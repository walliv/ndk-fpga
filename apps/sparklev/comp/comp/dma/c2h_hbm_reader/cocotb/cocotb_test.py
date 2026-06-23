# cocotb_test.py: Functional verification testbench for C2H_HBM_READER using cocotb
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import itertools
import math
import random
import logging
from logging.handlers import RotatingFileHandler
from cocotbext.ofm.dma.c2h_hbm_reader import C2HReaderMIRegMap, CtrlRegBits, StatRegBits

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge
from cocotb.logging import SimLogFormatter

import cocotb_bus.monitors
from cocotb_bus.drivers import BitDriver
from cocotb_bus.scoreboard import Scoreboard

from cocotbext.ofm.mi.drivers import MIRequestDriver
from cocotbext.ofm.mfb.monitors import MFBMonitor
from cocotbext.ofm.mfb.transaction import MfbTransactionWithMeta

# Patch AXI3 4-bit ARLEN before importing AxiSlaveRead so the width assert passes.
from cocotbext.axi.axi_channels import AxiARSink
HBM_LEN_WIDTH = 4
AxiARSink._signal_widths = {**AxiARSink._signal_widths, "arlen": HBM_LEN_WIDTH}

import cocotbext.axi
from cocotbext.axi import AxiReadBus, AxiSlaveRead, SparseMemoryRegion

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
CHANNELS        = 64
META_CHAN_W     = int(math.log2(CHANNELS))   # 6
META_TOTAL_W    = HDR_META_WIDTH + META_CHAN_W  # 18

# Maximum AXI burst length: 2^HBM_LEN_WIDTH beats
MAX_BURST_BEATS = 2 ** HBM_LEN_WIDTH  # 16
MAX_BURST_BYTES = MAX_BURST_BEATS * HBM_BYTE_W  # 512


