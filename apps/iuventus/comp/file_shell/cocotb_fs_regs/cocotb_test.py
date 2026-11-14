# cocotb_test.py: does FS_REGS implement the file shell register map, ring window and tail fence?
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

"""MI through cocotbext.ofm's MIRequestDriver; the ring side is a Python FS_HBM_PORT stand-in with
random RDY, read latency and B latency behind RING_WR_PENDING; the args side a cocotbext-axi
AxiLiteRam with random pauses. Reference: fs_regs_model."""

import os
from collections import deque

import cocotb
from cocotb.triggers import RisingEdge, Timer, ClockCycles

from cocotbext.axi import AxiLiteBus, AxiLiteRam
from cocotbext.ofm.mi.drivers import MIRequestDriver

import fs_ctx as fc
import fs_regs_model as rm
from fs_axi_util import pause_channels, quiet
from fs_tb_util import release_reset, seeded, settle, start_clock

STREAMS = int(os.environ.get("STREAMS", 8))


class Env:
    def __init__(self, dut, salt):
        self.dut = dut
        self.rng = seeded(salt)
        self.model = rm.FsRegsModel(STREAMS)
        self.st = rm.Status(STREAMS)
        self.mi = MIRequestDriver(dut, "MI", dut.CLK)
        self.args = AxiLiteRam(AxiLiteBus.from_prefix(dut, "ARG_AXIL"), dut.CLK, dut.RESET,
                               reset_active_level=True, size=4096)
        quiet(self.args)
        pause_channels(self.args, self.rng, 0.4)
        self.ring_mem = {}
        self.ring_rsp = deque()           # (due cycle, data)
        self.b_due = []                   # due cycles of ring writes still without B
        self.ring_rdy_prob = 0.5
        self.cycle = 0
        self.errors = []
        self.pulses = [0, 0, 0]
        self.prev_tails = None
        self.prev_pending = 0
        self.args_b = 0
        self.cov = {"tail_fenced": 0, "ring_rd": 0, "ring_wr": 0, "args": 0, "busy_ignored": 0}
        start_clock(dut)
        dut.RESET.value = 1
        dut.CLEAR.value = 0
        dut.RING_REQ_RDY.value = 0
        dut.RING_RSP_VLD.value = 0
        dut.RING_RSP_DATA.value = 0
        dut.RING_WR_PENDING.value = 0
        self.drive_status()

    async def reset(self):
        await release_reset(self.dut, 8, 2)
        cocotb.start_soon(self._ring_side())
        cocotb.start_soon(self._monitor())

    def drive_status(self):
        d, st = self.dut, self.st
        d.STATUS_BUSY.value = st.busy
        d.STATUS_DONE.value = st.done
        d.STATUS_ERR.value = st.err
        d.STATUS_STATE.value = st.state
        for s in range(STREAMS):
            d.IN_FILES[s].value = st.in_files[s]
            d.IN_HEAD[s].value = st.in_head[s]
            d.OUT_HEAD[s].value = st.out_head[s]
            d.IN_BYTES[s].value = st.in_bytes[s]
            d.OUT_BYTES[s].value = st.out_bytes[s]
            d.STREAM_STATUS[s].value = st.stream_status[s]
            d.ERR_INFO[s].value = st.err_info[s]

    def randomize_status(self):
        st, r = self.st, self.rng
        st.busy, st.done, st.err = r.getrandbits(1), r.getrandbits(1), r.getrandbits(1)
        st.state = r.getrandbits(8)
        for s in range(STREAMS):
            st.in_files[s] = r.getrandbits(32)
            st.in_head[s] = r.getrandbits(32)
            st.out_head[s] = r.getrandbits(32)
            st.in_bytes[s] = r.getrandbits(64)
            st.out_bytes[s] = r.getrandbits(64)
            st.stream_status[s] = r.getrandbits(4) if r.random() < 0.5 else 0
            st.err_info[s] = r.getrandbits(32)
        self.drive_status()

    # FS_HBM_PORT stand-in -------------------------------------------------------------------------
    async def _ring_side(self):
        d = self.dut
        while True:
            await RisingEdge(d.CLK)
            self.cycle += 1
            if int(d.RING_REQ_VLD.value) and int(d.RING_REQ_RDY.value):
                addr = int(d.RING_REQ_ADDR.value)
                if int(d.RING_REQ_WR.value):
                    self.ring_mem[addr >> 2] = fc.merge_be(self.ring_mem.get(addr >> 2, 0),
                                                           int(d.RING_REQ_DATA.value), int(d.RING_REQ_BE.value))
                    self.b_due.append(self.cycle + self.rng.randrange(1, 60))
                    self.cov["ring_wr"] += 1
                else:
                    self.ring_rsp.append((self.cycle + self.rng.randrange(1, 30), self.ring_mem.get(addr >> 2, 0)))
                    self.cov["ring_rd"] += 1
            await Timer(1, unit="ns")
            self.b_due = [c for c in self.b_due if c > self.cycle]
            # Pending from the cycle after the handshake until the B, as FS_HBM_PORT counts it.
            d.RING_WR_PENDING.value = int(bool(self.b_due))
            d.RING_REQ_RDY.value = int(self.rng.random() < self.ring_rdy_prob)
            d.RING_RSP_VLD.value = 0
            if self.ring_rsp and self.ring_rsp[0][0] <= self.cycle:
                d.RING_RSP_VLD.value = 1
                d.RING_RSP_DATA.value = self.ring_rsp.popleft()[1]
            else:
                d.RING_RSP_DATA.value = self.rng.getrandbits(32)

    # Monitor ------------------------------------------------------------------------------------
    async def _monitor(self):
        d = self.dut
        while True:
            await RisingEdge(d.CLK)
            if int(d.RESET.value):
                continue
            for i, sig in enumerate((d.CTRL_START, d.CTRL_ABORT, d.CTRL_CLEAR)):
                self.pulses[i] += int(sig.value)
            tails = [(int(d.IN_TAIL[s].value), int(d.OUT_TAIL[s].value)) for s in range(STREAMS)]
            if self.prev_tails is not None and tails != self.prev_tails and any(t != (0, 0) for t in tails):
                if self.prev_pending:
                    self.errors.append("a tail moved while ring writes were still without B")
            self.prev_tails = tails
            self.prev_pending = int(d.RING_WR_PENDING.value)
            if int(d.ARG_AXIL_BVALID.value) and int(d.ARG_AXIL_BREADY.value):
                self.args_b += 1

    def check(self):
        assert not self.errors, "\n".join(self.errors[:20])

    # Accesses -----------------------------------------------------------------------------------
    def rand_addr(self):
        r = self.rng
        kind = r.random()
        if kind < 0.25:
            a = r.choice([fc.REG_CTRL, fc.REG_STATUS, fc.REG_STREAM_MASK, fc.REG_VERSION, fc.REG_RING_DEPTHS,
                          fc.REG_KERNEL_ID, fc.REG_STRIPE, 0x1C, 0xFC])
        elif kind < 0.6:
            a = fc.STREAM_BASE + r.randrange(fc.MAX_STREAMS) * fc.STREAM_STRIDE + 4 * r.randrange(16)
        elif kind < 0.7:
            a = fc.ARGS_BASE + 4 * r.randrange(1024)
        elif kind < 0.9:
            a = fc.RING_MI_BASE + 4 * r.randrange(0x400000)
        else:
            a = r.choice([0x400, 0x800, 0x2000, 0x7F_FFFC, 0x180_0000, 0x1FF_FFFC])
        # Bits above the 25 decoded ones belong to the MI address space of the whole card.
        return a | (r.getrandbits(7) << 25)

    async def access(self, wr, addr, data=0):
        kind = rm.decode(addr, STREAMS)
        b_before = self.args_b
        if wr:
            if kind[0] == "global" and kind[1] in (fc.REG_STREAM_MASK, fc.REG_STRIPE) and self.st.busy:
                self.cov["busy_ignored"] += 1
            if kind[0] == "stream" and kind[2] in (fc.S_IN_TAIL, fc.S_OUT_TAIL) and self.b_due:
                self.cov["tail_fenced"] += 1
            pulses_before = list(self.pulses)
            await self.mi.write32(addr, data)
            await ClockCycles(self.dut.CLK, 2)
            exp = self.model.write(addr, data, self.st)
            got = [self.pulses[i] - pulses_before[i] for i in range(3)]
            if got != list(exp):
                self.errors.append(f"CTRL pulses {got} after writing 0x{data:x} to 0x{addr:x}, expected {list(exp)}")
            if kind[0] == "args":
                self.cov["args"] += 1
                if self.args_b == b_before:
                    self.errors.append("args write acknowledged before its B")
                want = data
                got_mem = int.from_bytes(self.args.read(kind[1], 4), "little")
                if got_mem != want:
                    self.errors.append(f"args 0x{kind[1]:x} holds 0x{got_mem:08x}, expected 0x{want:08x}")
        else:
            got = await self.mi.read32(addr)
            if kind[0] == "ring":
                want = self.ring_mem.get(kind[1] >> 2, 0)
            elif kind[0] == "args":
                want = int.from_bytes(self.args.read(kind[1], 4), "little")
                self.cov["args"] += 1
            else:
                want = self.model.read(addr, self.st)
            if got != want:
                self.errors.append(f"read 0x{addr & fc.DECODE_MASK:07x} ({kind}): 0x{got:08x}, expected 0x{want:08x}")

    def check_outputs(self):
        d, m = self.dut, self.model
        assert int(d.STREAM_MASK.value) == m.stream_mask
        assert int(d.STRIPE_LOG2_DRIVES.value) == m.drives and int(d.STRIPE_LOG2_CHUNK.value) == m.chunk
        for s in range(STREAMS):
            assert int(d.IN_TAIL[s].value) == m.in_tail[s], f"IN_TAIL({s})"
            assert int(d.OUT_TAIL[s].value) == m.out_tail[s], f"OUT_TAIL({s})"


