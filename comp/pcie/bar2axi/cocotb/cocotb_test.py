# cocotb_test.py: Tests of PCIE_BAR2AXI
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.triggers import ClockCycles

from bar2axi_env import Bar2AxiEnv, TbError, AddrPicker, rand_gaps
from cocotbext.ofm.pcie import PcieReqType

# Every test asserts these corner cases at its end unless it is too narrow to reach them.
CORNERS = ["max_write", "read_32_cpl", "zero_len_read", "cq_word_all_sof", "ur", "drop"]

SIM_TIMEOUT_MS = 100


async def corner_prelude(env, picker=None):
    """Directed corner cases: max-size write and read, zero-length read, all-SOF CQ words, wrong
    BAR/function and unsupported requests, boundary addresses."""
    g, cfg, r = env.gen, env.cfg, env.rng
    size = 1 << cfg.aperture
    page = r.randrange(0, size - 8192, 4096)
    max_wr_dw = cfg.max_wr // 4

    # max-size write, then a 4 KB read of its page: 32 completions of 128 B
    env.send(g.mem_wr(page, max_wr_dw, 0xF, 0xF))
    env.send(g.mem_wr(page + 4096 - cfg.max_wr, max_wr_dw, 0xF, 0xF))
    if cfg.max_rd >= 4096:
        env.send(g.mem_rd(page, 1024, 0xF, 0xF))
    # zero-length read straight after a write to the same DW, and a zero-length write
    env.send(g.mem_wr(page + 64, 1, 0xF, 0))
    env.send(g.mem_rd(page + 64, 1, 0x0, 0))
    env.send(g.mem_wr(page + 68, 1, 0x0, 0))
    # every First BE pattern of a 1-DW write, read back with a non-contiguous BE
    for fbe in range(16):
        env.send(g.mem_wr(page + 256 + 4 * fbe, 1, fbe, 0))
    env.send(g.mem_rd(page + 256, 16, 0xE, 0x7))
    env.send(g.mem_rd(page + 260, 1, 0x5, 0))
    env.send(g.mem_rd(page + 264, 2, 0x9, 0x6))
    # every start DW inside a 128 B chunk, each read crossing at least one chunk edge
    for a0 in range(32):
        env.send(g.mem_rd(page + 1024 + 4 * a0, 40 - a0 % 7, 0xF, 0xF))
    # end of the BAR window
    env.send(g.mem_wr(size - 64, 16, 0xC, 0x3))
    env.send(g.mem_rd(size - 128, 32, 0xF, 0xF))
    env.send(g.mem_wr(size - 4, 1, 0xF, 0))
    env.send(g.mem_rd(size - 4, 1, 0x8, 0))
    # wrong BAR and function: writes dropped, reads answered UR
    env.send(g.mem_wr(page, 4, 0xF, 0xF, bar=(cfg.bar_id + 1) % 7))
    env.send(g.mem_rd(page, 4, 0xF, 0xF, bar=(cfg.bar_id + 3) % 7))
    env.send(g.mem_rd(page, 8, 0xF, 0xF, func=(cfg.func_id + 1) % 256))
    env.send(g.mem_wr(page, 2, 0xF, 0xF, func=(cfg.func_id + 8) % 256))
    for _ in range(12):
        env.send(g.unsupported())
    if cfg.max_wr < 4096:
        # longer than MAX_WR_BYTES: dropped
        env.send(g.mem_wr(page, max_wr_dw + 1, 0xF, 0xF))
    await env.drain()

    # back-to-back single-region MemRd TLPs so that every CQ region of a word carries a SOF
    env.cq_drv.set_valid_generator(None)
    for _ in range(4):
        for k in range(4 * cfg.regions):
            env.send(g.mem_rd(page + 8 * k, 1 + k % 2, 0xF, 0xF if k % 2 else 0))
        await env.drain()
    if env.cq_gaps:
        env.cq_drv.set_valid_generator(rand_gaps(env.rng))


async def random_traffic(env, picker, n, mix=(45, 42, 8, 5), max_pending=6):
    """n random requests: writes, reads (half of them over recently written data), unsupported
    requests and wrong-BAR/function ones."""
    g, cfg, r = env.gen, env.cfg, env.rng
    max_wr_dw, max_rd_dw = cfg.max_wr // 4, cfg.max_rd // 4
    for i in range(n):
        kind = r.choices(["wr", "rd", "bad", "other_bar"], mix)[0]
        if kind == "wr":
            dw = r.choices([r.randint(1, 8), r.randint(9, 64), r.randint(65, max_wr_dw), max_wr_dw],
                           [35, 30, 25, 10])[0]
            dw = min(dw, max_wr_dw)
            off = picker.pick(4 * dw)
            env.send(g.mem_wr(off, dw, at=r.choice([0, 0, 0, 1, 2, 3])))
            picker.note(off, 4 * dw)
        elif kind == "rd":
            dw = r.choices([1, r.randint(1, 8), r.randint(9, 128), r.randint(129, max_rd_dw), max_rd_dw],
                           [8, 25, 35, 25, 7])[0]
            dw = min(dw, max_rd_dw)
            off = picker.pick(4 * dw, mode="recent" if r.random() < 0.5 else None)
            if dw == 1 and r.random() < 0.3:
                env.send(g.mem_rd(off, 1, 0x0, 0))
            else:
                env.send(g.mem_rd(off, dw))
        elif kind == "bad":
            env.send(g.unsupported())
        else:
            off = picker.pick(64)
            if r.random() < 0.5:
                env.send(g.mem_wr(off, 16, bar=r.choice([b for b in range(7) if b != cfg.bar_id])))
            else:
                env.send(g.mem_rd(off, 16, func=r.choice([f for f in range(16) if f != cfg.func_id])))
        await env.wait_queue(max_pending)


