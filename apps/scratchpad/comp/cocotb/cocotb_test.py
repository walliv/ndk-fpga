# cocotb_test.py: Integration tests of the scratchpad CORE_LOGIC (CPM5 PCIe module, PCIE_BAR2AXI, MTC, MI)
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import os
import random

import cocotb
from cocotb.triggers import ClockCycles

from scratchpad_env import EPS, SPAD_APERTURE, ScratchpadEnv, SharedState, env_int

TLPS = env_int("SPAD_TLPS", 1500)
WALL_S = 540.0
DTB_PATH = os.path.join(os.environ.get("NETCOPE_TEMP", "netcope_tmp/"), "DevTree.dtb")

# The design keeps its memory, test spaces and counters from one test to the next
_STATE = {}


def shared():
    if "st" not in _STATE:
        _STATE["st"] = SharedState(random.getrandbits(32))
    return _STATE["st"]


def bes(rng, off, dw, allow_zero=True):
    """First/last byte enables PCIe allows for a request of ``dw`` DWs at ``off``."""
    if dw == 1:
        return (rng.randrange(16) if allow_zero else rng.randrange(1, 16)), 0
    if dw == 2 and off % 8 == 0 and rng.random() < 0.5:
        return rng.randrange(1, 16), rng.randrange(1, 16)
    return rng.choice([0xF, 0xF, 0xE, 0xC, 0x8]), rng.choice([0xF, 0xF, 0x7, 0x3, 0x1])