# ============================================================
# Reference model
# ============================================================
async def build_expected_frame(mem, abase, size):
    """
    Compute the expected MFB frame bytes from the sparse HBM memory model.

    The DUT uses INCR burst type throughout; addresses advance by HBM_BYTE_W
    per beat, sequentially from abase.  abase must be 32B-aligned (low 5 bits
    cleared by the DUT).

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
# Testbench
# ============================================================
class Testbench:
    def __init__(self, dut, debug=False):
        self.dut = dut
        self.log = logging.getLogger("cocotb.%s" % type(self).__qualname__)

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
        # Uncomment to add backpressure for stress-testing:
        # self.hbm_slave.ar_channel.set_pause_generator(random_pause())
        # self.hbm_slave.r_channel.set_pause_generator(random_pause())

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
                "meta_width": META_TOTAL_W,
            },
            trans_type=MfbTransactionWithMeta,
        )

        # --- USER_RX_MFB_DST_RDY random backpressure ---
        self.backpressure = BitDriver(dut.USER_RX_MFB_DST_RDY, dut.CLK)

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
    async def issue_request(self, chan, lbase, off, size):
        """
        Program C2H_HBM_READER to read `size` bytes from HBM and wait until DONE.

        The DUT splits the transfer into as many 16-beat (512 B) INCR AXI bursts
        as needed, advancing the address sequentially.

        chan  : channel index [0, CHANNELS)
        lbase : 32B-aligned base offset within the channel region.
                Must be 512B-aligned for multi-burst transfers so that each
                16-beat INCR burst does not cross a 4 KB AXI boundary.
        off   : byte offset [0, 31] added when programming ADDR registers;
                DUT ignores low 5 bits, so effective start = abase.
        size  : transfer size in bytes (> 0, must be a multiple of HBM_BYTE_W
                for clean beat boundaries; up to the channel region size)
        """
        abase = (chan << (HBM_ADDR_WIDTH - HBM_ID_WIDTH)) | lbase
        addr  = abase + off  # programmed value (low 5 bits ignored by DUT)

        # Write random data for every beat the DUT will fetch
        nbeats = math.ceil(size / HBM_BYTE_W)
        await self.mem.write(abase, random.randbytes(nbeats * HBM_BYTE_W))

        # Build expected output and update model counters
        exp_data = await build_expected_frame(self.mem, abase, size)
        exp_meta = chan  # HDR_META=0 (high bits), CHAN=chan (low META_CHAN_W bits)
        self.expected_output.append(MfbTransactionWithMeta(data=exp_data, meta=exp_meta))
        self.exp_req_cnt   += 1
        self.exp_req_bytes += size

        nbursts = math.ceil(nbeats / MAX_BURST_BEATS)
        self.log.info(
            f"ISSUE: chan={chan} lbase=0x{lbase:x} off={off} size={size} "
            f"nbeats={nbeats} nbursts={nbursts} abase=0x{abase:x}"
        )

        # Program DUT registers
        await self._mi_write32(C2HReaderMIRegMap.ADDR_L, addr & 0xFFFFFFFF)
        await self._mi_write32(C2HReaderMIRegMap.ADDR_H, (addr >> 32) & 0x3)
        await self._mi_write32(C2HReaderMIRegMap.SIZE_L, size & 0xFFFFFFFF)
        await self._mi_write32(C2HReaderMIRegMap.SIZE_H, (size >> 32) & 0xFFFFFFFF)
        await self._mi_write32(C2HReaderMIRegMap.CTRL, 0x1)  # START

        # Verify SIZE_L was latched correctly
        size_l_rb = await self._mi_read32(C2HReaderMIRegMap.SIZE_L)
        if size_l_rb != (size & 0xFFFFFFFF):
            self.log.error(f"SIZE_L readback mismatch: wrote {size}, read {size_l_rb}")

        # Poll STATUS until DONE (bit 1)
        poll = 0
        while True:
            status = await self._mi_read32(C2HReaderMIRegMap.STATUS)
            if status & (1 << StatRegBits.ERROR):
                raise RuntimeError(f"C2H_HBM_READER: AXI RRESP error (addr=0x{addr:09X} size={size})")
            if status & (1 << StatRegBits.DONE):
                self.log.info(f"DONE after {poll} polls")
                break
            poll += 1
            await ClockCycles(self.dut.CLK, 1)

        # Clear DONE
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
def _rand_request():
    """
    Return (chan, lbase, off, size) for one small (single-burst) request.

    Constraints:
      - chan   in [0, CHANNELS)
      - lbase  32B-aligned; (lbase & 0xFFF) + MAX_BURST_BYTES <= 0x1000
               (ensures the single 16-beat INCR burst cannot cross a 4 KB boundary)
      - off    in [0, HBM_BYTE_W) — exercises the low-bit-masking path in the DUT
      - size   1..16 beats = HBM_BYTE_W..MAX_BURST_BYTES in steps of HBM_BYTE_W
    """
    chan     = random.randrange(CHANNELS)
    max_low12 = 0x1000 - MAX_BURST_BYTES  # 0xE00 = 3584
    low12    = random.randrange(0, max_low12 + 1, HBM_BYTE_W)
    lbase    = low12
    off      = random.randrange(0, HBM_BYTE_W)
    nbeats   = random.randrange(1, MAX_BURST_BEATS + 1)  # 1..16
    size     = nbeats * HBM_BYTE_W
    return chan, lbase, off, size


def _rand_large_request():
    """
    Return (chan, lbase, off, size) for a multi-burst request (2..16 full bursts).

    lbase is 512B-aligned so that every 16-beat (512 B) INCR burst starts at a
    512B boundary, which never crosses a 4 KB AXI page boundary (512 divides 4096).

    size is always an exact multiple of MAX_BURST_BYTES so all bursts are full.
    """
    chan        = random.randrange(CHANNELS)
    CHAN_REGION = 1 << (HBM_ADDR_WIDTH - HBM_ID_WIDTH)  # 256 MB per channel
    MAX_SIZE    = 16 * MAX_BURST_BYTES                   # 16 full bursts = 8192 B
    # 512B-aligned lbase with enough room for the largest request
    lbase = random.randrange(0, CHAN_REGION - MAX_SIZE, MAX_BURST_BYTES)
    off   = 0  # no sub-32B offset for multi-burst transfers
    nbursts = random.randrange(2, 17)  # 2..16 full bursts
    size    = nbursts * MAX_BURST_BYTES
    return chan, lbase, off, size


async def prepare(dut):
    cocotb.start_soon(Clock(dut.CLK, 4, unit="ns").start())
    tb = Testbench(dut=dut, debug=False)
    await tb.reset()
    return tb


async def _mfb_word_monitor(dut):
    """Log every valid MFB word and every FIFO write (beat_accept)."""
    clk = RisingEdge(dut.CLK)
    while True:
        await clk
        if dut.USER_RX_MFB_SRC_RDY.value == 1 and dut.USER_RX_MFB_DST_RDY.value == 1:
            sof = int(dut.USER_RX_MFB_SOF.value)
            eof = int(dut.USER_RX_MFB_EOF.value)
            eof_pos = int(dut.USER_RX_MFB_EOF_POS.value)
            data_bytes = dut.USER_RX_MFB_DATA.value.to_bytes(byteorder='little')
            cocotb.log.info(
                f"MFB word: SOF={sof} EOF={eof} EOF_POS={eof_pos} "
                f"DATA[0:4]={data_bytes[:4].hex()}"
            )
        if int(dut.beat_accept.value) == 1:
            rb = int(dut.remaining_bytes.value)
            eof_in = int(dut.fifo_rx_eof.value)
            eof_pos_in = int(dut.fifo_rx_eof_pos.value)
            first_beat = int(dut.first_beat.value)
            cocotb.log.info(
                f"BEAT: remaining_bytes={rb} eof={eof_in} eof_pos_in={eof_pos_in} "
                f"first_beat={first_beat}"
            )


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
    Single-burst transfers: 1..16 beats (32..512 B) per request.
    Verifies SOF/EOF/EOF_POS, data correctness, and MI counters.
    """
    tb = await prepare(dut)

    cocotb.start_soon(_mfb_word_monitor(dut))

    # DST_RDY always high (no backpressure) for deterministic coverage
    tb.dut.USER_RX_MFB_DST_RDY.value = 1
    # Uncomment to restore randomized backpressure:
    # tb.backpressure.start((1, i % 5) for i in itertools.count())

    for n in range(req_count):
        chan, lbase, off, size = _rand_request()
        await tb.issue_request(chan, lbase, off, size)

    await _wait_all_frames(tb, req_count, dut)
    await tb.check_counters()
    raise tb.scoreboard.result


@cocotb.test()
async def run_large_read_test(dut, req_count: int = 50):
    """
    Multi-burst transfers: 2..16 full 16-beat bursts per request (1..8 KB).
    Verifies that the DUT correctly chains bursts into a single MFB frame
    with SOF on the first beat and EOF on the last beat.
    """
    tb = await prepare(dut)

    cocotb.start_soon(_mfb_word_monitor(dut))

    tb.dut.USER_RX_MFB_DST_RDY.value = 1

    for n in range(req_count):
        chan, lbase, off, size = _rand_large_request()
        await tb.issue_request(chan, lbase, off, size)

    await _wait_all_frames(tb, req_count, dut)
    await tb.check_counters()
    raise tb.scoreboard.result
