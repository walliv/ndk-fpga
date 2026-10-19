# scratchpad_env.py: Environment of the scratchpad CORE_LOGIC bench (stimulus, reference model, scoreboard)
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

"""Both endpoints: CQ TLPs go in through the CPM5 straddle driver, completions return through the
straddle monitor, and one AXI memory model per NMU shares a sparse memory, the HBM window both
BARs map. State outliving a test lives in ``SharedState``."""

import lzma
import os
import random
import time
from collections import Counter, deque

import cocotb
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

from cocotbext.ofm.axi4s_pcie.cpm5 import (CC1024, CQ1024, Cpm5StraddleDriver, Cpm5StraddleMonitor,
                                           Cpm5Tlp, payload_byte_en, random_ready)
from cocotbext.ofm.mfb.utils import signal_binstr
from cocotbext.ofm.pcie import PcieReqType, pcie_byte_count
from cocotbext.ofm.pcie.PcieHeaders import CCHeader, CQHeader

from axi_mem_slave import AxiMemSlave, SparseMem, init_byte

# CORE_LOGIC constants (core_logic.vhd, mi_addr_space_pkg.vhd, pcie_top.vhd); the bench fails if the RTL disagrees
EPS = 2
SPAD_FUNC = 1
SPAD_BAR = 0
SPAD_APERTURE = 30
AXI_BASE = 0x0000_0040_0000_0000
AXI_CACHE = 0b0010
MI_APERTURE = 26
MAX_WR = 1024
MAX_RD = 4096
STATUS_BASE = 0x0200_0000
STATUS_OFFSET = 0x100
STATUS_ID = 0x5350_4144
# PCI_EXT_CAP behind cfg_ext: the Extended_Large user space starts at 0x600 (pcie_core_cpm5.vhd)
VSEC_REG = 0x600 // 4
EXT_LAST_REG = 0xFFC // 4

POSTED_TYPES = {0b0001, 0b1100, 0b1101, 0b1110, 0b1111}
READ_CPL_TYPES = {0b0000, 0b0111}


class TbError(Exception):
    pass


def env_int(name, default):
    return int(os.environ.get(name, default))


def la_low(fbe):
    for i in range(4):
        if (fbe >> i) & 1:
            return i
    return 0


def bin_int(handle):
    b = signal_binstr(handle)
    try:
        return int(b, 2)
    except ValueError:
        return None


class RefMem:
    """Per-byte write history in AXI address space, shared by both endpoints. A read may return the
    value its CQ position implies or, as posted writes pass a waiting read, that of a later write."""

    def __init__(self, salt):
        self.salt = salt
        self.hist = {}

    def write(self, addr, val, seq):
        self.hist.setdefault(addr, []).append((seq, val))

    def last_seq(self, addr):
        h = self.hist.get(addr)
        return h[-1][0] if h else 0

    def expected(self, addr, seq):
        exp = init_byte(addr, self.salt)
        for s, v in self.hist.get(addr, ()):
            if s < seq:
                exp = v
        return exp

    def check(self, addr, val, seq):
        exp = self.expected(addr, seq)
        if val == exp:
            return "exact"
        if any(s > seq and v == val for s, v in self.hist.get(addr, ())):
            return "relaxed"
        return None

    def final(self, addr):
        h = self.hist.get(addr)
        return h[-1][1] if h else init_byte(addr, self.salt)


class SharedState:
    """Everything the DUT keeps between cocotb tests (the design is reset only once, at time 0)."""

    def __init__(self, seed):
        self.seed = seed
        rng = random.Random(seed)
        self.salt = rng.getrandbits(32)
        self.mem = SparseMem(self.salt)
        self.ref = RefMem(self.salt)
        self.seq = 0
        # MI_TEST_SPACE of each endpoint: 64 words, zero after configuration
        self.tspace = [[0] * 64 for _ in range(EPS)]
        # PCIE_BAR2AXI counter values already accounted for (wr, rd, ur, drop, err)
        self.cnt = [Counter() for _ in range(EPS)]
        # host addresses of the BARs, aligned to their sizes
        self.bar1 = [rng.getrandbits(64 - SPAD_APERTURE) << SPAD_APERTURE for _ in range(EPS)]
        self.bar0 = [rng.getrandbits(64 - MI_APERTURE) << MI_APERTURE for _ in range(EPS)]
        self.cov = Counter()


