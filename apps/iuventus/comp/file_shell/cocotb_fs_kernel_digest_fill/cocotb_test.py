# cocotb_test.py: does DIGEST_FILL emit the fill pattern and the exact digest of unordered input?
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

"""Stimulus: random files cut into beats, shuffled across lanes with random gaps; AXI4-Lite args
through cocotbext-axi; OUT_RDY toggled at random. Reference: fs_kernel_digest_fill_model."""

import os

import cocotb
from cocotb.triggers import RisingEdge, ClockCycles

from cocotbext.axi import AxiLiteBus, AxiLiteMaster

import fs_kernel_digest_fill_model as model
from fs_axi_util import quiet
from fs_ctx import BEAT, merge_be
from fs_tb_util import release_reset, seeded, settle, start_clock

LANES = int(os.environ.get("LANES", 2))


class Env:
    def __init__(self, dut, salt=0):
        self.dut = dut
        self.rng = seeded(salt)
        self.axil = AxiLiteMaster(AxiLiteBus.from_prefix(dut, "S_AXIL"), dut.CLK, dut.RESET,
                                  reset_active_level=True)
        quiet(self.axil)
        self.out = []
        self.rdy_prob = 0.7
        self.ended = False
        self.cov = {"out_before_end": 0, "out_stall": 0, "both_lanes": 0, "partial_beats": 0}
        start_clock(dut)
        dut.RESET.value = 1
        dut.CLEAR.value = 0
        dut.START.value = 0
        dut.IN_VLD.value = 0
        dut.IN_END.value = 0
        dut.IN_FILES.value = 0
        dut.OUT_RDY.value = 0
        for lane in range(LANES):
            dut.IN_DATA[lane].value = 0
            dut.IN_BYTES[lane].value = 0
            dut.IN_FIDX[lane].value = 0
            dut.IN_FOFS[lane].value = 0
            dut.IN_COFS[lane].value = 0

    async def reset(self):
        await release_reset(self.dut, 8, 4)
        cocotb.start_soon(self._rdy_driver())
        cocotb.start_soon(self._monitor())

    async def _rdy_driver(self):
        while True:
            await settle(self.dut)
            self.dut.OUT_RDY.value = int(self.rng.random() < self.rdy_prob)

    async def _monitor(self):
        d = self.dut
        while True:
            await RisingEdge(d.CLK)
            if int(d.RESET.value):
                continue
            assert int(d.IN_RDY.value) == (1 << LANES) - 1, "IN_RDY must stay high"
            vld = int(d.OUT_VLD.value)
            rdy = int(d.OUT_RDY.value)
            if vld and not rdy:
                self.cov["out_stall"] += 1
            if vld and rdy:
                data = int(d.OUT_DATA.value).to_bytes(BEAT, "little")
                self.out.append((data, int(d.OUT_BYTES.value), bool(int(d.OUT_LAST.value))))
                if not self.ended:
                    self.cov["out_before_end"] += 1

    async def pulse(self, sig):
        await settle(self.dut)
        sig.value = 1
        await settle(self.dut)
        sig.value = 0

    async def set_args(self, fill_bytes, seed):
        await self.axil.write_dword(0x00, fill_bytes & 0xFFFFFFFF)
        await self.axil.write_dword(0x04, fill_bytes >> 32)
        await self.axil.write_dword(0x08, seed)

    async def feed(self, beats, nfiles, end_with_last=False, vld_prob=0.6):
        """Shuffled beats over the lanes; IN_END after the last one, or in its cycle."""
        d = self.dut
        d.IN_FILES.value = nfiles
        queue = list(beats)
        self.rng.shuffle(queue)
        end_with_last = end_with_last and bool(queue)
        while queue:
            await settle(d)
            vmask = 0
            for lane in range(LANES):
                if queue and self.rng.random() < vld_prob:
                    data, nbytes, fidx, fofs = queue.pop()
                    d.IN_DATA[lane].value = int.from_bytes(data, "little")
                    d.IN_BYTES[lane].value = nbytes
                    d.IN_FIDX[lane].value = fidx
                    d.IN_FOFS[lane].value = fofs
                    d.IN_COFS[lane].value = self.rng.getrandbits(64)
                    vmask |= 1 << lane
                    if nbytes < BEAT:
                        self.cov["partial_beats"] += 1
            if vmask == (1 << LANES) - 1 and LANES > 1:
                self.cov["both_lanes"] += 1
            d.IN_VLD.value = vmask
            if not queue and end_with_last:
                d.IN_END.value = 1
        if not end_with_last:
            await settle(d)
            d.IN_VLD.value = 0
            for _ in range(self.rng.randrange(0, 4)):
                await settle(d)
            d.IN_END.value = 1
        await settle(d)
        d.IN_VLD.value = 0
        d.IN_END.value = 0
        self.ended = True

    async def wait_last(self, timeout=200000):
        for _ in range(timeout):
            if self.out and self.out[-1][2]:
                return
            await RisingEdge(self.dut.CLK)
        raise AssertionError("no OUT_LAST within the timeout")

    async def run_job(self, files, fill_bytes, seed, end_with_last=False, vld_prob=0.6):
        self.out.clear()
        self.ended = False
        await self.set_args(fill_bytes, seed)
        await self.pulse(self.dut.START)
        assert int(self.dut.ARG_ERR.value) == 0, "ARG_ERR on valid arguments"
        beats = [b for fidx, data in files for b in model.file_beats(fidx, data)]
        ref = model.BeatDigest()
        for b in beats:
            ref.beat(*b)
        digest = model.file_digest(files)
        assert (ref.total, ref.sum, ref.xor) == digest[:3], "the two references disagree"
        await ClockCycles(self.dut.CLK, self.rng.randrange(0, 40))
        await self.feed(beats, len(files), end_with_last, vld_prob)
        await self.wait_last()
        await ClockCycles(self.dut.CLK, 20)
        assert int(self.dut.ARG_ERR.value) == 0, "ARG_ERR on valid arguments"
        check_output(self.out, model.output_beats(fill_bytes, seed, digest))


