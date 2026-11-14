# cocotb_test.py: does FS_HBM_PORT serve its MI and fetcher clients correctly over AXI3?
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

"""cocotbext-axi AxiRam (AXI3 4-bit LEN, random pauses on every channel) behind the DUT; Python
clients mimic FS_REGS (one MI access at a time) and FS_RING_FETCH (bursts held until RDY)."""

import os
import random
from collections import deque

import cocotb
from cocotb.triggers import RisingEdge, Timer, ClockCycles

from cocotbext.axi import AxiBus

from fs_axi_util import PoisonRam, pause_channels, quiet, use_axi3_len
from fs_ctx import AXI_BEAT
from fs_hbm_port_model import HbmPortModel
from fs_tb_util import release_reset, seeded, settle, start_clock

use_axi3_len()

FETCHERS = int(os.environ.get("FETCHERS", 16))
MEM_SIZE = 1 << 24
FETCH_BASE = 0x80_0000
FETCH_SPAN = 0x4_0000


class Env:
    def __init__(self, dut, salt, pause=0.3):
        self.dut = dut
        self.rng = seeded(salt)
        self.model = HbmPortModel(FETCHERS)
        self.poison = set()
        self.ram = PoisonRam(AxiBus.from_prefix(dut, "M_AXI"), dut.CLK, dut.HBM_RESET, MEM_SIZE, self.poison)
        quiet(self.ram)
        self.ram.write_if.aw_channel.queue_occupancy_limit = 8
        self.ram.read_if.ar_channel.queue_occupancy_limit = 8
        self.ram.read_if.r_channel.queue_occupancy_limit = 8
        pause_channels(self.ram, self.rng, pause)
        # Channels a test can stall at will: W to hold a write beat, R and B to keep transactions in flight.
        self.hold = {"w": False, "r": False, "b": False}
        for key, chan in (("w", self.ram.write_if.w_channel), ("r", self.ram.read_if.r_channel),
                          ("b", self.ram.write_if.b_channel)):
            chan.set_pause_generator(self._pauses(key, pause))
        self.errors = []
        self.clients = []
        self.flushing = False                 # since a client reset, until the first request is accepted
        self.axi_prev = {}                    # last cycle's valid-and-not-ready channels, with payload
        self.exp_ar = deque()
        self.exp_aw = deque()
        self.exp_w = deque()
        self.freq = [None] * FETCHERS         # (addr, beats) being offered
        # FREQ_VLD is one vector written by every fetcher task; a read-modify-write of the signal
        # would read the value of before this timestep's writes and lose updates.
        self.fvld = 0
        self.fq = [deque() for _ in range(FETCHERS)]
        self.f_wait = [0] * FETCHERS
        self.mi_req = None                    # (wr, addr, data, be) being offered
        self.mi_rsp = deque()
        self.rsp_wanted = 0
        self.cov = {"f_grants": 0, "mi_rd": 0, "mi_wr": 0, "mi_rd_blocked_by_wr": 0, "max_rr_wait": 0,
                    "f_beats": 0, "mi_and_f_same_cycle": 0, "resets": 0, "reset_reads_out": 0,
                    "reset_w_held": 0, "reset_writes_out": 0, "stale_r_beats": 0, "stale_b": 0,
                    "refused_cycles": 0}
        start_clock(dut)
        dut.RESET.value = 1
        dut.HBM_RESET.value = 1
        dut.CLEAR.value = 0
        dut.HBM_READY.value = 0
        dut.RING_REQ_VLD.value = 0
        dut.RING_REQ_WR.value = 0
        dut.RING_REQ_ADDR.value = 0
        dut.RING_REQ_DATA.value = 0
        dut.RING_REQ_BE.value = 0
        dut.FREQ_VLD.value = 0
        for f in range(FETCHERS):
            dut.FREQ_ADDR[f].value = 0
            dut.FREQ_BEATS[f].value = 1

    def _pauses(self, key, prob):
        rng = random.Random(self.rng.random())
        while True:
            yield self.hold[key] or rng.random() < prob

    async def reset(self, ready=True):
        await release_reset(self.dut, 8, 0, sigs=("RESET", "HBM_RESET"))
        if ready:
            self.dut.HBM_READY.value = 1
        await ClockCycles(self.dut.CLK, 2)
        cocotb.start_soon(self._monitor())

    def preload(self):
        data = self.rng.randbytes(FETCHERS * FETCH_SPAN)
        self.ram.write(FETCH_BASE, data)
        self.model.preload(FETCH_BASE, data)

    # Monitor: everything is sampled at the edge, i.e. the values of the cycle that just ended ------
    async def _monitor(self):
        d = self.dut
        while True:
            await RisingEdge(d.CLK)
            if int(d.HBM_RESET.value):
                self.axi_prev = {}
                continue
            in_reset = int(d.RESET.value)
            pend = int(d.RING_WR_PENDING.value)
            if pend != int(self.model.pending > 0):
                self.errors.append(f"RING_WR_PENDING {pend} with {self.model.pending} writes outstanding")
            if not int(d.HBM_READY.value) and (int(d.M_AXI_ARVALID.value) or int(d.M_AXI_AWVALID.value)):
                self.errors.append("AXI request before HBM_READY")
            self._axi_stable()

            if in_reset:
                # The clients are in reset: what they waited for is gone, what the AXI side owes stays.
                if not self.flushing:
                    self.cov["resets"] += 1
                    self.cov["reset_reads_out"] += int(self.model.rd_out > 0 or bool(self.exp_ar))
                    self.cov["reset_writes_out"] += int(self.model.pending > 0)
                    self.cov["reset_w_held"] += int(bool(int(d.M_AXI_WVALID.value) and not int(d.M_AXI_WREADY.value)))
                self.flushing = True
                self.model.abort_clients()
            else:
                self._client_requests()
            self._axi_handshakes()
            if not in_reset:
                self._client_responses()

    def _axi_stable(self):
        d = self.dut
        chans = {"AR": (d.M_AXI_ARVALID, d.M_AXI_ARREADY, (d.M_AXI_ARADDR, d.M_AXI_ARID, d.M_AXI_ARLEN)),
                 "AW": (d.M_AXI_AWVALID, d.M_AXI_AWREADY, (d.M_AXI_AWADDR, d.M_AXI_AWID, d.M_AXI_AWLEN)),
                 "W": (d.M_AXI_WVALID, d.M_AXI_WREADY, (d.M_AXI_WDATA, d.M_AXI_WSTRB, d.M_AXI_WLAST))}
        for name, (vld, rdy, payload) in chans.items():
            now = tuple(int(p.value) for p in payload)
            prev = self.axi_prev.get(name)
            if prev is not None and (not int(vld.value) or now != prev):
                self.errors.append(f"{name} withdrawn or changed before its handshake")
            self.axi_prev[name] = now if int(vld.value) and not int(rdy.value) else None

    def _client_requests(self):
        d = self.dut
        fvld = int(d.FREQ_VLD.value)
        frdy = int(d.FREQ_RDY.value)
        mi_hs = int(d.RING_REQ_VLD.value) and int(d.RING_REQ_RDY.value)
        if frdy & ~fvld:
            self.errors.append(f"FREQ_RDY 0x{frdy:x} without FREQ_VLD 0x{fvld:x}")
        if frdy & (frdy - 1):
            self.errors.append(f"FREQ_RDY 0x{frdy:x} grants two fetchers")
        if mi_hs and not int(d.RING_REQ_WR.value) and frdy:
            self.errors.append("MI read and a fetcher granted in one cycle")
        if self.flushing:
            if not self._axi_empty():
                if frdy or int(d.RING_REQ_RDY.value):
                    self.errors.append("request accepted while transactions from before a reset are outstanding")
                self.cov["refused_cycles"] += int(bool(fvld or int(d.RING_REQ_VLD.value)))
            elif mi_hs or frdy:
                self.flushing = False
        if mi_hs:
            wr, addr, data, be = self.mi_req
            if wr:
                exp = self.model.mi_write(addr, data, be) + (data,)
                self.exp_aw.append(exp)
                self.exp_w.append(exp)
                self.cov["mi_wr"] += 1
            else:
                if self.model.pending:
                    self.errors.append("MI read accepted with writes pending")
                    self.model.pending = 0
                if fvld:
                    self.cov["mi_and_f_same_cycle"] += 1
                self.exp_ar.append((self.model.mi_read(addr), self.model.mi_id, 0))
                self.cov["mi_rd"] += 1
            self.mi_req = None
        elif int(d.RING_REQ_VLD.value) and not int(d.RING_REQ_WR.value) and self.model.pending:
            self.cov["mi_rd_blocked_by_wr"] += 1
        for f in range(FETCHERS):
            if fvld >> f & 1:
                if frdy >> f & 1:
                    addr, beats = self.freq[f]
                    self.exp_ar.append(self.model.fetch(f, addr, beats))
                    self.freq[f] = None
                    self.f_wait[f] = 0
                    self.cov["f_grants"] += 1
                elif frdy:
                    self.f_wait[f] += 1
                    self.cov["max_rr_wait"] = max(self.cov["max_rr_wait"], self.f_wait[f])
                    if self.f_wait[f] > FETCHERS - 1:
                        self.errors.append(f"fetcher {f} passed over {self.f_wait[f]} times")

    def _axi_empty(self):
        """Every transaction accepted so far has answered, and no request is still held."""
        return self.model.quiet() and not self.exp_ar and not self.exp_aw and not self.exp_w

    def _axi_handshakes(self):
        d = self.dut
        if int(d.M_AXI_ARVALID.value) and int(d.M_AXI_ARREADY.value):
            got = (int(d.M_AXI_ARADDR.value), int(d.M_AXI_ARID.value), int(d.M_AXI_ARLEN.value))
            if int(d.M_AXI_ARSIZE.value) != 5 or int(d.M_AXI_ARBURST.value) != 1:
                self.errors.append("ARSIZE/ARBURST not 32 B INCR")
            want = self.exp_ar.popleft() if self.exp_ar else None
            if got != want:
                self.errors.append(f"AR {got}, expected {want}")
            self.model.ar_issued()
        if int(d.M_AXI_AWVALID.value) and int(d.M_AXI_AWREADY.value):
            got = (int(d.M_AXI_AWADDR.value), int(d.M_AXI_AWID.value), int(d.M_AXI_AWLEN.value))
            want = self.exp_aw.popleft() if self.exp_aw else None
            if want is None or got != (want[0], self.model.mi_id, 0):
                self.errors.append(f"AW {got}, expected {want}")
        if int(d.M_AXI_WVALID.value) and int(d.M_AXI_WREADY.value):
            want = self.exp_w.popleft() if self.exp_w else None
            strb = int(d.M_AXI_WSTRB.value)
            wdata = int(d.M_AXI_WDATA.value)
            if want is None or strb != want[1] or not int(d.M_AXI_WLAST.value):
                self.errors.append(f"W strb 0x{strb:08x}, expected {want}")
            elif any((wdata >> (32 * k)) & 0xFFFFFFFF != want[2] for k in range(8)):
                self.errors.append("W data is not the MI word on every lane")
            if int(d.M_AXI_WDATA_PARITY.value) != 0:
                self.errors.append("WDATA_PARITY not driven 0")
        if int(d.M_AXI_BVALID.value) and int(d.M_AXI_BREADY.value):
            self.model.b_response()
            self.cov["stale_b"] += int(self.flushing)
        if int(d.M_AXI_RVALID.value) and int(d.M_AXI_RREADY.value):
            self.cov["stale_r_beats"] += int(self.flushing)
            if int(d.M_AXI_RLAST.value):
                self.model.r_last()

    def _client_responses(self):
        d = self.dut
        vld = int(d.FRSP_VLD.value)
        if vld & (vld - 1):
            self.errors.append(f"FRSP_VLD 0x{vld:x} has two clients")
        elif vld:
            f = vld.bit_length() - 1
            data = int(d.FRSP_DATA.value).to_bytes(AXI_BEAT, "little")
            last = bool(int(d.FRSP_LAST.value))
            want = self.model.f_expect[f].popleft() if self.model.f_expect[f] else None
            if want is None or (data, last) != want:
                self.errors.append(f"fetcher {f} beat {data.hex()} last {last}, expected {want}")
            self.cov["f_beats"] += 1
        if int(d.RING_RSP_VLD.value):
            if self.model.mi_read_addr is None:
                self.errors.append("RING_RSP_VLD with no MI read outstanding")
            else:
                want = self.model.mi_read_data()
                got = int(d.RING_RSP_DATA.value)
                if got != want:
                    self.errors.append(f"MI read 0x{got:08x}, expected 0x{want:08x}")
                self.mi_rsp.append(got)

    # Clients --------------------------------------------------------------------------------------
    async def fetcher(self, f, count, region=None, prob=0.5):
        d = self.dut
        lo, span = region if region else (FETCH_BASE + f * FETCH_SPAN, FETCH_SPAN)
        for _ in range(count):
            beats = min(self.rng.choice([1, 2, 16, self.rng.randrange(1, 17)]), span // AXI_BEAT)
            addr = lo + self.rng.randrange(span // AXI_BEAT - beats + 1) * AXI_BEAT
            beats = min(beats, (4096 - addr % 4096) // AXI_BEAT)
            while self.rng.random() > prob:
                await settle(d)
            await settle(d)
            self.freq[f] = (addr, beats)
            d.FREQ_ADDR[f].value = addr
            d.FREQ_BEATS[f].value = beats
            self.fvld |= 1 << f
            d.FREQ_VLD.value = self.fvld
            while True:
                await RisingEdge(d.CLK)
                if int(d.FREQ_RDY.value) >> f & 1:
                    break
            await Timer(1, unit="ns")
            self.fvld &= ~(1 << f)
            d.FREQ_VLD.value = self.fvld

    async def mi_access(self, wr, addr, data=0, be=0xF):
        d = self.dut
        await settle(d)
        self.mi_req = (wr, addr, data, be)
        d.RING_REQ_VLD.value = 1
        d.RING_REQ_WR.value = int(wr)
        d.RING_REQ_ADDR.value = addr
        d.RING_REQ_DATA.value = data
        d.RING_REQ_BE.value = be
        while True:
            await RisingEdge(d.CLK)
            if int(d.RING_REQ_RDY.value):
                break
        await Timer(1, unit="ns")
        d.RING_REQ_VLD.value = 0
        if not wr:
            n = len(self.mi_rsp)
            for _ in range(5000):
                await RisingEdge(d.CLK)
                if len(self.mi_rsp) > n:
                    return self.mi_rsp[-1]
            raise AssertionError("MI read never returned")

    async def mi_traffic(self, count, lo=0, span=FETCH_BASE):
        written = []
        for _ in range(count):
            if written and self.rng.random() < 0.4:
                await self.mi_access(False, self.rng.choice(written))
            elif self.rng.random() < 0.15:
                await self.mi_access(False, lo + 4 * self.rng.randrange(span // 4))
            else:
                addr = lo + 4 * self.rng.randrange(span // 4)
                await self.mi_access(True, addr, self.rng.getrandbits(32), self.rng.choice([0xF, 0xF, self.rng.randrange(16)]))
                written.append(addr)

    async def quiesce(self, timeout=20000):
        for _ in range(timeout):
            if (not self.exp_ar and not self.exp_aw and not self.exp_w and self.model.pending == 0
                    and all(not q for q in self.model.f_expect) and self.model.mi_read_addr is None):
                break
            await RisingEdge(self.dut.CLK)
        await ClockCycles(self.dut.CLK, 10)
        self.check()
        assert not self.exp_ar and not self.exp_aw and self.model.pending == 0, "requests left unanswered"
        assert all(not q for q in self.model.f_expect), "fetcher beats never returned"
        self.check_counters()

    def check(self):
        assert not self.errors, "\n".join(self.errors[:20])

    def check_image(self):
        for waddr in self.model.written:
            val = self.model.image[waddr]
            got = int.from_bytes(self.ram.read(waddr << 2, 4), "little")
            assert got == val, f"HBM word 0x{waddr << 2:x} = 0x{got:08x}, expected 0x{val:08x}"

    def check_counters(self):
        """The outstanding counts are back at zero: an underflow would leave them wrapped or stuck."""
        for name in ("wr_cnt", "rd_cnt", "flush_r"):
            assert int(getattr(self.dut, name).value) == 0, f"{name} = {getattr(self.dut, name).value}"

    def start_clients(self, fetch_count, mi_count, prob=0.9):
        """Fetchers on every ring and the MI client, cancellable by client_reset."""
        self.clients = [cocotb.start_soon(self.fetcher(f, fetch_count, prob=prob)) for f in range(FETCHERS)]
        self.clients.append(cocotb.start_soon(self.mi_traffic(mi_count)))
        return self.clients

    async def client_reset(self, cycles):
        """RESET for `cycles` clocks with the clients dropped, as DMA_RST does; HBM_RESET stays low."""
        d = self.dut
        await settle(d)
        for t in self.clients:
            t.cancel()
        self.clients = []
        self.freq = [None] * FETCHERS
        self.fvld = 0
        self.f_wait = [0] * FETCHERS
        self.mi_req = None
        d.FREQ_VLD.value = 0
        d.RING_REQ_VLD.value = 0
        d.RESET.value = 1
        await release_reset(d, cycles, 0)


@cocotb.test()
async def test_mixed_traffic(dut):
    """All fetchers and the MI client at once, random AXI pauses everywhere."""
    env = Env(dut, 1)
    await env.reset()
    env.preload()
    tasks = [cocotb.start_soon(env.fetcher(f, 30, prob=env.rng.choice([0.2, 0.9]))) for f in range(FETCHERS)]
    tasks.append(cocotb.start_soon(env.mi_traffic(150)))
    for t in tasks:
        await t
    await env.quiesce()
    env.check_image()
    dut._log.info(f"coverage: {env.cov}")
    assert env.cov["mi_rd_blocked_by_wr"] > 0 and env.cov["max_rr_wait"] > 0


@cocotb.test()
async def test_fence_then_fetch(dut):
    """A fetch issued after RING_WR_PENDING fell sees every MI write before it."""
    env = Env(dut, 2)
    await env.reset()
    env.preload()
    for rnd in range(6):
        f = env.rng.randrange(FETCHERS)
        lo = FETCH_BASE + f * FETCH_SPAN + env.rng.randrange(FETCH_SPAN // 4096) * 4096
        for k in range(env.rng.randrange(4, 40)):
            await env.mi_access(True, lo + 4 * env.rng.randrange(1024), env.rng.getrandbits(32))
        while int(dut.RING_WR_PENDING.value):
            await RisingEdge(dut.CLK)
        await env.fetcher(f, 4, region=(lo, 4096), prob=1.0)
        await env.quiesce()
    env.check_image()


@cocotb.test()
async def test_hbm_ready_gate(dut):
    """Requests wait for HBM_READY; nothing reaches AXI before it."""
    env = Env(dut, 3)
    await env.reset(ready=False)
    env.preload()
    tasks = [cocotb.start_soon(env.fetcher(f, 3, prob=1.0)) for f in range(FETCHERS)]
    tasks.append(cocotb.start_soon(env.mi_access(True, 0x100, 0x1234_5678)))
    await ClockCycles(dut.CLK, 200)
    assert env.cov["f_grants"] == 0 and env.cov["mi_wr"] == 0, "request accepted before HBM_READY"
    env.check()
    await Timer(1, unit="ns")
    dut.HBM_READY.value = 1
    for t in tasks:
        await t
    await env.quiesce()


@cocotb.test()
async def test_hbm_err_sticky(dut):
    """A SLVERR on R or B sets HBM_ERR until CLEAR."""
    env = Env(dut, 4)
    await env.reset()
    env.preload()
    assert int(dut.HBM_ERR.value) == 0
    bad = FETCH_BASE + 5 * FETCH_SPAN + 0x2000
    env.poison.add(bad)
    await env.fetcher(5, 1, region=(bad, 32), prob=1.0)
    # The poisoned beat reads as zeros; the image keeps no expectation for it.
    for _ in range(400):
        await RisingEdge(dut.CLK)
        if int(dut.HBM_ERR.value):
            break
    assert int(dut.HBM_ERR.value) == 1, "SLVERR on R did not raise HBM_ERR"
    env.errors = [e for e in env.errors if "fetcher 5 beat" not in e]
    await ClockCycles(dut.CLK, 30)
    assert int(dut.HBM_ERR.value) == 1, "HBM_ERR is not sticky"
    await settle(dut)
    dut.CLEAR.value = 1
    await settle(dut)
    dut.CLEAR.value = 0
    await ClockCycles(dut.CLK, 2)
    assert int(dut.HBM_ERR.value) == 0, "CLEAR did not clear HBM_ERR"
    env.poison.add(0x40)
    await env.mi_access(True, 0x44, 0xDEADBEEF)
    for _ in range(400):
        await RisingEdge(dut.CLK)
        if int(dut.HBM_ERR.value):
            break
    assert int(dut.HBM_ERR.value) == 1, "SLVERR on B did not raise HBM_ERR"
    env.errors = [e for e in env.errors if "fetcher 5 beat" not in e]
    env.check()


@cocotb.test()
async def test_client_reset_in_flight(dut):
    """RESET (DMA_RST) while reads are in flight and a write beat is held: nothing stale reaches a
    client, no outstanding count wraps, requests wait for the old transactions, then traffic is right."""
    env = Env(dut, 5)
    await env.reset()
    env.preload()
    rounds = 12
    for rnd in range(rounds):
        env.hold["w"] = rnd % 2 == 0
        env.hold["r"] = rnd % 3 != 2
        env.hold["b"] = rnd % 4 == 1
        env.start_clients(12, 40)
        await ClockCycles(dut.CLK, env.rng.randint(60, 400))
        await env.client_reset(env.rng.choice([1, 1, 2, 3, 6]))
        # New clients ask at once; the old transactions are released only afterwards.
        env.start_clients(6, 20)
        await ClockCycles(dut.CLK, env.rng.choice([0, 3, 40, 120]))
        env.hold.update(w=False, r=False, b=False)
        for t in env.clients:
            await t
        await env.quiesce()
        env.check_image()
    dut._log.info(f"coverage: {env.cov}")
    cov = env.cov
    assert cov["resets"] == rounds
    assert cov["reset_reads_out"] > 0 and cov["reset_w_held"] > 0 and cov["reset_writes_out"] > 0, cov
    assert cov["stale_r_beats"] > 0 and cov["refused_cycles"] > 0, cov
