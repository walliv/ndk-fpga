# rx_driver.py: host side of an RX DMA Calypte queue as the ndp tools drive it
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0
"""One RX DMA Calypte queue as ndptool drives it through libnfb and the ndp kernel driver (ndk-sw): start, consumption
by the DMA header valid flag, and the stop loop. A 64-bit write is two 32-bit MI writes, SDP then SHP."""

from collections import Counter

import cocotb
from cocotb.triggers import Timer

from pcie_tlp import DmaHeader

BLOCK_BYTES = 128
STATUS_READS = 101
# A userspace queue writes its pointers only once this many packets were consumed (ndp_rx.h: uspace_acc).
USPACE_FLUSH = 32


class RxQueue:
    def __init__(self, ch, regs, mode, rng, log):
        assert mode in ("kernel", "userspace")
        self.ch = ch
        self.regs = regs
        self.mode = mode
        self.rng = rng
        self.log = log
        self.consuming = False
        self._task = None
        self.stats = Counter()
        self.reset()

    def reset(self):
        """The software state right after a start (nc_ndp_ctrl_start, dma_ctrl_ndp.h:388-438): pointers, the update
        buffer and the header valid flags are zero."""
        self.upd = (0, 0)
        self.hdrs = {}
        self.sdp = 0
        self.shp = 0
        self.hw_hhp = 0
        self.valid_flag = 1
        self.acc = 0
        # The SDP | SHP the hardware got last from this queue's consumer.
        self.flushed = (0, 0)

    # ------------------------------------------------------------------------------------------
    # Host memory, written by the DMA
    # ------------------------------------------------------------------------------------------
    def host_write(self, kind, index, dws):
        """`kind` "upd": the pointer update (HDP, HHP); "hdr": the DMA header at ring index `index` (DW0 holds the
        frame length in bits 15:0, DW1 the valid flag in bit 0)."""
        if kind == "upd":
            self.upd = (dws[0], dws[1])
        else:
            hdr = DmaHeader.deserialize(dws[0] | (dws[1] << 32))
            self.hdrs[index] = (hdr.frame_len, hdr.vld)

    # ------------------------------------------------------------------------------------------
    # Consumption
    # ------------------------------------------------------------------------------------------
    def _scan(self):
        """ndp_ctrl_rx_get_hwptr: the first header whose valid flag is not the expected one ends the scan."""
        mhp = self.regs.get("hdr_mask")
        for _ in range(mhp + 1):
            hdr = self.hdrs.get(self.hw_hhp)
            if hdr is None or hdr[1] != self.valid_flag:
                break
            self.hw_hhp = (self.hw_hhp + 1) & mhp
            if self.hw_hhp == 0:
                self.valid_flag ^= 1
        return (self.hw_hhp - self.shp) & mhp

    async def _consume(self):
        """Kernel mode (ctrl_ndp.c:527-575) writes SDP | SHP once per burst, userspace mode (ndp_rx.h:233-272) only
        after at least 32 packets."""
        mhp, mdp = self.regs.get("hdr_mask"), self.regs.get("data_mask")
        while self.consuming:
            await Timer(self.rng.choice((20, 100, 400, 2000)), "ns")
            if not self.consuming:
                break
            avail = self._scan()
            if not avail:
                continue
            count = self.rng.randint(1, min(64, avail))
            blocks = sum(-(-self.hdrs[(self.shp + i) & mhp][0] // BLOCK_BYTES) for i in range(count))
            self.shp = (self.shp + count) & mhp
            self.sdp = (self.sdp + blocks) & mdp
            self.stats["consumed"] += count
            if self.mode == "kernel":
                await self.flush()
            else:
                self.acc += count
                if self.acc >= USPACE_FLUSH:
                    self.acc = 0
                    await self.flush()

    async def flush(self):
        self.flushed = (self.sdp, self.shp)
        await self.regs.write_sp(self.sdp, self.shp)

    def start_consumer(self):
        if not self.consuming:
            self.consuming = True
            self._task = cocotb.start_soon(self._consume())

    async def stop_consumer(self):
        """The tool leaves its burst loop; a burst in progress completes."""
        self.consuming = False
        if self._task is not None:
            await self._task
            self._task = None

    # ------------------------------------------------------------------------------------------
    # Stop
    # ------------------------------------------------------------------------------------------
    async def stop_prefix(self):
        """Step 1 of a stop iteration: SDP | SHP from the update buffer, which may move them backwards."""
        self.cached = self.upd
        if self.cached[0] != self.flushed[0] or self.cached[1] != self.flushed[1]:
            self.stats["SDP/SHP rewritten from the update buffer"] += 1
            if self.cached == (0, 0):
                self.stats["SDP/SHP reset to 0 by a stale update buffer"] += 1
        await self.regs.write_sp(*self.cached)

    async def stop(self, bound_ns, now, control_written=False):
        """The loop of ndp_base.h:66-80 -> ctrl_ndp.c:892-925 -> dma_ctrl_ndp.h:453-500. Returns (latency or None past
        `bound_ns`, iterations); with `control_written` the caller did step 1 and CONTROL = STOP itself."""
        t0 = now()
        it = 0
        while True:
            it += 1
            if not (control_written and it == 1):
                await self.stop_prefix()
                await self.regs.write("control", 0)
            await self.regs.write("sdp", self.cached[0])
            await self.regs.write("shp", self.cached[1])
            for _ in range(STATUS_READS):
                if (await self.regs.read("status")) & 1 == 0:
                    self.stats["stops"] += 1
                    self.stats["stop iterations"] += it
                    return now() - t0, it
            if now() - t0 > bound_ns:
                return None, it