@cocotb.test()
async def test_register_map(dut):
    """Random reads and writes over every region; status inputs change between accesses."""
    env = Env(dut, 1)
    await env.reset()
    for _ in range(500):
        if env.rng.random() < 0.3:
            env.randomize_status()
        env.ring_rdy_prob = env.rng.choice([0.2, 0.7, 1.0])
        addr = env.rand_addr()
        await env.access(env.rng.random() < 0.5, addr, env.rng.getrandbits(32))
        await ClockCycles(dut.CLK, env.rng.randrange(0, 4))
        env.check()
        env.check_outputs()
    dut._log.info(f"coverage: {env.cov}")
    assert env.cov["busy_ignored"] > 0 and env.cov["ring_rd"] > 0 and env.cov["args"] > 0


@cocotb.test()
async def test_tail_fence(dut):
    """Entries then their tail, as the host does: the tail lands only after every ring write's B."""
    env = Env(dut, 2)
    await env.reset()
    for _ in range(40):
        s = env.rng.randrange(STREAMS)
        n = env.rng.randrange(1, 9)
        for k in range(4 * n):
            await env.access(True, fc.IN_RING_BASE + s * fc.IN_RING_STRIDE + 4 * env.rng.randrange(4096),
                             env.rng.getrandbits(32))
        reg = env.rng.choice([fc.S_IN_TAIL, fc.S_OUT_TAIL])
        await env.access(True, fc.STREAM_BASE + s * fc.STREAM_STRIDE + reg, env.rng.getrandbits(32))
        env.check()
        env.check_outputs()
    dut._log.info(f"coverage: {env.cov}")
    assert env.cov["tail_fenced"] > 0


