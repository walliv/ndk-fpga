# cocotb_test.py: Functional verification testbench for C2H_HBM_READER using cocotb
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import math
import random
import logging
from logging.handlers import RotatingFileHandler
from cocotbext.ofm.dma.hyperion import C2HReaderMIRegMap, C2HStatRegBits

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, ReadOnly
from cocotb.logging import SimLogFormatter

from cocotb_bus.drivers import BitDriver
from cocotb_bus.scoreboard import Scoreboard

from cocotbext.ofm.mi.drivers import MIRequestDriver
from cocotbext.ofm.mfb.fast_monitors import MFBMonitor
from cocotbext.ofm.mfb.properties import attach_mfb_properties
from cocotbext.ofm.mfb.transaction import MfbTransactionWithMeta
from cocotbext.ofm.mfb.utils import random_tuple_iterator

from cocotbext.axi import AxiReadBus, AxiSlaveRead, SparseMemoryRegion
from cocotbext.axi.axi_channels import AxiARSink

# AXI3 carries a 4b ARLEN (max 16 beats) where cocotbext-axi defaults to the AXI4 8b. The sink checks the
# width when AxiSlaveRead constructs it, so the patch only has to precede the Testbench.
HBM_LEN_WIDTH = 4
AxiARSink._signal_widths = {**AxiARSink._signal_widths, "arlen": HBM_LEN_WIDTH}

root_logger = logging.getLogger()
file_handler = RotatingFileHandler("rotating.log", maxBytes=(5 * 1024 * 1024), backupCount=2)
file_handler.setFormatter(SimLogFormatter(strip_ansi=True))
root_logger.addHandler(file_handler)

# ============================================================
# DUT constants (must match RTL generics)
# ============================================================
HBM_DATA_WIDTH  = 256
HBM_ADDR_WIDTH  = 34
HBM_ID_WIDTH    = 6
HBM_BYTE_W      = HBM_DATA_WIDTH // 8   # 32
HDR_META_WIDTH  = 12
HBM_SIZE        = 1 << HBM_ADDR_WIDTH
AXI_PAGE        = 4096

# Maximum AXI burst length: 2^HBM_LEN_WIDTH beats
MAX_BURST_BEATS = 2 ** HBM_LEN_WIDTH  # 16
MAX_BURST_BYTES = MAX_BURST_BEATS * HBM_BYTE_W  # 512
# Largest multi-burst request the random tests issue
MAX_LARGE_BYTES = 16 * MAX_BURST_BYTES  # 8 KiB
# Share of random requests placed to end exactly at their channel region's end
REGION_END_RATE = 0.1
# A request that never completes must fail the test rather than hang it
DONE_POLL_LIMIT = 200_000


# ============================================================
# Reference model
# ============================================================
async def build_expected_frame(mem, abase, size):
    """
    Compute the expected MFB frame bytes from the sparse HBM memory model.

    The DUT uses INCR burst type throughout; addresses advance by HBM_BYTE_W
    per beat, sequentially from abase.

    abase : 32B-aligned start address
    size  : number of bytes requested (must be > 0)
    """
    nbeats = math.ceil(size / HBM_BYTE_W)
    chunks = []
    for i in range(nbeats):
        chunks.append(bytes(await mem.read(abase + i * HBM_BYTE_W, HBM_BYTE_W)))
    return b"".join(chunks)[:size]


# ============================================================
# Pause generator for AXI backpressure
# ============================================================
def random_pause():
    """Yield True (pause) ~20 % of the time, False (allow) ~80 %."""
    while True:
        yield random.random() < 0.2


