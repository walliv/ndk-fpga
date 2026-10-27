# cocotb_test.py: verification of MFB_MERGER_SIMPLE
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0
"""Two seeded MFB streams into MFB_MERGER_SIMPLE under random TX DST_RDY: the output must interleave both input frame
sequences in order, unaltered, and in the arrival order mode keep the order of their accepted SOFs."""

import os
from collections import deque

import cocotb
import cocotbext.ofm.mfb.fast_drivers
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

from cocotbext.ofm.mfb.fast_drivers import MFBDriver
from cocotbext.ofm.mfb.fast_monitors import MFBMonitor
from cocotbext.ofm.mfb.properties import MFBProperty, final_check_all
from cocotbext.ofm.mfb.transaction import MfbTransactionWithMeta
from cocotbext.ofm.utils.random import named_rngs
from cocotbext.ofm.utils.signals import generic_bool, signal_binstr, signal_handshake
from cocotbext.ofm.ver.scoreboard import MergeChecker, Report

CLK_NS = 4
STALL_LIMIT_CYCLES = 20_000
INT_GENERICS = ("REGIONS", "REGION_SIZE", "BLOCK_SIZE", "ITEM_WIDTH", "META_WIDTH", "CNT_MAX")
BOOL_GENERICS = ("MASKING_EN", "ARRIVAL_ORDER_EN")


class GapGen:
    """(valid, idle) block runs for MFBDriver: long bursts, sparse single blocks or random mixes, switched
    at random, so an input is sometimes idle while the other one is saturated."""

    def __init__(self, rng, blocks_per_word):
        self.rng = rng
        self.w = blocks_per_word
        self.left = 0
        self.kind = 0

    def __iter__(self):
        return self

    def __next__(self):
        rng, w = self.rng, self.w
        if self.left <= 0:
            self.kind = rng.randrange(4)
            self.left = rng.randint(4, 64)
        self.left -= 1
        if self.kind == 0:
            return (rng.randint(8, 64) * w, 0)
        if self.kind == 1:
            return (1, rng.randint(1, 8) * w)
        if self.kind == 2:
            return (rng.randint(1, 4 * w), rng.randint(0, 4 * w))
        return (rng.randint(1, 2 * w), rng.randint(16, 128) * w)


async def drive_dst_rdy(signal, clock, rng):
    """Random DST_RDY in runs: always ready, never ready, or a random duty cycle."""
    edge = RisingEdge(clock)
    while True:
        kind = rng.randrange(3)
        duty = (1.0, 0.0, rng.random())[kind]
        cycles = rng.randint(1, 40) if kind == 1 else rng.randint(10, 200)
        for _ in range(cycles):
            signal.value = int(rng.random() < duty)
            await edge