@cocotb.test()
async def test_counter_latch(dut):
    """Reading a counter's low word latches its high word for the next high-word read."""
    env = Env(dut, 3)
    await env.reset()
    for _ in range(60):
        s = env.rng.randrange(STREAMS)
        lo, hi = env.rng.choice([(fc.S_IN_BYTES_LO, fc.S_IN_BYTES_HI), (fc.S_OUT_BYTES_LO, fc.S_OUT_BYTES_HI)])
        env.randomize_status()
        await env.access(False, fc.STREAM_BASE + s * fc.STREAM_STRIDE + lo)
        env.randomize_status()
        await env.access(False, fc.STREAM_BASE + s * fc.STREAM_STRIDE + hi)
        env.check()


@cocotb.test()
async def test_clear(dut):
    """CTRL.CLEAR and the CLEAR input zero the tails; configuration stays."""
    env = Env(dut, 4)
    await env.reset()
    env.st.busy = 0
    env.drive_status()
    for _ in range(10):
        for s in range(STREAMS):
            await env.access(True, fc.STREAM_BASE + s * fc.STREAM_STRIDE + fc.S_IN_TAIL, env.rng.getrandbits(32))
            await env.access(True, fc.STREAM_BASE + s * fc.STREAM_STRIDE + fc.S_OUT_TAIL, env.rng.getrandbits(32))
        await env.access(True, fc.REG_STREAM_MASK, env.rng.getrandbits(32))
        await env.access(True, fc.REG_STRIPE, env.rng.getrandbits(32))
        env.check_outputs()
        if env.rng.random() < 0.5:
            await env.access(True, fc.REG_CTRL, fc.CTRL_CLEAR | env.rng.getrandbits(2))
        else:
            await settle(dut)
            dut.CLEAR.value = 1
            await settle(dut)
            dut.CLEAR.value = 0
            env.model.clear()
            await ClockCycles(dut.CLK, 2)
        env.check_outputs()
        env.check()