class Endpoint:
    """Agents and expectations of one PCIe endpoint."""

    def __init__(self, env, ep):
        self.env = env
        self.ep = ep
        self.st = env.st
        self.log = env.log
        self.rng = random.Random(env.rng.getrandbits(32))
        cips = env.cips
        self.clk = getattr(cips, f"EP{ep}_CLK")
        self.cips = cips
        self.cq = Cpm5StraddleDriver(cips, f"EP{ep}_CQ", self.clk, CQ1024, rng=random.Random(self.rng.getrandbits(32)),
                                     p_share=env.p_share, p_skip=0.2)
        self.cc = Cpm5StraddleMonitor(cips, f"EP{ep}_CC", self.clk, CC1024, callback=self._on_cc)
        # the CQ as the DUT sees it: legal CPM5 straddling and exactly the TLPs queued, in order
        self.cq_mon = Cpm5StraddleMonitor(cips, f"EP{ep}_CQ", self.clk, CQ1024, callback=self._on_cq)
        self.cq_sent = deque()
        self.cc_ready = getattr(cips, f"EP{ep}_CC_READY")
        self.cc_ready.value = 0
        nmu = env.nmu(ep)
        self.axi = AxiMemSlave(nmu, self.clk, self.st.mem, random.Random(self.rng.getrandbits(32)),
                               env.axi_cfg, self.log, prefix="AXI")
        self.axi.on_write_burst = self._on_axi_write
        self.axi.on_ar = self._on_ar
        self.free_tags = deque(range(256))
        self.rng.shuffle(self.free_tags)
        self.exp = {}               # tag -> completion group
        self.req_id = self.rng.getrandbits(16)
        self.last_wr_seq = 0        # seq of the last MemWr queued to PF1 BAR0
        self.committed = 0          # every scratchpad write with a seq up to this one is in memory
        self.cnt = Counter()        # counter increments expected in this test
        self.sent = 0
        self.np_out = 0
        self.cpl_tlps = 0
        self.rq_seen = 0
        self.wr_bursts = 0

    def start(self):
        self.axi.start()
        cocotb.start_soon(random_ready(self.clk, self.cc_ready, random.Random(self.rng.getrandbits(32)),
                                       p_phases=self.env.cc_phases))
        cocotb.start_soon(self._rq_watch())

    async def _rq_watch(self):
        clk_re = RisingEdge(self.clk)
        valid = getattr(self.cips, f"EP{self.ep}_RQ_VALID")
        while True:
            await clk_re
            await ReadOnly()
            if signal_binstr(valid) != "0":
                self.rq_seen += 1

    # ---------------------------------------------------------------------------------------------
    # Requests
    # ---------------------------------------------------------------------------------------------
    def _fail(self, msg):
        self.env.fail(f"EP{self.ep}: {msg}")

    def _queue(self, hdr, fbe, lbe, payload=b"", idle=None):
        desc = hdr.serialize().to_bytes(16, "little")
        if hdr.req_type == PcieReqType.MWR or payload:
            byte_en = payload_byte_en(len(payload) // 4, fbe, lbe) << 16 if payload else 0
        else:
            byte_en = 0
        if idle is None:
            idle = self.rng.choice([0] * 12 + [1, 2, 5, 17])
        tlp = Cpm5Tlp(desc + bytes(payload), fbe, lbe, byte_en=byte_en)
        self.cq_sent.append(tlp)
        self.cq.append(tlp, idle_before=idle)
        self.sent += 1
        self.st.cov[f"ep{self.ep}_tlps"] += 1

    def _hdr(self, rtype, addr, dw, func, bar, aperture, tag=0):
        h = CQHeader()
        h.addr = (addr & ((1 << 64) - 1)) >> 2
        h.dword_count = dw
        h.req_type = rtype
        h.req_id = self.req_id
        h.tag = tag
        h.tgt_func = func
        h.bar_id = bar
        h.bar_apper = aperture
        h.tc = self.rng.randrange(8)
        h.attr = self.rng.randrange(8)
        return h

    def _take_tag(self):
        if not self.free_tags:
            self._fail("ran out of tags")
        self.np_out += 1
        return self.free_tags.popleft()

    def mem_wr(self, off, dw, fbe, lbe, payload=None):
        """MemWr to PF1 BAR0 at byte offset ``off`` of the window."""
        st = self.st
        if payload is None:
            payload = self.rng.randbytes(4 * dw)
        st.seq += 1
        seq = st.seq
        h = self._hdr(PcieReqType.MWR, self.st.bar1[self.ep] + off, dw, SPAD_FUNC, SPAD_BAR, SPAD_APERTURE)
        if 4 * dw <= MAX_WR:
            axi = AXI_BASE + off
            for j in range(dw):
                be = fbe if j == 0 else (lbe if j == dw - 1 else 0xF)
                for b in range(4):
                    if (be >> b) & 1:
                        st.ref.write(axi + 4 * j + b, payload[4 * j + b], seq)
            self.last_wr_seq = seq
            self.cnt["wr"] += 1
            if 4 * dw == MAX_WR:
                st.cov["max_write"] += 1
            if (off & 0xFFF) + 4 * dw == 4096:
                st.cov["write_to_page_end"] += 1
            if off % 128 + 4 * dw > 128:
                st.cov["write_over_128B"] += 1
        else:
            self.cnt["drop"] += 1
        self._queue(h, fbe, lbe, payload)

    def mem_rd(self, off, dw, fbe, lbe, cross=False):
        """MemRd of PF1 BAR0; ``cross`` marks a read of the other endpoint's writes."""
        st = self.st
        st.seq += 1
        seq = st.seq
        tag = self._take_tag()
        pcie = st.bar1[self.ep] + off
        h = self._hdr(PcieReqType.MRD, pcie, dw, SPAD_FUNC, SPAD_BAR, SPAD_APERTURE, tag)
        axi = AXI_BASE + off
        a0 = (off >> 2) & 31
        nch = ((a0 + dw - 1) >> 5) + 1
        bc = pcie_byte_count(dw, fbe, lbe)
        la = (off & 0x7C) | la_low(fbe)
        end_off = la + bc
        chunk0 = axi & ~127
        segs = []
        for s in range(nch):
            lo = a0 if s == 0 else 0
            hi = ((a0 + dw - 1) & 31) + 1 if s == nch - 1 else 32
            segs.append(dict(status=0, dw=hi - lo, bc=bc if s == 0 else end_off - 128 * s,
                             la=la if s == 0 else 0, addr=chunk0 + 128 * s + 4 * lo))
        self.exp[tag] = dict(kind="rd", seq=seq, segs=segs, idx=0, hdr=h, dw=dw, cross=cross,
                             zero_len=(dw == 1 and fbe == 0), wr_before=self.last_wr_seq,
                             cpl_id=True)
        self.cnt["rd"] += 1
        if 4 * dw == MAX_RD:
            st.cov["max_read"] += 1
        if (off & 0xFFF) + 4 * dw == 4096:
            st.cov["read_to_page_end"] += 1
        if nch > 1:
            st.cov["read_over_128B"] += 1
        self._queue(h, fbe, lbe)

    def unsupported(self, kind):
        """A request PCIE_BAR2AXI must answer with UR (non-posted) or drop (posted)."""
        st = self.st
        r = self.rng
        off = r.randrange(0, 1 << SPAD_APERTURE, 8)
        if kind == "rd_bar2":
            func, bar, rtype, dw = SPAD_FUNC, 2, PcieReqType.MRD, r.randint(1, 16)
        elif kind == "rd_func0_bar2":
            func, bar, rtype, dw = 0, 2, PcieReqType.MRD, r.randint(1, 16)
        elif kind == "rd_func2":
            func, bar, rtype, dw = 2, SPAD_BAR, PcieReqType.MRD, r.randint(1, 16)
        elif kind == "iord":
            func, bar, rtype, dw = SPAD_FUNC, SPAD_BAR, PcieReqType.IORD, 1
        elif kind == "wr_bar2":
            func, bar, rtype, dw = SPAD_FUNC, 2, PcieReqType.MWR, r.randint(1, 16)
        else:
            raise ValueError(kind)
        fbe = r.randrange(1, 16)
        lbe = 0 if dw == 1 else r.randrange(1, 16)
        if rtype == PcieReqType.MWR:
            h = self._hdr(rtype, st.bar1[self.ep] + off, dw, func, bar, SPAD_APERTURE)
            self.cnt["drop"] += 1
            st.cov["dropped"] += 1
            self._queue(h, fbe, lbe, r.randbytes(4 * dw))
            return
        tag = self._take_tag()
        h = self._hdr(rtype, st.bar1[self.ep] + off, dw, func, bar, SPAD_APERTURE, tag)
        if rtype in READ_CPL_TYPES:
            bc = pcie_byte_count(dw, fbe, lbe)
            la = (off & 0x7C) | la_low(fbe)
        else:
            bc, la = 4, 0
        self.exp[tag] = dict(kind="ur", seq=0, segs=[dict(status=1, dw=0, bc=bc, la=la, addr=None)], idx=0,
                             hdr=h, dw=dw, cross=False, zero_len=False, wr_before=0, cpl_id=True)
        self.cnt["ur"] += 1
        self._queue(h, fbe, lbe)

    def mi_wr(self, addr, dw, fbe, lbe, payload=None):
        """MemWr to PF0 BAR0 (MTC) at MI address ``addr`` inside the test space."""
        if payload is None:
            payload = self.rng.randbytes(4 * dw)
        h = self._hdr(PcieReqType.MWR, self.st.bar0[self.ep] + addr, dw, 0, 0, MI_APERTURE)
        ts = self.st.tspace[self.ep]
        for j in range(dw):
            be = fbe if j == 0 else (lbe if j == dw - 1 else 0xF)
            w = ((addr >> 2) + j) & 63
            v = int.from_bytes(payload[4 * j:4 * j + 4], "little")
            for b in range(4):
                if (be >> b) & 1:
                    ts[w] = (ts[w] & ~(0xFF << (8 * b))) | (v & (0xFF << (8 * b)))
        self.st.cov[f"ep{self.ep}_mi_wr"] += 1
        self._queue(h, fbe, lbe, payload)

    def mi_rd(self, addr, dw, fbe, lbe, expect=None, kind="mi_rd"):
        """MemRd of PF0 BAR0 (MTC); ``expect`` is the list of DW values, default: the test space model."""
        tag = self._take_tag()
        h = self._hdr(PcieReqType.MRD, self.st.bar0[self.ep] + addr, dw, 0, 0, MI_APERTURE, tag)
        if expect is None:
            ts = self.st.tspace[self.ep]
            expect = [ts[((addr >> 2) + j) & 63] for j in range(dw)]
        bc = pcie_byte_count(dw, fbe, lbe)
        la = (addr & 0x7C) | la_low(fbe)
        self.exp[tag] = dict(kind=kind, seq=0, segs=[dict(status=0, dw=dw, bc=bc, la=la, addr=None)], idx=0,
                             hdr=h, dw=dw, cross=False, zero_len=False, wr_before=0, cpl_id=False,
                             mi_expect=expect)
        self.st.cov[f"ep{self.ep}_{kind}"] += 1
        self._queue(h, fbe, lbe)
        return tag

    # ---------------------------------------------------------------------------------------------
    # DUT outputs
    # ---------------------------------------------------------------------------------------------
    def _on_axi_write(self, aw, beats):
        self.wr_bursts += 1
        lo = aw["addr"]
        hi = lo + (aw["len"] + 1) * self.axi.wb
        if not (AXI_BASE <= lo and hi <= AXI_BASE + (1 << SPAD_APERTURE)):
            self._fail(f"AXI write burst {lo:#x}..{hi:#x} outside the 1 GiB HBM window at {AXI_BASE:#x}")
        return None

    def _on_ar(self, ar):
        lo = ar["addr"]
        hi = lo + (ar["len"] + 1) * self.axi.wb
        if not (AXI_BASE <= lo and hi <= AXI_BASE + (1 << SPAD_APERTURE)):
            self._fail(f"AXI read {lo:#x}..{hi:#x} outside the 1 GiB HBM window at {AXI_BASE:#x}")

    def _on_cq(self, tlp):
        exp = self.cq_sent.popleft() if self.cq_sent else None
        got = (tlp.data, tlp.first_be, tlp.last_be, tlp.byte_en)
        if exp is None or (exp.data, exp.first_be, exp.last_be, exp.byte_en) != got:
            self._fail(f"CQ TLP {self.cq_mon.tlps} on the wire differs from the one queued")

    def _on_cc(self, tlp):
        st = self.st
        data = tlp.data
        if len(data) < 12:
            self._fail(f"CC TLP of {len(data)} B is shorter than its descriptor")
        hdr = CCHeader.deserialize(int.from_bytes(data[:12], "little"))
        payload = data[12:]
        g = self.exp.get(hdr.tag)
        if g is None:
            self._fail(f"completion with unexpected tag {hdr.tag:#x}")
        seg = g["segs"][g["idx"]]
        rq = g["hdr"]
        what = f"completion {g['idx']}/{len(g['segs'])} of {g['kind']} tag {hdr.tag:#x}"
        checks = [("requester ID", hdr.rid, rq.req_id), ("status", hdr.completion_status, seg["status"]),
                  ("DW count", hdr.dword_count, seg["dw"]), ("byte count", hdr.byte_count, seg["bc"]),
                  ("lower address", hdr.lower_address, seg["la"]), ("poisoned", hdr.poisoned, 0),
                  ("payload bytes", len(payload), 4 * seg["dw"])]
        if g["cpl_id"]:
            checks += [("completer ID", hdr.cid, rq.tgt_func), ("completer ID enable", hdr.cid_en, 0),
                       ("TC", hdr.tc, rq.tc), ("attributes", hdr.attr, rq.attr), ("address type", hdr.at, rq.at)]
        for name, got, exp in checks:
            if got != exp:
                self._fail(f"{what}: {name} = {got:#x}, expected {exp:#x}")
        if g["kind"] == "rd":
            if g["idx"] == 0:
                # the RAW fence held this read until every earlier write of this endpoint had its B
                self.committed = max(self.committed, g["wr_before"])
            if not g["zero_len"]:
                for i, v in enumerate(payload):
                    res = st.ref.check(seg["addr"] + i, v, g["seq"])
                    if res is None:
                        exp = st.ref.expected(seg["addr"] + i, g["seq"])
                        self._fail(f"{what}: data byte {seg['addr'] + i:#x} = {v:#04x}, expected {exp:#04x}")
                    if res == "relaxed":
                        st.cov["relaxed_bytes"] += 1
                    elif g["cross"]:
                        st.cov["cross_ep_bytes"] += 1
        elif g["kind"] != "ur" and g["mi_expect"] is not None:
            got = [int.from_bytes(payload[4 * j:4 * j + 4], "little") for j in range(g["dw"])]
            if got != g["mi_expect"]:
                self._fail(f"{what}: MI data {[hex(x) for x in got]}, expected {[hex(x) for x in g['mi_expect']]}")
        g["idx"] += 1
        self.cpl_tlps += 1
        if g["idx"] == len(g["segs"]):
            del self.exp[hdr.tag]
            self.free_tags.append(hdr.tag)
            self.np_out -= 1
            st.cov[f"done_{g['kind']}"] += 1
            if g["kind"] == "rd":
                if len(g["segs"]) >= 32:
                    st.cov["read_32_cpl"] += 1
                if g["zero_len"]:
                    st.cov["zero_len_read"] += 1
                if g["cross"]:
                    st.cov["cross_ep_reads"] += 1
            g.setdefault("done", True)
            if "on_done" in g:
                g["on_done"](payload)

    def idle(self):
        return (not self.cq._queue and not self.cq_sent and not self.exp and self.axi.idle()
                and self.cc._open is None)

    def progress(self):
        st = self.axi.stats
        return (self.cq.sent, self.cpl_tlps, st["aw"], st["w"], st["b"], st["ar"], st["r"])


class ScratchpadEnv:
    """Both endpoints, the shared memory and the end-of-test checks."""

    def __init__(self, dut, name, st, wall_limit_s=540.0, axi_cfg=None, cc_phases=(0.0, 0.3, 0.6, 0.9, 1.0),
                 p_share=0.85):
        self.dut = dut
        self.log = dut._log
        self.name = name
        self.st = st
        self.seed = random.getrandbits(32)
        self.rng = random.Random(self.seed)
        self.t0 = time.monotonic()
        self.wall_limit_s = wall_limit_s
        self.cips = dut.pcie_i.pcie_core_i.cips_i
        self.axi_cfg = dict(p_awready=0.6, p_wready=0.7, p_arready=0.6, p_bvalid=0.6, p_rvalid=0.7,
                            commit_lat=(0, 40), b_lat=(0, 12), r_lat=(4, 80), err_prob=0.0,
                            axi_cache=AXI_CACHE)
        if axi_cfg:
            self.axi_cfg.update(axi_cfg)
        self.cc_phases = cc_phases
        self.p_share = p_share
        self.errors = []
        self.log.info(f"[{name}] TB seed {self.seed}, shared-state seed {st.seed}, AXI {self.axi_cfg}")

    def nmu(self, ep):
        try:
            gen = self.dut.ep_g[ep]
        except (IndexError, TypeError, AttributeError):
            gen = getattr(self.dut, f"ep_g({ep})")
        return gen.nmu_i.xpm_nmu_i

    def fail(self, msg):
        msg = f"[{self.name}] {msg}"
        self.errors.append(msg)
        self.log.error(msg)
        raise TbError(msg)

    async def start(self):
        self.eps = [Endpoint(self, ep) for ep in range(EPS)]
        for e in self.eps:
            e.start()
        self.clk = self.eps[0].clk
        # the PL0 reset is released at 200 ns and the links come up after 240 ns; give the MI path time
        await ClockCycles(self.clk, 200)

    def wall_check(self):
        el = time.monotonic() - self.t0
        if el > self.wall_limit_s:
            self.fail(f"wall-clock watchdog: {el:.0f} s > {self.wall_limit_s:.0f} s")

    def _progress(self):
        return tuple(e.progress() for e in self.eps)

    def stall_check(self, n_cycles):
        prog = self._progress()
        if prog != getattr(self, "_last_prog", None):
            self._last_prog = prog
            self._stall = 0
            return
        self._stall = getattr(self, "_stall", 0) + n_cycles
        if self._stall > 40000:
            state = "; ".join(f"EP{e.ep}: queue {len(e.cq._queue)}, expected tags {sorted(e.exp)[:8]}, "
                              f"AXI {e.axi.stats}" for e in self.eps)
            self.fail(f"no progress for {self._stall} cycles: {state}")

    async def throttle(self, ep, max_queue=6, max_np=24):
        e = self.eps[ep]
        while len(e.cq._queue) > max_queue or e.np_out >= max_np:
            await ClockCycles(e.clk, 8)
            self.wall_check()
            self.stall_check(8)

    async def drain(self, max_cycles=600000):
        n = 0
        while not all(e.idle() for e in self.eps):
            await ClockCycles(self.clk, 16)
            n += 16
            self.wall_check()
            self.stall_check(16)
            if n > max_cycles:
                self.fail("drain timeout: " + "; ".join(f"EP{e.ep} queue {len(e.cq._queue)} tags {sorted(e.exp)[:8]} "
                                                        f"AXI idle {e.axi.idle()}" for e in self.eps))
        await ClockCycles(self.clk, 32)

    # ---------------------------------------------------------------------------------------------
    # Higher level operations
    # ---------------------------------------------------------------------------------------------
    async def flush(self, ep):
        """Make every queued write of ``ep`` visible to the other endpoint: a read issues only after all
        earlier writes got B (RAW fence), so its completion proves they are in memory."""
        e = self.eps[ep]
        target = e.last_wr_seq
        e.mem_rd(self.rng.randrange(0, 1 << SPAD_APERTURE, 4) & ~0xFFF, 1, 0xF, 0)
        while e.committed < target:
            await ClockCycles(e.clk, 16)
            self.wall_check()
            self.stall_check(16)

    async def mi_read_words(self, ep, addr, n):
        """Read ``n`` MI words through endpoint ``ep``'s MTC and return them (no model check)."""
        e = self.eps[ep]
        out = {}
        for j in range(n):
            await self.throttle(ep)
            tag = e.mi_rd(addr + 4 * j, 1, 0xF, 0, expect=None, kind="mi_peek")
            g = e.exp[tag]
            g["mi_expect"] = None

            def done(payload, j=j):
                out[j] = int.from_bytes(payload[:4], "little")
            g["on_done"] = done
        while len(out) < n:
            await ClockCycles(e.clk, 16)
            self.wall_check()
            self.stall_check(16)
        return [out[j] for j in range(n)]

    async def check_status(self, tag=""):
        """PCIE_BAR2AXI counters of both endpoints, read over MI through endpoint 0, against the model."""
        for e in self.eps:
            regs = await self.mi_read_words(0, STATUS_BASE + e.ep * STATUS_OFFSET, 7)
            got = dict(wr=regs[0], rd=regs[1], ur=regs[2], drop=regs[3], err=regs[4])
            base = self.st.cnt[e.ep]
            exp = {k: (base[k] + e.cnt[k]) & 0xFFFFFFFF for k in ("wr", "rd", "ur", "drop")}
            exp["err"] = (base["err"] + e.axi.stats["err_b"] + e.axi.stats["err_r"]) & 0xFFFFFFFF
            if got != exp:
                self.fail(f"{tag} EP{e.ep} status counters over MI {got}, expected {exp}")
            if regs[5] != (e.ep << 4 | 1) or regs[6] != STATUS_ID:
                self.fail(f"{tag} EP{e.ep} status INFO/ID {regs[5]:#x}/{regs[6]:#x}, expected "
                          f"{e.ep << 4 | 1:#x}/{STATUS_ID:#x}")
            self.st.cov["status_checks"] += 1
        return True

    def commit_counters(self):
        for e in self.eps:
            for k in ("wr", "rd", "ur", "drop"):
                self.st.cnt[e.ep][k] += e.cnt[k]
            self.st.cnt[e.ep]["err"] += e.axi.stats["err_b"] + e.axi.stats["err_r"]
            e.cnt.clear()

    async def finish(self, minima=None):
        await self.drain()
        await self.check_status("final")
        await self.drain()
        for e in self.eps:
            e.cc.final_check()
            e.cq_mon.final_check()
            if e.axi.errors:
                self.fail(f"EP{e.ep} AXI protocol errors: {e.axi.errors[:3]}")
            if e.rq_seen:
                self.fail(f"EP{e.ep}: RQ TVALID was not 0 in {e.rq_seen} cycles")
            if e.axi.stats["rready_low"] or e.axi.stats["bready_low"]:
                self.fail(f"EP{e.ep}: RREADY/BREADY low while valid {e.axi.stats['rready_low']}/"
                          f"{e.axi.stats['bready_low']} cycles")
            for k, v in e.cc.coverage.items():
                self.st.cov[f"cc{e.ep}_{k}"] += v
            for k, v in e.cq_mon.coverage.items():
                self.st.cov[f"cq{e.ep}_{k}"] += v
        # every write landed exactly where base + BAR offset says
        bad = [a for a in self.st.ref.hist if self.st.mem.read(a, 1)[0] != self.st.ref.final(a)]
        if bad:
            a = bad[0]
            self.fail(f"final memory: {len(bad)} bytes differ, first {a:#x} = {self.st.mem.read(a, 1)[0]:#04x}, "
                      f"expected {self.st.ref.final(a):#04x}")
        self.commit_counters()
        el = time.monotonic() - self.t0
        for e in self.eps:
            self.log.info(f"[{self.name}] EP{e.ep}: {e.sent} CQ TLPs, {e.cpl_tlps} CC TLPs, "
                          f"{e.cc.beats} CC beats, AXI {e.axi.stats}")
        self.log.info(f"[{self.name}] seed {self.seed}: wall {el:.1f} s, coverage {dict(sorted(self.st.cov.items()))}")
        if minima:
            missing = {k: (self.st.cov.get(k, 0), n) for k, n in minima.items() if self.st.cov.get(k, 0) < n}
            if missing:
                self.fail(f"coverage holes (hits, needed): {missing}")

    # ---------------------------------------------------------------------------------------------
    # Configuration space (cfg_ext)
    # ---------------------------------------------------------------------------------------------
    async def cfg_read(self, ep, reg, func=0, expect_dv=True, timeout=16):
        c = self.cips
        clk = getattr(c, f"EP{ep}_CLK")
        names = ("READ_RECEIVED", "REGISTER_NUMBER", "FUNCTION_NUMBER", "READ_DATA", "READ_DATA_VALID")
        sig = {n: getattr(c, f"EP{ep}_CFGX_{n}") for n in names}
        await RisingEdge(clk)
        sig["REGISTER_NUMBER"].value = reg
        sig["FUNCTION_NUMBER"].value = func
        sig["READ_RECEIVED"].value = 1
        await RisingEdge(clk)
        sig["READ_RECEIVED"].value = 0
        data = None
        for _ in range(timeout):
            await ReadOnly()
            if signal_binstr(sig["READ_DATA_VALID"]) == "1":
                if data is not None:
                    self.fail(f"EP{ep} cfg_ext read of register {reg:#x} answered twice")
                data = bin_int(sig["READ_DATA"])
            await RisingEdge(clk)
        if expect_dv and data is None:
            self.fail(f"EP{ep} cfg_ext read of register {reg:#x} (byte {4 * reg:#x}) got no answer")
        if not expect_dv and data is not None:
            self.fail(f"EP{ep} cfg_ext read of register {reg:#x} (byte {4 * reg:#x}) answered, the core does it")
        return data

    async def cfg_write(self, ep, reg, value, func=0):
        c = self.cips
        clk = getattr(c, f"EP{ep}_CLK")
        await RisingEdge(clk)
        getattr(c, f"EP{ep}_CFGX_REGISTER_NUMBER").value = reg
        getattr(c, f"EP{ep}_CFGX_FUNCTION_NUMBER").value = func
        getattr(c, f"EP{ep}_CFGX_WRITE_DATA").value = value
        getattr(c, f"EP{ep}_CFGX_WRITE_BYTE_ENABLE").value = 0xF
        getattr(c, f"EP{ep}_CFGX_WRITE_RECEIVED").value = 1
        await RisingEdge(clk)
        getattr(c, f"EP{ep}_CFGX_WRITE_RECEIVED").value = 0
        await ClockCycles(clk, 4)

    async def read_dtb(self, ep):
        """The xz-compressed DTB as the nfb driver fetches it through the DTB VSEC."""
        hdr = await self.cfg_read(ep, VSEC_REG)
        vsec = await self.cfg_read(ep, VSEC_REG + 1)
        epid = await self.cfg_read(ep, VSEC_REG + 2)
        length = await self.cfg_read(ep, VSEC_REG + 3)
        if hdr != 0x0001000B:
            self.fail(f"EP{ep} VSEC extended capability header {hdr:#010x}, expected 0x0001000b")
        if vsec != 0x02010D7B:
            self.fail(f"EP{ep} VSEC header {vsec:#010x}, expected 0x02010d7b (DTB VSEC)")
        if epid != (0x80000000 | ep):
            self.fail(f"EP{ep} endpoint ID register {epid:#010x}, expected {0x80000000 | ep:#010x}")
        words = []
        for i in range((length + 3) // 4):
            await self.cfg_write(ep, VSEC_REG + 4, i)
            words.append(await self.cfg_read(ep, VSEC_REG + 5))
        blob = b"".join(w.to_bytes(4, "little") for w in words)[:length]
        return blob

    async def check_dtb(self, dtb_path):
        with open(dtb_path, "rb") as f:
            ref = f.read()
        for ep in range(EPS):
            blob = await self.read_dtb(ep)
            dtb = lzma.decompress(blob, format=lzma.FORMAT_XZ)
            if dtb != ref:
                self.fail(f"EP{ep} DTB read over cfg_ext differs from {dtb_path}")
            for name in (b"scratchpad_status0", b"scratchpad_status1", b"mi_test_space", b"ALVEO_V80"):
                if name not in dtb:
                    self.fail(f"EP{ep} DTB lacks {name!r}")
            self.st.cov["dtb_reads"] += 1
            # the rest of 0x600-0xFFC reads as zero, below it the core answers itself
            for reg in (VSEC_REG + 8, VSEC_REG + 0x40, EXT_LAST_REG):
                if await self.cfg_read(ep, reg) != 0:
                    self.fail(f"EP{ep} cfg_ext register {reg:#x} not zero")
            for reg in (0x10, 0x40, VSEC_REG - 1):
                await self.cfg_read(ep, reg, expect_dv=False)
            self.st.cov["cfg_ext_filler_checks"] += 1