class MergerBench:
    def __init__(self, dut, saturate):
        self.dut = dut
        self.log = dut._log
        self.saturate = saturate
        self.gen = {name: int(getattr(dut, name).value) for name in INT_GENERICS}
        self.gen.update({name: generic_bool(getattr(dut, name)) for name in BOOL_GENERICS})
        g = self.gen
        self.params = {"regions": g["REGIONS"], "region_size": g["REGION_SIZE"], "block_size": g["BLOCK_SIZE"],
                       "item_width": g["ITEM_WIDTH"], "meta_width": g["META_WIDTH"]}
        self.item_bytes = g["ITEM_WIDTH"] // 8
        self.word_items = g["REGIONS"] * g["REGION_SIZE"] * g["BLOCK_SIZE"]
        self.rngs = named_rngs("rst", "pkt0", "pkt1", "gap0", "gap1", "rdy")
        self.frames = int(os.environ.get("MERGER_FRAMES", "3000"))
        # In the arrival order mode no frame may leave before a frame of the other input accepted earlier. MERGER_ORDER_CHECK
        # keeps the check of an A/B run on an elaboration without that mode.
        self.order_check = os.environ.get("MERGER_ORDER_CHECK", "1" if g["ARRIVAL_ORDER_EN"] else "0") == "1"
        self.report = Report(self.log)
        self.cycles = 0
        # Accepted input frames not yet seen on the output, tagged with the cycle of their SOF, and per input the SOF
        # cycles of frames accepted but not yet complete.
        self.merge = MergeChecker(self.report, ("input 0", "input 1"), "TX_MFB",
                                  lambda f: f"{len(f[0])} B, META {f[1]:#x}")
        self.sof_cycles = (deque(), deque())
        self.in_frames = [0, 0]
        self.out_from = [0, 0]
        self.last_out_cycle = 0
        # Output frames that left before a frame of the other input whose SOF was accepted earlier.
        self.overtakes = 0
        self.overtake_wait_max = 0
        self.win = {"rdy_cycles": 0, "words": 0, "items": 0}

    def build(self):
        d, clk = self.dut, self.dut.CLK
        d.TX_MFB_DST_RDY.value = 0
        d.RST.value = 1
        blocks = self.gen["REGIONS"] * self.gen["REGION_SIZE"]
        self.drv = [MFBDriver(d, f"RX_MFB{i}", clk, mfb_params=self.params,
                              vld_gen=None if self.saturate else GapGen(self.rngs[f"gap{i}"], blocks))
                    for i in (0, 1)]

        def mon(name, cb):
            m = MFBMonitor(d, name, clk, mfb_params=self.params, trans_type=MfbTransactionWithMeta, start=False)
            m.add_callback(cb)
            return m

        self.in_mons = [mon(f"RX_MFB{i}", lambda t, i=i: self._on_in(i, t)) for i in (0, 1)]
        self.out_mon = mon("TX_MFB", self._on_out)
        self.props = {n: MFBProperty(d, n, clk, reset=d.RST, mfb_params=self.params, start=False)
                      for n in ("RX_MFB0", "RX_MFB1", "TX_MFB")}

    # ------------------------------------------------------------------------------------------
    def _on_in(self, i, t):
        self.merge.add_in(i, (t.data, t.meta), self.sof_cycles[i].popleft())
        self.in_frames[i] += 1

    def _on_out(self, t):
        self.last_out_cycle = self.cycles
        hit = self.merge.add_out((t.data, t.meta), f"cycle {self.cycles}")
        if hit is None:
            return
        i, arrived = hit
        self.out_from[i] += 1
        if self._in_window():
            self.win["items"] += len(t.data) // self.item_bytes
        j = 1 - i
        pending = self.merge.pending[j]
        other = pending[0][1] if pending else (self.sof_cycles[j][0] if self.sof_cycles[j] else None)
        # A same-cycle tie belongs to input 0.
        if other is not None and (other < arrived or (other == arrived and j == 0)):
            self.overtakes += 1
            self.overtake_wait_max = max(self.overtake_wait_max, self.cycles - other)
            if self.order_check:
                self.report(f"output frame {self.merge.out_frames} of input {i} (SOF accepted at cycle {arrived}) left before "
                            f"a frame of input {j} accepted at cycle {other}")

    def _in_window(self):
        """Both inputs still have frames to deliver: the output could be busy every ready cycle."""
        return all(self.in_frames[i] < self.frames for i in (0, 1))

    async def sampler(self):
        d = self.dut
        edge = RisingEdge(d.CLK)
        props = list(self.props.values())
        while True:
            await edge
            await ReadOnly()
            self.cycles += 1
            if signal_binstr(d.RST) == "0":
                for i in (0, 1):
                    if signal_handshake(getattr(d, f"RX_MFB{i}_SRC_RDY"), getattr(d, f"RX_MFB{i}_DST_RDY")):
                        sof = signal_binstr(getattr(d, f"RX_MFB{i}_SOF"))
                        for _ in range(sof.count("1")):
                            self.sof_cycles[i].append(self.cycles)
                for m in self.in_mons:
                    m.monitor_cycle()
                if self._in_window() and self.in_frames[0] + self.in_frames[1] > 0 and \
                        signal_binstr(d.TX_MFB_DST_RDY) == "1":
                    self.win["rdy_cycles"] += 1
                    self.win["words"] += signal_binstr(d.TX_MFB_SRC_RDY) == "1"
                self.out_mon.monitor_cycle()
            for p in props:
                p.check_cycle()

    # ------------------------------------------------------------------------------------------
    def frame(self, i, rng):
        """Random size in items, from one item up to eight words, small ones most often. META bit 0 names
        the input, so the two inputs never offer equal frames."""
        k = rng.randrange(10)
        top = (self.word_items // self.gen["REGIONS"], 2 * self.word_items, 8 * self.word_items)[0 if k < 4 else
                                                                                                 1 if k < 7 else 2]
        items = rng.randint(1, max(1, top))
        meta = (rng.getrandbits(self.gen["META_WIDTH"]) & ~1) | i
        return MfbTransactionWithMeta(data=rng.randbytes(items * self.item_bytes), meta=meta)

    async def run(self):
        d = self.dut
        self.build()
        self.log.info(f"cocotbext.ofm imported from {cocotbext.ofm.mfb.fast_drivers.__file__}")
        self.log.info(f"generics {self.gen}, {self.frames} frames per input, "
                      f"{'saturated inputs' if self.saturate else 'gapped inputs'}, "
                      f"random TX DST_RDY, frame order check "
                      f"{'on' if self.order_check else 'off'}")
        cocotb.start_soon(Clock(d.CLK, CLK_NS, "ns", impl="gpi").start())
        cocotb.start_soon(self.sampler())
        await ClockCycles(d.CLK, self.rngs["rst"].randint(5, 20))
        d.RST.value = 0
        await RisingEdge(d.CLK)
        cocotb.start_soon(drive_dst_rdy(d.TX_MFB_DST_RDY, d.CLK, self.rngs["rdy"]))
        for i in (0, 1):
            for _ in range(self.frames):
                self.drv[i].append(self.frame(i, self.rngs[f"pkt{i}"]))
        total = 2 * self.frames
        while self.merge.out_frames < total and not self.report.errors:
            await ClockCycles(d.CLK, 100)
            if self.cycles - self.last_out_cycle > STALL_LIMIT_CYCLES:
                d = self.dut
                state = ", ".join(f"{n} {signal_binstr(getattr(d, n))}" for n in
                                  ("RX_MFB0_SRC_RDY", "RX_MFB0_DST_RDY", "RX_MFB1_SRC_RDY", "RX_MFB1_DST_RDY",
                                   "TX_MFB_SRC_RDY", "TX_MFB_DST_RDY"))
                if self.gen["ARRIVAL_ORDER_EN"]:
                    state += (f", owner {int(d.ao_owner.value)}, registers valid {signal_binstr(d.ao_vld)}, frames open "
                              f"{signal_binstr(d.ao_open)}")
                self.report(f"no output frame for {self.cycles - self.last_out_cycle} cycles, {self.merge.out_frames}/"
                            f"{total} out, inputs accepted {self.in_frames}; {state}")
                break
        await ClockCycles(d.CLK, 20)
        for msg in self.merge.leftovers():
            self.report(msg)
        if self.in_frames != [self.frames, self.frames]:
            self.report(f"inputs accepted {self.in_frames} frames, {self.frames} each were sent")
        try:
            final_check_all(self.props)
        except Exception as exc:
            self.report(str(exc))
        w = self.win
        util = w["words"] / w["rdy_cycles"] if w["rdy_cycles"] else None
        item_util = w["items"] / (w["rdy_cycles"] * self.word_items) if w["rdy_cycles"] else None
        self.log.info(f"summary: sim_time={self.cycles * CLK_NS} ns cycles={self.cycles} | out {self.merge.out_frames} "
                      f"frames ({self.out_from[0]} from input 0, {self.out_from[1]} from input 1) | both inputs "
                      f"busy: {w['rdy_cycles']} DST_RDY cycles, output word utilisation "
                      f"{'n/a' if util is None else f'{util:.3f}'}, item utilisation "
                      f"{'n/a' if item_util is None else f'{item_util:.3f}'} | out of SOF arrival order "
                      f"{self.overtakes} frames, longest wait of an overtaken frame {self.overtake_wait_max} cycles")
        errors = self.report.errors
        assert not errors, f"{len(errors)} error(s), first: {errors[0]}"


@cocotb.test()
async def run_random_test(dut):
    """Gapped inputs in random burst, sparse and mixed runs; random TX DST_RDY."""
    await MergerBench(dut, saturate=False).run()


@cocotb.test()
async def run_saturation_test(dut):
    """Both inputs always valid; random TX DST_RDY. Logs the output utilisation."""
    await MergerBench(dut, saturate=True).run()
