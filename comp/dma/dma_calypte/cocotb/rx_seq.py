# rx_seq.py: RX register sequences (rx/uvm/tbench/env/reg_sequence.sv) and the RX packet source
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import os

from cocotb.triggers import RisingEdge, Timer
from cocotb.utils import get_sim_time

from cocotbext.ofm.mfb.transaction import MfbTransactionWithMeta

from traffic import ndk_rand_dist, pick, rx_sequence_sizes

PS_PER_US = 1_000_000


def _env_us(name, default):
    return int(float(os.environ.get(name, default)) * PS_PER_US)


class RxChannelRun:
    """run_channel of one RX channel: start, pointer updates for run_time, stop, wait stop_time,
    forever. Stops at the next safe point once `halt` is set by the end of the test."""

    def __init__(self, ch, regs, rng, log):
        self.ch = ch
        self.regs = regs
        self.rng = rng
        self.log = log
        self.halt = False
        self.parked = False
        self.state = "init"
        self.state_since = 0
        self.starts = self.stops = self.updates = 0
        # run_channel is randomised once (its body never returns).
        upd_dist = ndk_rand_dist(500_000, 10_000_000)
        while True:
            self.update_min, self.update_max = pick(rng, upd_dist), pick(rng, upd_dist)
            if self.update_min < self.update_max:
                break
        run_lo = _env_us("RX_RUN_TIME_MIN_US", 50)
        run_hi = _env_us("RX_RUN_TIME_MAX_US", 500)
        stop_lo = _env_us("RX_STOP_TIME_MIN_US", 5)
        stop_hi = _env_us("RX_STOP_TIME_MAX_US", 50)
        self.run_min, self.run_max = sorted(rng.sample(range(run_lo, run_hi + 1, 1000), 2))
        self.stop_min, self.stop_max = sorted(rng.sample(range(stop_lo, stop_hi + 1, 1000), 2))

    async def _start(self):
        rng, r = self.rng, self.regs

        def addr(align):
            hi = 0 if rng.getrandbits(1) else rng.getrandbits(32)
            return (hi << 32) | (rng.getrandbits(32) & ~(align - 1))

        data_base, hdr_base, update_base = addr(128), addr(8), addr(8)
        data_mask = ~(0xFFFF << rng.randint(4, 15)) & 0xFFFF
        hdr_mask = ~(0xFFFF << rng.randint(4, 15)) & 0xFFFF
        upd_timeout = pick(rng, ndk_rand_dist(5, 1024))
        p2p = rng.getrandbits(1)
        await r.write("update_base", update_base)
        await r.write("data_base", data_base)
        await r.write("hdr_base", hdr_base)
        await r.write("sdp", 0)
        await r.write("shp", 0)
        await r.write("data_mask", data_mask)
        await r.write("hdr_mask", hdr_mask)
        await r.write("upd_timeout", upd_timeout)
        await r.write("exper", p2p)
        await r.write("control", 1)
        await Timer(100, "ns")
        status = await r.read("status")
        while status & 1 == 0:
            await Timer(300, "ns")
            status = await r.read("status")
        self.starts += 1

    async def _pointer_update(self):
        r, rng = self.regs, self.rng
        sdp_mask, shp_mask = r.get("data_mask"), r.get("hdr_mask")
        sdp, shp = r.get("sdp"), r.get("shp")
        hdp = await r.read("hdp")
        hhp = await r.read("hhp")
        sdp_move = rng.randint(0, (hdp - sdp) & sdp_mask)
        shp_move = rng.randint(0, (hhp - shp) & shp_mask)
        await r.write("sdp", (sdp + sdp_move) & sdp_mask)
        await r.write("shp", (shp + shp_move) & shp_mask)
        self.updates += 1

    async def _stop(self):
        r = self.regs
        await r.write("control", 0)
        await Timer(100, "ns")
        status = await r.read("status")
        while status & 1 == 1:
            await Timer(300, "ns")
            await self._pointer_update()
            status = await r.read("status")
        self.stops += 1

    def _enter(self, state):
        self.state = state
        self.state_since = int(get_sim_time("ns"))

    async def run(self):
        rng = self.rng
        while not self.halt:
            self._enter("starting")
            await self._start()
            self._enter("running")
            start = get_sim_time("ps")
            run_time = rng.randint(self.run_min, self.run_max)
            while get_sim_time("ps") < start + run_time and not self.halt:
                await Timer(rng.randint(self.update_min, self.update_max), "ps")
                await self._pointer_update()
            if self.halt:
                break
            self._enter("stopping")
            await self._stop()
            self._enter("stopped")
            idle_end = get_sim_time("ps") + rng.randint(self.stop_min, self.stop_max)
            while get_sim_time("ps") < idle_end and not self.halt:
                await Timer(min(PS_PER_US, idle_end - get_sim_time("ps")), "ps")
        self._enter("parked")
        self.parked = True

    async def stop_if_running(self):
        """Stops a parked channel left running, so that nothing more can enter or move in it."""
        if (await self.regs.read("status")) & 1:
            self._enter("stopping")
            await self._stop()
            self._enter("parked")


class RxPacketSource:
    """virt_seq of the RX test: library batches (80..100 sequences of 10..200 packets, 60..PKT_SIZE_MAX
    B) until RX_SIM_TIME_US, checked before every sequence where UVM finishes the batch; random channel
    and 24-bit header meta per packet (rx_env/driver.sv)."""

    def __init__(self, driver, clock, channels, pkt_size_max, rng, log):
        self.drv = driver
        self.clock = clock
        self.channels = channels
        self.pkt_size_max = pkt_size_max
        self.rng = rng
        self.log = log
        self.sim_time_ps = _env_us("RX_SIM_TIME_US", 450)
        self.batch_min = int(os.environ.get("RX_BATCH_MIN", "80"))
        self.batch_max = int(os.environ.get("RX_BATCH_MAX", "100"))
        self.sent = 0
        self.sent_bytes = 0
        self.done = False

    def used(self):
        # A packet leaves the send queue when the driver starts it, which a full channel buffer can delay for long.
        return bool(self.drv._sendQ) or self.drv.frame_cnt < self.sent

    async def run(self):
        rng = self.rng
        edge = RisingEdge(self.clock)
        batches = 0
        while get_sim_time("ps") < self.sim_time_ps:
            batches += 1
            for _ in range(rng.randint(self.batch_min, self.batch_max)):
                if get_sim_time("ps") >= self.sim_time_ps:
                    break
                for size in rx_sequence_sizes(rng, 60, self.pkt_size_max):
                    ch = rng.randrange(self.channels)
                    meta = (ch << 24) | rng.getrandbits(24)
                    while self.drv._sendQ:
                        await edge
                    self.drv.append(MfbTransactionWithMeta(data=rng.randbytes(size), meta=meta))
                    self.sent += 1
                    self.sent_bytes += size
        while self.used():
            await edge
        self.log.info(f"RX input finished: {batches} batch(es), {self.sent} packets, {self.sent_bytes} B")
        self.done = True