@cocotb.test(timeout_time=SIM_TIMEOUT_MS, timeout_unit="ms")
async def test_directed_corners(dut):
    """Directed corner cases under random backpressure on every ready signal."""
    env = Bar2AxiEnv(dut, "directed")
    await env.start()
    await corner_prelude(env)
    await env.drain()
    env.finish(required=CORNERS + ["write_to_bar_end", "write_to_page_end", "zero_len_write"])


@cocotb.test(timeout_time=SIM_TIMEOUT_MS, timeout_unit="ms")
async def test_random_mix(dut):
    """Interleaved random writes/reads with corner cases, random tags and outstanding reads."""
    env = Bar2AxiEnv(dut, "random_mix")
    await env.start()
    picker = AddrPicker(env.cfg, env.rng)
    await corner_prelude(env)
    await random_traffic(env, picker, 5000)
    await env.drain()
    env.finish(required=CORNERS)


@cocotb.test(timeout_time=SIM_TIMEOUT_MS, timeout_unit="ms")
async def test_raw_hot_window(dut):
    """Reads and writes hammer one 8 KB window while AXI writes commit late, so a read issued before
    an earlier write's B would return stale data."""
    env = Bar2AxiEnv(dut, "raw_hot", axi_cfg=dict(commit_lat=(5, 150), b_lat=(0, 20), r_lat=(0, 8)),
                     cc_rdy=0.9)
    await env.start()
    picker = AddrPicker(env.cfg, env.rng, hot_size=8192)
    g, r = env.gen, env.rng
    for _ in range(3000):
        dw = r.choice([1, 2, 4, 8, 16, 33, 64])
        off = picker.pick(4 * dw, mode="hot")
        env.send(g.mem_wr(off, dw))
        picker.note(off, 4 * dw)
        if r.random() < 0.8:
            # read right behind the write, overlapping it
            rdw = r.choice([1, 2, 8, 16, 40])
            page = off & ~0xFFF
            roff = min(max(page, off + r.randrange(-64, 64, 4)), page + 4096 - 4 * rdw)
            env.send(g.mem_rd(roff, rdw))
        await env.wait_queue(6)
    await env.drain()
    if env.model.cnt["rd"] < 2000:
        raise TbError("too few reads reached the DUT")
    env.finish()


@cocotb.test(timeout_time=SIM_TIMEOUT_MS, timeout_unit="ms")
async def test_posted_pass_blocked_read(dut):
    """With CC stalled, a read sits in flight; later writes must still reach AXI. The CQ may only
    stall once RD_OUTSTANDING non-posted requests are pending."""
    env = Bar2AxiEnv(dut, "posted_pass")
    await env.start()
    g, cfg, m = env.gen, env.cfg, env.model
    env.cc_hold = True
    base = env.rng.randrange(0, (1 << cfg.aperture) - 65536, 4096)
    env.send(g.mem_rd(base, 64, 0xF, 0xF))
    for i in range(48):
        env.send(g.mem_wr(base + 4096 + 256 * i, 64, 0xF, 0xF))
    for _ in range(4000):
        await ClockCycles(dut.CLK, 4)
        if m.wr_b_done == 48 and env.cq_mon.frame_cnt == 49:
            break
    if m.wr_b_done != 48:
        raise TbError(f"posted writes blocked behind a stalled read: {m.wr_b_done}/48 completed")
    if m.cov["cpl_tlps"] != 0:
        raise TbError("a completion left while CC_MFB_DST_RDY was held low")
    # fill the non-posted budget; the CQ has to stop accepting only after it
    for i in range(cfg.rd_outstanding + 4):
        env.send(g.mem_rd(base + 64 * i, 2, 0xF, 0xF))
    await ClockCycles(dut.CLK, 3000)
    # the DUT's own count: its input pipes may hold a few more frames than it has accepted
    accepted = int(dut.CNT_RD.value)
    if accepted != cfg.rd_outstanding:
        raise TbError(f"{accepted} reads accepted with CC stalled, RD_OUTSTANDING = {cfg.rd_outstanding}")
    env.cov["np_budget_reached"] += 1
    env.cc_hold = False
    await env.drain()
    env.finish()


@cocotb.test(timeout_time=SIM_TIMEOUT_MS, timeout_unit="ms")
async def test_heavy_backpressure(dut):
    """Rare ready/valid on every AXI channel and on CC, deep reorder of read vs write latency."""
    env = Bar2AxiEnv(dut, "heavy_bp", axi_cfg=dict(p_awready=0.15, p_wready=0.2, p_arready=0.15,
                                                   p_bvalid=0.2, p_rvalid=0.25, commit_lat=(0, 80),
                                                   b_lat=(0, 40), r_lat=(0, 120)),
                     cc_rdy=0.2)
    await env.start()
    picker = AddrPicker(env.cfg, env.rng, hot_size=32768)
    await random_traffic(env, picker, 1200)
    await env.drain(max_cycles=1500000)
    env.finish()


@cocotb.test(timeout_time=SIM_TIMEOUT_MS, timeout_unit="ms")
async def test_axi_error_responses(dut):
    """SLVERR on some B and R responses: the DUT keeps going and counts every error response."""
    env = Bar2AxiEnv(dut, "axi_err", axi_cfg=dict(err_prob=0.1))
    await env.start()
    picker = AddrPicker(env.cfg, env.rng)
    await random_traffic(env, picker, 1000, mix=(50, 50, 0, 0))
    await env.drain()
    if env.axi.stats["err_b"] == 0 or env.axi.stats["err_r"] == 0:
        raise TbError(f"no error injected: {env.axi.stats}")
    env.finish()