def check_output(got, exp):
    assert len(got) == len(exp), f"{len(got)} output beats, expected {len(exp)}"
    for i, ((gd, gb, gl), (ed, eb, el)) in enumerate(zip(got, exp)):
        assert gb == eb, f"beat {i}: OUT_BYTES {gb}, expected {eb}"
        assert gl == el, f"beat {i}: OUT_LAST {gl}, expected {el}"
        assert gd[:gb] == ed[:eb], f"beat {i}: data\n got {gd[:gb].hex()}\n exp {ed[:eb].hex()}"


def random_files(rng, nfiles):
    sizes = [0, 1, 7, 8, 9, 63, 64, 65, 511, 512, 4096]
    files = []
    for i in range(nfiles):
        size = rng.choice(sizes) if rng.random() < 0.4 else rng.randrange(0, 3000)
        fidx = i if rng.random() < 0.7 else rng.getrandbits(32)
        files.append((fidx, rng.randbytes(size)))
    return files


@cocotb.test()
async def test_jobs_random(dut):
    """Back-to-back jobs: random files, fill sizes and seeds, IN_END after or with the last beat."""
    env = Env(dut, 1)
    await env.reset()
    for job in range(8):
        files = random_files(env.rng, env.rng.randrange(0, 12))
        fill = BEAT * env.rng.choice([0, 1, 2, env.rng.randrange(1, 300)])
        if job % 3 == 0:
            fill = BEAT * env.rng.randrange(20, 300)
        seed = env.rng.getrandbits(32)
        env.rdy_prob = (0.3, 0.7, 1.0)[job % 3]
        dut._log.info(f"job {job}: {len(files)} files, fill {fill} B, seed 0x{seed:08x}, rdy {env.rdy_prob}")
        await env.run_job(files, fill, seed, end_with_last=env.rng.random() < 0.5,
                          vld_prob=(0.2, 0.6, 1.0)[(job // 3) % 3])
    dut._log.info(f"coverage: {env.cov}")
    assert env.cov["out_stall"] > 0 and env.cov["partial_beats"] > 0
    if LANES > 1:
        assert env.cov["both_lanes"] > 0


@cocotb.test()
async def test_fill_streams_before_end(dut):
    """The pattern must flow while input is still pending; only the record waits for IN_END."""
    env = Env(dut, 2)
    await env.reset()
    env.rdy_prob = 1.0
    files = random_files(env.rng, 3)
    await env.set_args(BEAT * 50, 0x12345678)
    await env.pulse(dut.START)
    await ClockCycles(dut.CLK, 120)
    assert len(env.out) == 50, f"{len(env.out)} fill beats before any input, expected 50"
    assert not any(last for _, _, last in env.out), "record emitted before IN_END"
    beats = [b for fidx, data in files for b in model.file_beats(fidx, data)]
    await env.feed(beats, len(files))
    await env.wait_last()
    check_output(env.out, model.output_beats(BEAT * 50, 0x12345678, model.file_digest(files)))


@cocotb.test()
async def test_wide_fields(dut):
    """FIDX above 2**24 and FOFS near 2**48 exercise the shift truncation and the offset field."""
    env = Env(dut, 3)
    await env.reset()
    for _ in range(3):
        beats = []
        ref = model.BeatDigest()
        for _ in range(env.rng.randrange(1, 40)):
            nbytes = env.rng.choice([64, 64, env.rng.randrange(1, 65)])
            b = (env.rng.randbytes(BEAT), nbytes, env.rng.getrandbits(32),
                 env.rng.getrandbits(42) << 6)
            beats.append(b)
            ref.beat(*b)
        nfiles = env.rng.getrandbits(32)
        seed = env.rng.getrandbits(32)
        env.out.clear()
        env.ended = False
        await env.set_args(BEAT * 3, seed)
        await env.pulse(dut.START)
        await env.feed(beats, nfiles)
        await env.wait_last()
        check_output(env.out, model.output_beats(BEAT * 3, seed, (ref.total, ref.sum, ref.xor, nfiles)))


@cocotb.test()
async def test_clear_mid_job(dut):
    """CLEAR drops a running job; the next job's output carries nothing of it."""
    env = Env(dut, 4)
    await env.reset()
    files = random_files(env.rng, 6)
    await env.set_args(BEAT * 400, 7)
    await env.pulse(dut.START)
    beats = [b for fidx, data in files for b in model.file_beats(fidx, data)]
    for b in beats[: len(beats) // 2]:
        await settle(dut)
        dut.IN_DATA[0].value = int.from_bytes(b[0], "little")
        dut.IN_BYTES[0].value = b[1]
        dut.IN_FIDX[0].value = b[2]
        dut.IN_FOFS[0].value = b[3]
        dut.IN_VLD.value = 1
    await settle(dut)
    dut.IN_VLD.value = 0
    await env.pulse(dut.CLEAR)
    await ClockCycles(dut.CLK, 3)
    await RisingEdge(dut.CLK)
    assert int(dut.OUT_VLD.value) == 0, "output still valid after CLEAR"
    files = random_files(env.rng, 5)
    await env.run_job(files, BEAT * 5, 0xCAFEF00D)


@cocotb.test()
async def test_args_axil(dut):
    """Arguments read back as written, byte strobes honoured, other offsets read 0."""
    env = Env(dut, 5)
    await env.reset()
    regs = {0x00: 0, 0x04: 0, 0x08: 0}
    for _ in range(60):
        addr = env.rng.choice([0x00, 0x04, 0x08, 0x0C, 0x1FC, 0x100])
        if env.rng.random() < 0.5:
            val = env.rng.getrandbits(32)
            strb = env.rng.randrange(1, 16)
            data = val.to_bytes(4, "little")
            # cocotbext-axi derives WSTRB from the byte span written; write each enabled byte alone.
            for b in range(4):
                if strb >> b & 1:
                    await env.axil.write(addr + b, data[b:b + 1])
            if addr in regs:
                regs[addr] = merge_be(regs[addr], val, strb)
        else:
            got = await env.axil.read_dword(addr)
            assert got == regs.get(addr, 0), f"arg 0x{addr:03x}: read 0x{got:08x}, expected 0x{regs.get(addr, 0):08x}"


@cocotb.test()
async def test_invalid_fill_bytes(dut):
    """FILL_BYTES not a multiple of 64: ARG_ERR from the cycle after START, OUT_LAST still after IN_END."""
    env = Env(dut, 6)
    await env.reset()
    for job in range(6):
        fill = BEAT * env.rng.randrange(0, 100) + env.rng.randrange(1, BEAT)
        if job % 3 == 2:
            fill |= env.rng.getrandbits(32) << 32
        assert model.arg_err(fill)
        env.rdy_prob = (0.3, 1.0)[job % 2]
        env.out.clear()
        env.ended = False
        await env.set_args(fill, env.rng.getrandbits(32))
        await env.pulse(dut.START)
        assert int(dut.ARG_ERR.value) == 1, f"no ARG_ERR the cycle after START with FILL_BYTES 0x{fill:x}"
        files = random_files(env.rng, env.rng.randrange(0, 6))
        beats = [b for fidx, data in files for b in model.file_beats(fidx, data)]
        await ClockCycles(dut.CLK, env.rng.randrange(0, 30))
        assert int(dut.ARG_ERR.value) == 1, "ARG_ERR dropped before IN_END"
        await env.feed(beats, len(files), env.rng.random() < 0.5)
        await env.wait_last()
        await ClockCycles(dut.CLK, 40)
        lasts = [i for i, (_, _, last) in enumerate(env.out) if last]
        assert lasts == [len(env.out) - 1], f"OUT_LAST at beats {lasts} of {len(env.out)}"
        assert int(dut.ARG_ERR.value) == 1, "ARG_ERR dropped before the next START"
        if job % 2:
            await env.pulse(dut.CLEAR)
            assert int(dut.ARG_ERR.value) == 0, "CLEAR did not drop ARG_ERR"
        # A valid job right after clears ARG_ERR and is exact.
        files = random_files(env.rng, 3)
        await env.run_job(files, BEAT * env.rng.randrange(0, 20), env.rng.getrandbits(32))