# ============================================================
# Channel addressing
# ============================================================
class ChannelMap:
    """Channel addressing derived from CHANNELS: the channel is the top log2(CHANNELS) bits of the
    HBM address, so each channel owns one contiguous region of 2**(HBM_ADDR_WIDTH-log2(CHANNELS))
    bytes."""

    def __init__(self, channels: int):
        assert channels >= 2 and channels & (channels - 1) == 0, f"CHANNELS={channels} is not a power of two"
        self.channels = channels
        self.chan_w = channels.bit_length() - 1
        assert self.chan_w <= HBM_ID_WIDTH
        self.region_w = HBM_ADDR_WIDTH - self.chan_w
        self.region = 1 << self.region_w
        self.meta_w = HDR_META_WIDTH + self.chan_w

    def chan_of(self, addr: int) -> int:
        return addr >> self.region_w

    def in_range(self, addr: int, size: int) -> bool:
        """Mirror of the DUT's request validation: a non-empty request from a 32B-aligned address
        that ends inside HBM and inside the channel region it starts in."""
        return (addr % HBM_BYTE_W == 0 and size > 0 and addr + size <= HBM_SIZE
                and (addr & (self.region - 1)) + size <= self.region)


# ============================================================
# Testbench
# ============================================================
class Testbench:
    def __init__(self, dut, debug=False):
        self.dut = dut
        self.log = logging.getLogger("cocotb.%s" % type(self).__qualname__)

        # The model takes CHANNELS from the elaborated DUT, so a GENERICS override cannot desync it.
        self.cmap = ChannelMap(int(dut.CHANNELS.value))

        # --- MI driver ---
        self.mi = MIRequestDriver(dut, "MI", dut.CLK)

        # --- HBM memory (sparse, covers full 34-bit address space) ---
        self.mem = SparseMemoryRegion(2 ** HBM_ADDR_WIDTH)

        # --- AXI3 read slave (serves HBM data) ---
        self.hbm_slave = AxiSlaveRead(
            AxiReadBus.from_prefix(dut, "HBM_AXI"),
            dut.CLK,
            dut.RESET,
        )
        self.hbm_slave.target = self.mem
        self.hbm_slave.ar_channel.set_pause_generator(random_pause())
        self.hbm_slave.r_channel.set_pause_generator(random_pause())

        # Drive the non-standard RDATA_PARITY port to 0 (not part of AxiReadBus)
        dut.HBM_AXI_RDATA_PARITY.value = 0

        # --- MFB monitor ---
        # Pass explicit MFB params: the bus carries 32 byte-items (item_width=8)
        # in one region split into 4 blocks of 8 bytes (SOF_POS=2b, EOF_POS=5b).
        # Inference from signal widths alone would mis-derive item_width=2.
        self.mfb_mon = MFBMonitor(
            dut, "USER_RX_MFB", dut.CLK,
            mfb_params={
                "regions": 1,
                "region_size": 4,
                "block_size": 8,
                "item_width": 8,
                "meta_width": self.cmap.meta_w,
            },
            trans_type=MfbTransactionWithMeta,
        )

        # Conformance watchdog on USER_RX_MFB with the monitor's geometry; named explicitly, as nvc also
        # exposes the internal signals of the top level.
        self.mfb_props = attach_mfb_properties(
            dut, dut.CLK, reset=dut.RESET, include=("USER_RX_MFB",),
            mfb_params={"regions": 1, "region_size": 4, "block_size": 8, "item_width": 8},
        )

        # --- USER_RX_MFB_DST_RDY random backpressure ---
        self.backpressure = BitDriver(dut.USER_RX_MFB_DST_RDY, dut.CLK)

        # --- Expected AR stream of the request in flight, checked by ar_monitor() ---
        self.exp_chan = None
        self.exp_lo = 0
        self.exp_hi = 0
        self.ar_count = 0
        self.ar_beats = 0

        # --- Scoreboard ---
        self.expected_output = []
        self.scoreboard = Scoreboard(dut)
        self.scoreboard.add_interface(self.mfb_mon, self.expected_output)

        # --- Model statistics ---
        self.exp_req_cnt   = 0
        self.exp_req_bytes = 0

        if debug:
            self.log.setLevel(logging.DEBUG)
            self.mfb_mon.log.setLevel(logging.DEBUG)
        else:
            self.mfb_mon.log.setLevel(logging.WARNING)
        # Always INFO on scoreboard so Expected/Received values are visible on mismatch
        self.scoreboard.log.setLevel(logging.INFO)

    async def reset(self):
        self.dut.RESET.value = 1
        # Ensure MI inputs are driven to idle during reset
        await ClockCycles(self.dut.CLK, 100)
        self.dut.RESET.value = 0

    async def ar_monitor(self):
        """AXI3 read-burst legality watchdog in the style of the Iuventus read adapter bench, plus
        the channel routing: ARID carries the channel of the burst's address, which must be the
        channel of the request in flight, and every burst stays inside that request's beats."""
        cm = self.cmap
        while True:
            await RisingEdge(self.dut.CLK)
            await ReadOnly()
            if not (bool(self.dut.HBM_AXI_ARVALID.value) and bool(self.dut.HBM_AXI_ARREADY.value)):
                continue
            addr = int(self.dut.HBM_AXI_ARADDR.value)
            length = int(self.dut.HBM_AXI_ARLEN.value)
            size = int(self.dut.HBM_AXI_ARSIZE.value)
            burst = int(self.dut.HBM_AXI_ARBURST.value)
            arid = int(self.dut.HBM_AXI_ARID.value)
            burst_bytes = (length + 1) << size
            assert self.exp_chan is not None, f"AR at 0x{addr:09X} without a request in flight"
            assert size == HBM_BYTE_W.bit_length() - 1, f"ARSIZE={size}, expected {HBM_BYTE_W.bit_length() - 1} (32B beats)"
            assert burst == 1, f"ARBURST={burst}, expected 1 (INCR)"
            assert (addr & ~(AXI_PAGE - 1)) == ((addr + burst_bytes - 1) & ~(AXI_PAGE - 1)), (
                f"AR burst crosses a 4KB boundary: addr=0x{addr:09X} arlen={length} "
                f"arsize={size} (burst_bytes={burst_bytes})")
            assert self.exp_lo <= addr and addr + burst_bytes <= self.exp_hi, (
                f"AR burst [0x{addr:09X}, 0x{addr + burst_bytes:09X}) leaves the request's beats "
                f"[0x{self.exp_lo:09X}, 0x{self.exp_hi:09X})")
            assert cm.chan_of(addr) == self.exp_chan, (
                f"AR at 0x{addr:09X} lies in channel {cm.chan_of(addr)}, the request targets "
                f"channel {self.exp_chan}")
            assert arid & (cm.channels - 1) == self.exp_chan, (
                f"ARID=0x{arid:02X} carries channel {arid & (cm.channels - 1)}, expected "
                f"{self.exp_chan} for AR at 0x{addr:09X} (CHANNELS={cm.channels})")
            self.ar_count += 1
            self.ar_beats += length + 1

    # --------------------------------------------------------
    # MI helpers
    # --------------------------------------------------------
    async def _mi_write32(self, addr, value):
        await self.mi.write(addr, value.to_bytes(4, "little"))

    async def _mi_read32(self, addr):
        return int.from_bytes(await self.mi.read(addr, 4), "little")

    async def _mi_read64(self, addr):
        return int.from_bytes(await self.mi.read(addr, 8), "little")

    # --------------------------------------------------------
    # Single read-request stimulus + model update
    # --------------------------------------------------------
    async def _program(self, addr, size):
        await self._mi_write32(C2HReaderMIRegMap.ADDR_L, addr & 0xFFFFFFFF)
        await self._mi_write32(C2HReaderMIRegMap.ADDR_H, (addr >> 32) & 0x3)
        await self._mi_write32(C2HReaderMIRegMap.SIZE_L, size & 0xFFFFFFFF)
        await self._mi_write32(C2HReaderMIRegMap.SIZE_H, (size >> 32) & 0xFFFFFFFF)
        await self._mi_write32(C2HReaderMIRegMap.CTRL, 0x1)  # START

    async def _wait_status(self, addr, size):
        """Poll STATUS until DONE or RANGE_ERR and return the status word."""
        for poll in range(DONE_POLL_LIMIT):
            status = await self._mi_read32(C2HReaderMIRegMap.STATUS)
            if status & (1 << C2HStatRegBits.ERROR):
                raise RuntimeError(f"C2H_HBM_READER: AXI RRESP error (addr=0x{addr:09X} size={size})")
            if status & ((1 << C2HStatRegBits.DONE) | (1 << C2HStatRegBits.RANGE_ERR)):
                self.log.debug(f"status 0x{status:X} after {poll} polls")
                return status
            await ClockCycles(self.dut.CLK, 1)
        raise TimeoutError(f"C2H_HBM_READER: no DONE/RANGE_ERR for addr=0x{addr:09X} size={size}")

    async def issue_request(self, addr, size):
        """
        Program C2H_HBM_READER to read `size` bytes from HBM address `addr` and wait until DONE.

        The DUT streams `size` bytes starting at `addr`, split into INCR AXI bursts of at most 16
        beats that must not cross a 4 KiB boundary. `addr`/`size` must pass ChannelMap.in_range().
        """
        cm = self.cmap
        assert cm.in_range(addr, size), f"request addr=0x{addr:09X} size={size} is out of range"
        chan = cm.chan_of(addr)

        # Write random data for every beat the DUT will fetch
        nbeats = math.ceil(size / HBM_BYTE_W)
        await self.mem.write(addr, random.randbytes(nbeats * HBM_BYTE_W))

        # Build expected output and update model counters
        exp_data = await build_expected_frame(self.mem, addr, size)
        exp_meta = chan  # HDR_META=0 (high bits), CHAN=chan (low chan_w bits)
        self.expected_output.append(MfbTransactionWithMeta(data=exp_data, meta=exp_meta))
        self.exp_req_cnt   += 1
        self.exp_req_bytes += size

        self.log.debug(f"ISSUE: chan={chan} addr=0x{addr:09X} size={size} nbeats={nbeats}")

        self.exp_chan = chan
        self.exp_lo = addr
        self.exp_hi = addr + nbeats * HBM_BYTE_W
        ar_beats0 = self.ar_beats

        await self._program(addr, size)
        status = await self._wait_status(addr, size)
        assert not status & (1 << C2HStatRegBits.RANGE_ERR), (
            f"RANGE_ERR for the in-range request addr=0x{addr:09X} size={size}")

        # Verify SIZE_L was latched correctly
        size_l_rb = await self._mi_read32(C2HReaderMIRegMap.SIZE_L)
        assert size_l_rb == (size & 0xFFFFFFFF), f"SIZE_L readback mismatch: wrote {size}, read {size_l_rb}"

        # DONE rises with the last R beat, so every AR of the request has been seen by now.
        assert self.ar_beats - ar_beats0 == nbeats, (
            f"ARs requested {self.ar_beats - ar_beats0} beats for addr=0x{addr:09X} size={size}, "
            f"expected {nbeats}")
        self.exp_chan = None

        # Clear DONE
        await self._mi_write32(C2HReaderMIRegMap.CTRL, 0x2)

    async def issue_rejected_request(self, addr, size):
        """Program a request the DUT must reject: RANGE_ERR, no DONE, no AR, no counter change."""
        assert not self.cmap.in_range(addr, size)
        ar_count0 = self.ar_count
        self.exp_chan = None
        await self._program(addr, size)
        status = await self._wait_status(addr, size)
        assert status & (1 << C2HStatRegBits.RANGE_ERR), (
            f"no RANGE_ERR for the out-of-range request addr=0x{addr:09X} size={size} "
            f"(status=0x{status:X}, CHANNELS={self.cmap.channels})")
        assert not status & (1 << C2HStatRegBits.DONE), f"DONE with RANGE_ERR (status=0x{status:X})"
        await ClockCycles(self.dut.CLK, 50)
        assert self.ar_count == ar_count0, f"rejected request addr=0x{addr:09X} size={size} issued an AR"
        await self._mi_write32(C2HReaderMIRegMap.CTRL, 0x2)

    # --------------------------------------------------------
    # Counter verification
    # --------------------------------------------------------
    async def check_counters(self):
        req_cnt   = await self._mi_read64(C2HReaderMIRegMap.REQ_CNT_L)
        req_bytes = await self._mi_read64(C2HReaderMIRegMap.REQ_BYTES_L)

        assert req_cnt == self.exp_req_cnt, \
            f"REQ_CNT mismatch: DUT={req_cnt}, model={self.exp_req_cnt}"
        assert req_bytes == self.exp_req_bytes, \
            f"REQ_BYTES_CNT mismatch: DUT={req_bytes}, model={self.exp_req_bytes}"

        self.log.info(f"Counters OK: req_cnt={req_cnt}, req_bytes={req_bytes}")