def rand_len(rng, max_dw):
    c = rng.random()
    if c < 0.3:
        dw = rng.randint(1, 4)
    elif c < 0.7:
        dw = rng.randint(5, 40)
    elif c < 0.9:
        dw = rng.randint(41, max_dw // 2)
    else:
        dw = rng.randint(max_dw // 2, max_dw)
    return min(dw, max_dw)


class Region:
    """DW-aligned offsets inside [lo, hi) of the window that keep a request inside one 4 KB page,
    biased to page ends, 128 B chunk edges and recently written data."""

    def __init__(self, rng, lo, hi):
        self.rng = rng
        self.lo = lo
        self.hi = hi
        self.hot = rng.randrange(lo, hi - 65536, 4096)
        self.recent = []

    def pick(self, nbytes):
        r = self.rng
        mode = r.choices(["hot", "page_end", "chunk_edge", "any", "recent", "top"], [40, 12, 15, 8, 20, 5])[0]
        if mode == "recent" and self.recent:
            base, n = r.choice(self.recent)
            off = base + r.randrange(0, max(1, n), 4) - r.randrange(0, 256, 4)
        elif mode == "page_end":
            off = r.randrange(self.lo, self.hi, 4096) + 4096 - nbytes - r.choice([0, 0, 4, 64, 128])
        elif mode == "chunk_edge":
            off = self.hot + r.randrange(0, 65536, 128) + r.choice([-8, -4, 0, 4, 120, 124])
        elif mode == "top":
            off = self.hi - nbytes - r.choice([0, 0, 4, 128])
        elif mode == "any":
            off = r.randrange(self.lo, self.hi, 4)
        else:
            off = self.hot + r.randrange(0, 65536, 4)
        off = max(self.lo, min(off, self.hi - nbytes)) & ~3
        if (off & 0xFFF) + nbytes > 4096:
            off = (off & ~0xFFF) + 4096 - nbytes
        return off

    def note(self, off, nbytes):
        self.recent.append((off, nbytes))
        if len(self.recent) > 64:
            self.recent.pop(0)


async def mi_traffic(env, ep, n):
    """Test-space writes and reads through endpoint ``ep``'s PF0 BAR0 (MTC)."""
    e = env.eps[ep]
    r = random.Random(env.rng.getrandbits(32))
    for _ in range(n):
        await env.throttle(ep)
        dw = r.randint(1, 4)
        # the test space decodes MI address bits 7:2 and spans 0x0-0x13F_FFFF of the MI space, the
        # PCIe debug space follows; a request at the top of the window must not run into it
        base = r.choice([0, 0, 0x1000, 0x10_0000, 0x13F_FF00])
        addr = base + r.randrange(0, 256 - (4 * dw if base == 0x13F_FF00 else 0) + 4, 4)
        fbe, lbe = bes(r, addr, dw, allow_zero=False)
        if r.random() < 0.5:
            e.mi_wr(addr, dw, fbe, lbe)
        else:
            e.mi_rd(addr, dw, fbe, lbe)


async def ep_traffic(env, ep, n, region, other, mix):
    """Random scratchpad traffic of endpoint ``ep`` in ``region``; reads of ``other`` (the other
    endpoint's region) only cover bytes its committed writes produced."""
    e = env.eps[ep]
    o = env.eps[1 - ep]
    r = random.Random(env.rng.getrandbits(32))
    kinds, weights = zip(*mix.items())
    for i in range(n):
        await env.throttle(ep)
        kind = r.choices(kinds, weights)[0]
        if kind == "wr":
            dw = rand_len(r, 256)
            off = region.pick(4 * dw)
            fbe, lbe = bes(r, off, dw)
            e.mem_wr(off, dw, fbe, lbe)
            region.note(off, 4 * dw)
        elif kind == "rd":
            dw = rand_len(r, 1024)
            off = region.pick(4 * dw)
            fbe, lbe = bes(r, off, dw)
            e.mem_rd(off, dw, fbe, lbe)
        elif kind == "ur":
            e.unsupported(r.choice(["rd_bar2", "rd_func0_bar2", "rd_func2", "iord", "wr_bar2"]))
        elif kind == "mi":
            dw = r.randint(1, 4)
            addr = r.randrange(0, 256, 4)
            fbe, lbe = bes(r, addr, dw, allow_zero=False)
            if r.random() < 0.5:
                e.mi_wr(addr, dw, fbe, lbe)
            else:
                e.mi_rd(addr, dw, fbe, lbe)
        elif kind == "cross" and other.recent:
            base, nbytes = r.choice(other.recent)
            dw = max(1, min(nbytes // 4, r.randint(1, 256)))
            off = base & ~3
            if (off & 0xFFF) + 4 * dw > 4096:
                dw = (4096 - (off & 0xFFF)) // 4
            lo = 0x40_0000_0000 + off
            if max(env.st.ref.last_seq(lo + b) for b in range(4 * dw)) <= o.committed:
                fbe, lbe = bes(r, off, dw)
                e.mem_rd(off, dw, fbe, lbe, cross=True)
        if i % 64 == 0:
            env.wall_check()


@cocotb.test(timeout_time=20, timeout_unit="ms")
async def test_dtb_mi_status(dut):
    """DTB through cfg_ext on both endpoints, MI test spaces through each MTC, status block IDs."""
    env = ScratchpadEnv(dut, "dtb_mi_status", shared(), wall_limit_s=WALL_S)
    await env.start()
    await env.check_dtb(DTB_PATH)
    for _ in range(3):
        tasks = [cocotb.start_soon(mi_traffic(env, ep, 60)) for ep in range(EPS)]
        for t in tasks:
            await t
        await env.drain()
    await env.check_status("initial")
    await env.finish(minima={"dtb_reads": 2, "cfg_ext_filler_checks": 2, "ep0_mi_wr": 40, "ep1_mi_wr": 40,
                             "done_mi_rd": 80, "status_checks": 2})


@cocotb.test(timeout_time=200, timeout_unit="ms")
async def test_random_mix(dut):
    """Both endpoints at once: MemWr/MemRd in their own half of the window, reads of the other
    endpoint's committed writes, UR and dropped requests, MI accesses; random CQ gaps and CC/AXI backpressure."""
    env = ScratchpadEnv(dut, "random_mix", shared(), wall_limit_s=WALL_S)
    await env.start()
    half = 1 << (SPAD_APERTURE - 1)
    regions = [Region(random.Random(env.rng.getrandbits(32)), 0, half),
               Region(random.Random(env.rng.getrandbits(32)), half, 2 * half)]
    mix = {"wr": 42, "rd": 38, "ur": 5, "mi": 7, "cross": 8}
    # a short single-endpoint prelude writes data the other endpoint may then read
    for ep in range(EPS):
        await ep_traffic(env, ep, 40, regions[ep], regions[1 - ep], {"wr": 1})
        await env.flush(ep)
    # the corner cases the CC path must handle: the largest write and read, 32 completions, zero length
    e0 = env.eps[0]
    e0.mem_wr(0x1000, 256, 0xF, 0xF)
    e0.mem_rd(0x1000, 1024, 0xF, 0xF)
    e0.mem_rd(0x2000 + 0x7C, 1, 0, 0)
    tasks = [cocotb.start_soon(ep_traffic(env, ep, TLPS, regions[ep], regions[1 - ep], mix)) for ep in range(EPS)]
    for t in tasks:
        await t
    # the CC conditioner starts every completion in slot 0 of a fresh beat, so only the CQ straddles
    await env.finish(minima={"done_rd": TLPS // 2, "done_ur": TLPS // 40, "dropped": TLPS // 200, "max_write": 1,
                             "max_read": 1, "read_32_cpl": 1, "zero_len_read": 1, "read_to_page_end": 5,
                             "write_to_page_end": 5, "read_over_128B": TLPS // 10, "write_over_128B": TLPS // 10,
                             "cross_ep_reads": TLPS // 40, "cross_ep_bytes": 1000, "done_mi_rd": TLPS // 50,
                             "relaxed_bytes": 1, "cc0_stall_mid_tlp": 10, "cc1_stall_mid_tlp": 10,
                             "cq0_sops_2": 10, "cq1_sops_2": 10, "cq0_sops_4": 1, "cq1_sops_4": 1,
                             "cq0_tlp_3plus_beats": 10, "cq1_tlp_3plus_beats": 10})


@cocotb.test(timeout_time=200, timeout_unit="ms")
async def test_shared_window(dut):
    """Write through one endpoint, read the same bytes through the other, in both directions and
    over the whole window, page ends and 128 B chunk edges included."""
    env = ScratchpadEnv(dut, "shared_window", shared(), wall_limit_s=WALL_S)
    await env.start()
    r = random.Random(env.rng.getrandbits(32))
    size = 1 << SPAD_APERTURE
    rounds = max(8, TLPS // 40)
    for rnd in range(rounds):
        wr_ep = rnd % 2
        rd_ep = 1 - wr_ep
        e_w = env.eps[wr_ep]
        e_r = env.eps[rd_ep]
        # one block per round, split into TLPs as a host would (4 KB pages, 1 KB writes, 4 KB reads)
        nbytes = r.choice([4, 64, 128, 132, 1024, 2048, 4096, 8192, 12288])
        place = r.choice(["page_end", "chunk_edge", "any", "bottom", "top"])
        if place == "page_end":
            start = r.randrange(0, size - 16384, 4096) + 4096 - r.choice([4, 8, 64, 128, 132])
        elif place == "chunk_edge":
            start = r.randrange(0, size - 16384, 128) + r.choice([-4, 4, 124, 0])
        elif place == "bottom":
            start = r.randrange(0, 4096, 4)
        elif place == "top":
            start = size - nbytes - r.choice([0, 4, 128])
        else:
            start = r.randrange(0, size - 16384, 4)
        start = max(0, min(start, size - nbytes)) & ~3
        off = start
        while off < start + nbytes:
            n = min(start + nbytes - off, 1024, 4096 - (off & 0xFFF))
            dw = n // 4
            fbe, lbe = (0xF, 0xF) if dw > 1 else (0xF, 0)
            await env.throttle(wr_ep)
            e_w.mem_wr(off, dw, fbe, lbe)
            off += n
        await env.flush(wr_ep)
        off = start
        while off < start + nbytes:
            n = min(start + nbytes - off, 4096 - (off & 0xFFF), r.choice([4096, 512, 128]))
            dw = n // 4
            await env.throttle(rd_ep)
            e_r.mem_rd(off, dw, 0xF, 0xF if dw > 1 else 0, cross=True)
            off += n
        if rnd % 8 == 7:
            await env.drain()
    await env.finish(minima={"cross_ep_reads": rounds, "cross_ep_bytes": 4 * rounds})


@cocotb.test(timeout_time=200, timeout_unit="ms")
async def test_heavy_backpressure(dut):
    """The random mix with AXI ready/valid and CC TREADY mostly low and dense CQ straddling."""
    axi = dict(p_awready=0.2, p_wready=0.25, p_arready=0.15, p_bvalid=0.2, p_rvalid=0.25, commit_lat=(5, 120),
               b_lat=(0, 30), r_lat=(10, 150))
    env = ScratchpadEnv(dut, "heavy_backpressure", shared(), wall_limit_s=WALL_S, axi_cfg=axi,
                        cc_phases=(0.0, 0.1, 0.2, 0.5), p_share=0.97)
    await env.start()
    half = 1 << (SPAD_APERTURE - 1)
    regions = [Region(random.Random(env.rng.getrandbits(32)), 0, half),
               Region(random.Random(env.rng.getrandbits(32)), half, 2 * half)]
    mix = {"wr": 45, "rd": 40, "ur": 5, "mi": 5, "cross": 5}
    tasks = [cocotb.start_soon(ep_traffic(env, ep, max(200, TLPS // 3), regions[ep], regions[1 - ep], mix))
             for ep in range(EPS)]
    for t in tasks:
        await t
    await ClockCycles(env.clk, 10)
    await env.finish(minima={"done_rd": 100})