# ============================================================
# Test helpers
# ============================================================
def _rand_addr(cmap, size):
    """Random 32B-aligned request address for `size` bytes: any channel, with no regard for 4 KiB
    pages. A share of requests fetches the last beat of the channel region, which for the last
    channel is the end of HBM."""
    region_base = random.randrange(cmap.channels) << cmap.region_w
    beats_bytes = -(-size // HBM_BYTE_W) * HBM_BYTE_W
    if random.random() < REGION_END_RATE:
        return region_base + cmap.region - beats_bytes
    return region_base + random.randrange(0, cmap.region - beats_bytes + 1, HBM_BYTE_W)


def _rand_request(cmap):
    """(addr, size) of one single-burst-sized request: 1..512 B, any byte count."""
    size = random.randint(1, MAX_BURST_BYTES)
    return _rand_addr(cmap, size), size


def _rand_large_request(cmap):
    """(addr, size) of one multi-burst request: 513 B..8 KiB, any byte count."""
    size = random.randint(MAX_BURST_BYTES + 1, MAX_LARGE_BYTES)
    return _rand_addr(cmap, size), size


async def prepare(dut):
    cocotb.start_soon(Clock(dut.CLK, 4, unit="ns").start())
    tb = Testbench(dut=dut, debug=False)
    tb.log.info(f"cocotb.RANDOM_SEED={cocotb.RANDOM_SEED} CHANNELS={tb.cmap.channels} "
                f"(re-run with COCOTB_RANDOM_SEED=<seed> GENERICS=-gCHANNELS=<n> to reproduce)")
    tb.backpressure.start(random_tuple_iterator(1, 8, 1, 4))
    await tb.reset()
    cocotb.start_soon(tb.ar_monitor())
    return tb


async def _wait_all_frames(tb, req_count, dut, timeout_clocks=10_000_000):
    """Wait until the MFB monitor has seen all `req_count` complete frames."""
    last = 0
    waited = 0
    while tb.mfb_mon.frame_cnt < req_count:
        if tb.mfb_mon.frame_cnt // 100 > last:
            last = tb.mfb_mon.frame_cnt // 100
            cocotb.log.info(
                f"Waiting for MFB frames: {tb.mfb_mon.frame_cnt}/{req_count}"
            )
        await ClockCycles(dut.CLK, 100)
        waited += 100
        if waited >= timeout_clocks:
            raise TimeoutError(
                f"Timed out waiting for MFB frames: {tb.mfb_mon.frame_cnt}/{req_count}"
            )
    await ClockCycles(dut.CLK, 100)


# ============================================================
# Tests
# ============================================================
@cocotb.test()
async def run_random_read_test(dut, req_count: int = 1000):
    """
    Single-burst-sized transfers: 1..512 B at random aligned addresses, so bursts land across
    4 KiB pages and at channel region ends. Verifies SOF/EOF/EOF_POS, META, data and MI counters.
    """
    tb = await prepare(dut)

    for n in range(req_count):
        addr, size = _rand_request(tb.cmap)
        await tb.issue_request(addr, size)

    await _wait_all_frames(tb, req_count, dut)
    await tb.check_counters()
    raise tb.scoreboard.result


@cocotb.test()
async def run_large_read_test(dut, req_count: int = 50):
    """
    Multi-burst transfers: 513 B..8 KiB at random aligned addresses. Verifies that the DUT
    chains bursts into a single MFB frame with SOF on the first beat and EOF on the last beat.
    """
    tb = await prepare(dut)

    for n in range(req_count):
        addr, size = _rand_large_request(tb.cmap)
        await tb.issue_request(addr, size)

    await _wait_all_frames(tb, req_count, dut)
    await tb.check_counters()
    raise tb.scoreboard.result


@cocotb.test()
async def run_4k_boundary_test(dut):
    """
    Requests starting in the last 16 beats of a 4 KiB page, each long enough to reach past the
    page, so a burst capped only at 16 beats would cross the boundary.
    """
    tb = await prepare(dut)
    cm = tb.cmap

    req_count = 0
    for beats_before in range(1, MAX_BURST_BEATS):
        for size in (beats_before * HBM_BYTE_W + 1, MAX_BURST_BYTES, MAX_BURST_BYTES + 33, 3 * MAX_BURST_BYTES):
            chan = random.randrange(cm.channels)
            page = random.randrange(1, cm.region // AXI_PAGE - 4)
            addr = (chan << cm.region_w) + page * AXI_PAGE - beats_before * HBM_BYTE_W
            await tb.issue_request(addr, size)
            req_count += 1

    await _wait_all_frames(tb, req_count, dut)
    await tb.check_counters()
    raise tb.scoreboard.result


@cocotb.test()
async def run_range_err_test(dut):
    """
    Requests that start unaligned, cross a channel region, run past the end of HBM or are empty
    set RANGE_ERR and issue no AR; in-range requests right at the region edges still complete.
    """
    tb = await prepare(dut)
    cm = tb.cmap

    req_count = 0
    for chan in sorted({0, random.randrange(1, cm.channels - 1), cm.channels - 1}):
        region_base = chan << cm.region_w
        region_end = region_base + cm.region
        # Ends exactly at the region end (for the last channel, the end of HBM): accepted.
        size = random.randint(1, 3 * MAX_BURST_BEATS) * HBM_BYTE_W
        await tb.issue_request(region_end - size, size)
        req_count += 1
        # One byte too long: crosses into the next region, or past the end of HBM.
        await tb.issue_rejected_request(region_end - size, size + 1)
        # Starts inside the region and ends a whole burst into the next one.
        await tb.issue_rejected_request(region_end - HBM_BYTE_W, MAX_BURST_BYTES)
        # Starts at the region base: accepted, and served from this channel.
        size = random.randint(1, MAX_BURST_BYTES)
        await tb.issue_request(region_base, size)
        req_count += 1
        # Otherwise in range, but not 32B-aligned.
        lbase = random.randrange(0, cm.region - 2 * MAX_BURST_BYTES, HBM_BYTE_W)
        await tb.issue_rejected_request(region_base + lbase + random.randrange(1, HBM_BYTE_W), size)

    # Far past the end of HBM, and an empty request.
    await tb.issue_rejected_request(HBM_SIZE - MAX_BURST_BYTES, 2 * MAX_LARGE_BYTES)
    await tb.issue_rejected_request(random.randrange(0, HBM_SIZE, HBM_BYTE_W), 0)

    await _wait_all_frames(tb, req_count, dut)
    await tb.check_counters()
    raise tb.scoreboard.result
