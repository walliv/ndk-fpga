# cocotb_test.py: Verification of TX_DMA_PCIE_TRANS_BUFFER
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

"""
Testbench for TX_DMA_PCIE_TRANS_BUFFER, organized in two parts:

  1. Directed regression tests (test_smoke, test_unaligned_sweep, test_dual_sof,
     test_wraparound) -- each pins down one specific behavior from the write-side protocol
     (alignment, dual-SOF/two-region writes, address wraparound) with a small, easy-to-debug
     set of transactions.

  2. Randomized verification (test_random_soak, test_random_read_patterns) -- drives fully
     randomized, legal traffic on the input PCIE_MFB write bus (random channels, addresses,
     lengths, byte enables, idle/no-op gaps) modeled in lockstep by TransBufferModel, and
     exercises the read side with several different access patterns: single retried reads,
     back-to-back pipelined burst reads, and reads interleaved with an in-flight write stream
     (to hit the write-priority BRAM stall/retry path).

See trans_buffer_model.py for the reference model and NVC_ARRAY_DEMUX_ARTIFACT note below for a
discovered nvc-1.21.0-specific simulation artifact and how the stimulus generator avoids it.

Environment knobs:
  TB_TXN_GAP -- "1" (default) keeps the historical behavior of inserting one no-op word after
    every generated write transaction (see NVC_ARRAY_DEMUX_ARTIFACT below). Set to "0" to disable
    those inserted gaps so back-to-back transactions can be driven at true line rate; this is only
    a mitigation for a bug in the *old* per-byte-demux RTL and is not required for the banked
    architecture, but is kept opt-in (default on) so the same testbench still covers both.
"""

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, ReadOnly

from trans_buffer_model import TransBufferModel, MFB_BYTES, REGION_BYTES

RANDOM_SEED = 0xC0FFEE
CLK_PERIOD_NS = 4

# See "Environment knobs" above.
TB_TXN_GAP = os.environ.get("TB_TXN_GAP", "1") != "0"

# Read data is only guaranteed valid ~6 cycles after the write word that produced it has been
# accepted (1 input register + 2 BRAM input registers + the BRAM write itself). Use a generous
# margin.
WRITE_SETTLE_MARGIN = 20

# The model/DUT instance persists for the whole simulation run (multiple @cocotb.test()
# functions execute against the *same* elaborated design and the same BRAM content -- RESET only
# clears pipeline registers, not BRAM contents). Keep a single model object per run so its view of
# the buffer content stays in sync with the DUT across tests.
_model = None


def log2ceil(x: int) -> int:
    return max(1, (x - 1).bit_length()) if x > 1 else 0


def get_model(dut) -> TransBufferModel:
    global _model
    if _model is None:
        channels = int(dut.CHANNELS.value)
        pointer_width = int(dut.POINTER_WIDTH.value)
        _model = TransBufferModel(channels, pointer_width)
        cocotb.log.info(f"Created TransBufferModel(channels={channels}, pointer_width={pointer_width})")
    return _model


def encode_meta(addr_dw: int, chan: int, be: int, chan_width: int) -> int:
    val = 0  # IS_DMA_HDR = 0
    val |= (addr_dw & ((1 << 62) - 1)) << 1
    val |= (chan & ((1 << chan_width) - 1)) << (1 + 62)
    val |= (be & 0xFFFFFFFF) << (1 + 62 + chan_width)
    return val


# =================================================================================================
# Stimulus generation -- builds lists of "word" dicts, each representing one accepted
# (SRC_RDY='1') PCIE_MFB write word. Only the legal patterns described in the task spec are
# produced here.
# =================================================================================================

def _word(sof0, sof1, meta0, meta1, data64: bytes):
    assert len(data64) == MFB_BYTES
    return dict(sof0=sof0, sof1=sof1, meta0=meta0, meta1=meta1, data=data64)


def gen_noop_word():
    """A 'DMA header' word: SRC_RDY=1, no SOF, all BE=0 (upstream masks SOF/BE for these)."""
    return _word(False, False, (0, 0, 0), (0, 0, 0), bytes(random.randrange(256) for _ in range(MFB_BYTES)))


def gen_words(anchor: int, addr_dw: int, chan: int, byte_offset: int, data: bytes, other=None):
    """
    Build the word sequence for one transaction of len(data) bytes, logically starting at buffer
    byte (addr_dw*4 + byte_offset) of `chan` (byte_offset in 0..3, an FBE-style sub-DW skip).

    anchor=0: word0 has SOF0=1 (meta0 = addr_dw/chan), SOF1=0; payload may fill the rest of word0
      (both regions, since SOF1=0 means the whole word belongs to this one transaction) and
      continue across further whole (no-SOF) words.

    anchor=1: word0 has SOF1=1 (meta1 = addr_dw/chan); payload fills up to (32-byte_offset) bytes
      of region 1's own slice (word bytes 32+byte_offset..63) and continues, if longer, across
      further whole (no-SOF) words -- exactly like the anchor=0 continuation, since after the
      SOF1 word the RTL's "last SOF wins" rule latches region-1's address/channel as the ongoing
      write context.
      `other`, if given, is an independent (addr0_dw, chan0, byte_offset0, data0) region-0
      transaction packed into the SAME first word (dual-SOF, pattern c); its payload must fit
      entirely within region 0 (byte_offset0 + len(data0) <= 32).
    """
    assert 0 <= byte_offset <= 3
    words = []
    remaining = len(data)
    pos = 0

    if anchor == 0:
        avail0 = MFB_BYTES - byte_offset
        chunk = min(remaining, avail0)
        wbytes = bytearray(MFB_BYTES)
        be_full = 0
        for i in range(chunk):
            wbytes[byte_offset + i] = data[pos + i]
            be_full |= 1 << (byte_offset + i)
        words.append(_word(True, False,
                            (addr_dw, chan, be_full & 0xFFFFFFFF),
                            (0, 0, (be_full >> 32) & 0xFFFFFFFF),
                            bytes(wbytes)))
        pos += chunk
        remaining -= chunk
        while remaining > 0:
            chunk = min(remaining, MFB_BYTES)
            wbytes = bytearray(MFB_BYTES)
            for i in range(chunk):
                wbytes[i] = data[pos + i]
            be_full = (1 << chunk) - 1
            words.append(_word(False, False,
                                (0, 0, be_full & 0xFFFFFFFF),
                                (0, 0, (be_full >> 32) & 0xFFFFFFFF),
                                bytes(wbytes)))
            pos += chunk
            remaining -= chunk
    else:
        assert anchor == 1
        avail0 = REGION_BYTES - byte_offset
        chunk = min(remaining, avail0)
        wbytes = bytearray(MFB_BYTES)
        be1_local = 0
        for i in range(chunk):
            wbytes[REGION_BYTES + byte_offset + i] = data[pos + i]
            be1_local |= 1 << (byte_offset + i)

        if other is not None:
            addr0_dw, chan0, byte_offset0, data0 = other
            assert byte_offset0 + len(data0) <= REGION_BYTES
            be0_local = 0
            for i in range(len(data0)):
                wbytes[byte_offset0 + i] = data0[i]
                be0_local |= 1 << (byte_offset0 + i)
            meta0 = (addr0_dw, chan0, be0_local)
            sof0 = True
        else:
            meta0 = (0, 0, 0)
            sof0 = False

        words.append(_word(sof0, True, meta0, (addr_dw, chan, be1_local), bytes(wbytes)))
        pos += chunk
        remaining -= chunk
        while remaining > 0:
            chunk = min(remaining, MFB_BYTES)
            wbytes = bytearray(MFB_BYTES)
            for i in range(chunk):
                wbytes[i] = data[pos + i]
            be_full = (1 << chunk) - 1
            words.append(_word(False, False,
                                (0, 0, be_full & 0xFFFFFFFF),
                                (0, 0, (be_full >> 32) & 0xFFFFFFFF),
                                bytes(wbytes)))
            pos += chunk
            remaining -= chunk

    return words


def rand_bytes(n):
    return bytes(random.randrange(256) for _ in range(n))


# =================================================================================================
# NVC_ARRAY_DEMUX_ARTIFACT
#
# Discovered while developing this testbench (nvc 1.21.0, this exact DUT, MEM_ARRAYS>1 configs
# only -- i.e. the default CHANNELS=8/POINTER_WIDTH=16 config, which has MEM_ARRAYS=2):
#
# Two consecutive SOF0-only, fully-byte-enabled (BE=all ones, i.e. an address/DW-aligned first
# word with byte_offset=0 and a payload of >=64 B) write words, whose SOF-carried META_MEM_ARR_IDX
# bit *differs* between them (i.e. their target channels resolve to *different* memory arrays),
# cause the RTL's write_be array-demux (wr_bram_data_demux_p, the "MEM_ARRAYS > 1" generate
# branch in tx_dma_pcie_trans_buffer.vhd) to route the *second* word's data into the *first*
# word's memory array under nvc, silently corrupting a different channel's storage (verified with
# internal-signal probing: mem_arr_idx_next correctly evaluates to the new array index, yet the
# wr_be_bram_demux(<idx>)(0) assignment in the very same process/cycle uses the *old* array index).
# The RTL source was read carefully; per VHDL semantics wr_bram_data_demux_p's "if
# pcie_mfb_sof_inp_reg(i)='1' then wr_be_bram_demux(to_integer(unsigned(pcie_mfb_meta_arr(i)
# (META_MEM_ARR_IDX))))(i) <= ..." branch should read pcie_mfb_meta_arr directly (not any
# register) and is therefore expected to be correct every cycle regardless of write history; the
# failure only appears under nvc and disappears if any word without a "fully enabled" SOF0 (e.g.
# a no-op/DMA-header word, BE=0) is interposed. This looks like an nvc front-end bug in resolving
# a doubly-dynamically-indexed 1-bit slice (`pcie_mfb_meta_arr(i)(META_MEM_ARR_IDX)`, itself a
# single-bit natural-range subtype) used as a `to_integer(unsigned(...))` array index, reusing a
# stale evaluation from an earlier delta. It reproduces identically at -O0 and -O3.
#
# This is NOT worked around by modifying the RTL (out of scope / forbidden by the task). Instead,
# every multi-word helper below inserts one no-op ("DMA header", BE=0) word after each generated
# transaction; empirically this reliably prevents the stale-index reuse. This only matters for the
# MEM_ARRAYS>1 default config; the CHANNELS=32/POINTER_WIDTH=13 config used to prove genericity
# has MEM_ARRAYS=1 (see tx_dma_pcie_trans_buffer.vhd's CHANS_PER_ARRAY/MEM_ARRAYS constants) and
# does not instantiate the affected generate branch at all.
# =================================================================================================


# =================================================================================================
# Driver / reader
# =================================================================================================

class Testbench:
    def __init__(self, dut):
        self.dut = dut
        self.model = get_model(dut)
        self.channels = self.model.channels
        self.chan_width = log2ceil(self.channels)
        self.buf_size = self.model.buf_size

    async def start_clock(self):
        cocotb.start_soon(Clock(self.dut.CLK, CLK_PERIOD_NS, unit='ns').start())
        await ClockCycles(self.dut.CLK, 1)

    async def reset(self):
        dut = self.dut
        dut.RESET.value = 1
        dut.PCIE_MFB_SRC_RDY.value = 0
        dut.PCIE_MFB_SOF.value = 0
        dut.PCIE_MFB_DATA.value = 0
        dut.PCIE_MFB_META[0].value = 0
        dut.PCIE_MFB_META[1].value = 0
        dut.RD_EN_A.value = 0
        dut.RD_CHAN_A.value = 0
        dut.RD_ADDR_A.value = 0
        dut.RD_EN_B.value = 0
        dut.RD_CHAN_B.value = 0
        dut.RD_ADDR_B.value = 0
        await ClockCycles(dut.CLK, 10)
        dut.RESET.value = 0
        await RisingEdge(dut.CLK)
        # RESET clears the RTL's addr_cntr_pst/chan_num_reg pipeline registers; mirror that in
        # the model (the BRAM content itself is untouched by RESET, on either side).
        self.model.addr_cntr = 0
        self.model.chan_reg = 0

    async def drive_word(self, word):
        dut = self.dut
        dut.PCIE_MFB_SRC_RDY.value = 1
        sof_val = (1 if word['sof1'] else 0) << 1 | (1 if word['sof0'] else 0)
        dut.PCIE_MFB_SOF.value = sof_val
        dut.PCIE_MFB_DATA.value = int.from_bytes(word['data'], 'little')
        m0addr, m0chan, m0be = word['meta0']
        m1addr, m1chan, m1be = word['meta1']
        dut.PCIE_MFB_META[0].value = encode_meta(m0addr, m0chan, m0be, self.chan_width)
        dut.PCIE_MFB_META[1].value = encode_meta(m1addr, m1chan, m1be, self.chan_width)
        self.model.process_word(word['sof0'], word['sof1'], m0addr, m0chan, m0be,
                                 m1addr, m1chan, m1be, word['data'])
        await RisingEdge(dut.CLK)

    async def drive_idle(self, cycles=1):
        self.dut.PCIE_MFB_SRC_RDY.value = 0
        for _ in range(cycles):
            await RisingEdge(self.dut.CLK)

    async def drive_words(self, words):
        for w in words:
            await self.drive_word(w)
        self.dut.PCIE_MFB_SRC_RDY.value = 0

    async def write_transaction(self, words):
        """Drive one generated transaction's words, then (when TB_TXN_GAP != "0") one no-op word
        (see NVC_ARRAY_DEMUX_ARTIFACT above) -- use this instead of drive_words() for every
        independent transaction so consecutive transactions never directly abut."""
        await self.drive_words(words)
        if TB_TXN_GAP:
            await self.drive_word(gen_noop_word())
        self.dut.PCIE_MFB_SRC_RDY.value = 0

    async def read_window(self, chan: int, addr: int, timeout=10000) -> bytes:
        """Read 64 bytes starting at byte address `addr` (mod buffer size) of `chan`. Retries
        (re-issuing RD_EN_A) while write-priority stalls RD_DATA_VLD_A."""
        dut = self.dut
        for _ in range(timeout):
            await RisingEdge(dut.CLK)
            dut.RD_EN_A.value = 1
            dut.RD_CHAN_A.value = chan
            dut.RD_ADDR_A.value = addr
            await RisingEdge(dut.CLK)
            dut.RD_EN_A.value = 0
            await ReadOnly()
            vld = bool(dut.RD_DATA_VLD_A.value)
            data = int(dut.RD_DATA_A.value).to_bytes(MFB_BYTES, 'little') if vld else None
            # Leave the ReadOnly phase before returning control to the caller, which may want to
            # drive signals (e.g. the next read/write) right away.
            await RisingEdge(dut.CLK)
            if vld:
                return data
        raise TimeoutError(f"read_window: RD_DATA_VLD_A never asserted for chan={chan} addr={addr}")

    async def read_range(self, chan: int, start: int, length: int) -> bytes:
        """Single-shot (retried) reads, one 64 B window at a time."""
        out = bytearray()
        addr = start
        remaining = length
        while remaining > 0:
            chunk = min(remaining, MFB_BYTES)
            window = await self.read_window(chan, addr)
            out += window[:chunk]
            addr = (addr + MFB_BYTES) % self.buf_size
            remaining -= chunk
        return bytes(out)

    async def read_burst(self, reqs):
        """Pipelined back-to-back reads: issue one RD_EN_A pulse per clock cycle (no waiting for
        RD_DATA_VLD_A in between, exercising the "reads pipelined back-to-back" mode), for a list
        of (chan, addr) requests. Any individual request that loses write-priority arbitration
        (RD_DATA_VLD_A not seen on its capturing edge) is retried afterwards with read_window().
        Returns a list of 64 B windows, one per request, in request order."""
        dut = self.dut
        n = len(reqs)
        results = [None] * n

        async def issuer():
            for chan, addr in reqs:
                await RisingEdge(dut.CLK)
                dut.RD_EN_A.value = 1
                dut.RD_CHAN_A.value = chan
                dut.RD_ADDR_A.value = addr
            await RisingEdge(dut.CLK)
            dut.RD_EN_A.value = 0

        cocotb.start_soon(issuer())

        await RisingEdge(dut.CLK)  # aligns with issuer's first edge (issues reqs[0])
        missed = []
        for idx in range(n):
            await RisingEdge(dut.CLK)
            await ReadOnly()
            if bool(dut.RD_DATA_VLD_A.value):
                results[idx] = int(dut.RD_DATA_A.value).to_bytes(MFB_BYTES, 'little')
            else:
                missed.append(idx)

        for idx in missed:
            results[idx] = await self.read_window(*reqs[idx])
        return results

    async def write_stream_and_read_burst(self, write_words, read_reqs):
        """Drive a write-side word stream (PCIE_MFB_*) and a pipelined read-side burst
        (RD_*_A) concurrently. The two buses are independent signals, so both are driven from a
        *single* issuer coroutine (one write word and one read request per cycle); a second,
        separate coroutine attempting to drive on the same clock edges as this method's own
        ReadOnly-based capture loop was found to race under nvc/cocotb's phase scheduling (two
        independent free-running writer coroutines + a ReadOnly-sampling loop), hence the
        single-issuer design. Returns a list of 64 B read results, one per read_reqs entry
        (already-retried for any write-priority stalls)."""
        dut = self.dut
        nw = len(write_words)
        nr = len(read_reqs)
        results = [None] * nr

        async def issuer():
            for i in range(max(nw, nr)):
                await RisingEdge(dut.CLK)
                if i < nw:
                    w = write_words[i]
                    dut.PCIE_MFB_SRC_RDY.value = 1
                    sof_val = (1 if w['sof1'] else 0) << 1 | (1 if w['sof0'] else 0)
                    dut.PCIE_MFB_SOF.value = sof_val
                    dut.PCIE_MFB_DATA.value = int.from_bytes(w['data'], 'little')
                    m0addr, m0chan, m0be = w['meta0']
                    m1addr, m1chan, m1be = w['meta1']
                    dut.PCIE_MFB_META[0].value = encode_meta(m0addr, m0chan, m0be, self.chan_width)
                    dut.PCIE_MFB_META[1].value = encode_meta(m1addr, m1chan, m1be, self.chan_width)
                    self.model.process_word(w['sof0'], w['sof1'], m0addr, m0chan, m0be,
                                             m1addr, m1chan, m1be, w['data'])
                else:
                    dut.PCIE_MFB_SRC_RDY.value = 0
                if i < nr:
                    chan, addr = read_reqs[i]
                    dut.RD_EN_A.value = 1
                    dut.RD_CHAN_A.value = chan
                    dut.RD_ADDR_A.value = addr
                else:
                    dut.RD_EN_A.value = 0
            await RisingEdge(dut.CLK)
            dut.PCIE_MFB_SRC_RDY.value = 0
            dut.RD_EN_A.value = 0

        cocotb.start_soon(issuer())

        await RisingEdge(dut.CLK)  # aligns with issuer's first edge
        missed = []
        for idx in range(nr):
            await RisingEdge(dut.CLK)
            await ReadOnly()
            if bool(dut.RD_DATA_VLD_A.value):
                results[idx] = int(dut.RD_DATA_A.value).to_bytes(MFB_BYTES, 'little')
            else:
                missed.append(idx)
        # let the write side finish streaming even if reads completed first
        remaining_write_cycles = max(0, nw - nr)
        for _ in range(remaining_write_cycles + 1):
            await RisingEdge(dut.CLK)

        for idx in missed:
            results[idx] = await self.read_window(*read_reqs[idx])
        return results


# =================================================================================================
# Directed regression tests
# =================================================================================================

@cocotb.test()
async def test_smoke(dut):
    random.seed(RANDOM_SEED)
    tb = Testbench(dut)
    await tb.start_clock()
    await tb.reset()

    chan = 0
    addr_dw = 0
    data = rand_bytes(MFB_BYTES)

    words = gen_words(anchor=0, addr_dw=addr_dw, chan=chan, byte_offset=0, data=data)
    await tb.write_transaction(words)
    await tb.drive_idle(WRITE_SETTLE_MARGIN)

    got = await tb.read_range(chan, addr_dw * 4, len(data))
    exp = tb.model.read(chan, addr_dw * 4, len(data))
    assert got == exp, f"test_smoke mismatch: got={got.hex()} exp={exp.hex()}"
    assert got == data


@cocotb.test()
async def test_unaligned_sweep(dut):
    random.seed(RANDOM_SEED + 1)
    tb = Testbench(dut)
    await tb.start_clock()
    await tb.reset()

    lengths_dw = [1, 7, 8, 9, 16, 63, 64]
    next_addr_dw = [0] * tb.channels

    checks = []
    for dw_offset in range(16):
        for length_dw in lengths_dw:
            chan = (dw_offset + length_dw) % tb.channels
            addr_dw = next_addr_dw[chan] - (next_addr_dw[chan] % 16) + dw_offset
            if addr_dw < next_addr_dw[chan]:
                addr_dw += 16
            data = rand_bytes(length_dw * 4)
            words = gen_words(anchor=0, addr_dw=addr_dw, chan=chan, byte_offset=0, data=data)
            await tb.write_transaction(words)
            await tb.drive_idle(2)
            checks.append((chan, addr_dw * 4, data))
            next_addr_dw[chan] = addr_dw + length_dw + 32  # generous gap to avoid overlap

    # a handful of random FBE/LBE (sub-DW byte-granular) patterns
    for _ in range(8):
        chan = random.randrange(tb.channels)
        byte_offset = random.randrange(4)
        total_bytes = random.randrange(1, 253)
        addr_dw = next_addr_dw[chan]
        data = rand_bytes(total_bytes)
        words = gen_words(anchor=0, addr_dw=addr_dw, chan=chan, byte_offset=byte_offset, data=data)
        await tb.write_transaction(words)
        await tb.drive_idle(2)
        checks.append((chan, addr_dw * 4 + byte_offset, data))
        next_addr_dw[chan] = addr_dw + (byte_offset + total_bytes + 3) // 4 + 32

    await tb.drive_idle(WRITE_SETTLE_MARGIN)

    for chan, start_byte, data in checks:
        got = await tb.read_range(chan, start_byte, len(data))
        assert got == data, f"unaligned_sweep mismatch chan={chan} start={start_byte} len={len(data)}"
        exp = tb.model.read(chan, start_byte, len(data))
        assert got == exp


@cocotb.test()
async def test_dual_sof(dut):
    random.seed(RANDOM_SEED + 2)
    tb = Testbench(dut)
    await tb.start_clock()
    await tb.reset()

    checks = []

    cases = []
    # same channel, adjacent addresses
    cases.append(dict(chan0=1, chan1=1, len0=32, len1=16, base0=0, base1=64))
    # different channels, same memory array (default config: chans 0..3 == array 0)
    cases.append(dict(chan0=0, chan1=2, len0=20, len1=12, base0=256, base1=256))
    # different channels, different memory arrays (0..3 vs 4..7 in default config)
    cases.append(dict(chan0=0, chan1=min(4, tb.channels - 1), len0=32, len1=32, base0=512, base1=512))
    # region-1 transaction continuing into subsequent words
    cases.append(dict(chan0=1, chan1=3, len0=8, len1=200, base0=768, base1=768))

    for c in cases:
        chan0, chan1 = c['chan0'] % tb.channels, c['chan1'] % tb.channels
        addr0_dw = c['base0'] // 4
        addr1_dw = c['base1'] // 4
        data0 = rand_bytes(c['len0'])
        data1 = rand_bytes(c['len1'])
        words = gen_words(anchor=1, addr_dw=addr1_dw, chan=chan1, byte_offset=0, data=data1,
                           other=(addr0_dw, chan0, 0, data0))
        await tb.write_transaction(words)
        await tb.drive_idle(2)
        checks.append((chan0, addr0_dw * 4, data0))
        checks.append((chan1, addr1_dw * 4, data1))

    # SOF(1) only, region 0 empty (pattern d)
    chan1 = 5 % tb.channels
    addr1_dw = 1024 // 4
    data1 = rand_bytes(48)
    words = gen_words(anchor=1, addr_dw=addr1_dw, chan=chan1, byte_offset=0, data=data1, other=None)
    await tb.write_transaction(words)
    await tb.drive_idle(2)
    checks.append((chan1, addr1_dw * 4, data1))

    await tb.drive_idle(WRITE_SETTLE_MARGIN)

    for chan, start_byte, data in checks:
        got = await tb.read_range(chan, start_byte, len(data))
        assert got == data, f"dual_sof mismatch chan={chan} start={start_byte} len={len(data)}"


@cocotb.test()
async def test_wraparound(dut):
    random.seed(RANDOM_SEED + 3)
    tb = Testbench(dut)
    await tb.start_clock()
    await tb.reset()

    buf_size = tb.buf_size
    max_dw = buf_size // 4

    chan = 1 % tb.channels
    # start 3 DWs before the end of the buffer; a 64-DW (256B) transaction wraps around
    addr_dw = max_dw - 3
    data = rand_bytes(256)
    words = gen_words(anchor=0, addr_dw=addr_dw, chan=chan, byte_offset=0, data=data)
    await tb.write_transaction(words)
    await tb.drive_idle(WRITE_SETTLE_MARGIN)

    start_byte = (addr_dw * 4) % buf_size
    got = await tb.read_range(chan, start_byte, len(data))
    assert got == data, f"wraparound write/read mismatch: got={got.hex()} exp={data.hex()}"

    # a read window itself crossing the buffer end
    read_start = buf_size - 20
    got2 = await tb.read_window(chan, read_start)
    exp2 = tb.model.read(chan, read_start, MFB_BYTES)
    assert got2 == exp2, f"wraparound read-window mismatch: got={got2.hex()} exp={exp2.hex()}"


# =================================================================================================
# Randomized verification
#
# test_random_soak: pure random legal MFB write stimulus (random channels/addresses/lengths/byte
#   enables/idle gaps), modeled in lockstep, with single-shot retried reads interleaved into the
#   still-running write stream (exercising the write-priority BRAM stall/retry path) plus a final
#   read-back pass.
#
# test_random_read_patterns: a second, independently-seeded random write batch, then the same
#   data is read back through *three* different read-side access patterns (single retried reads,
#   pipelined back-to-back burst reads, and burst reads interleaved with a concurrent write
#   stream) to specifically exercise read-pattern diversity on RD_*_A.
# =================================================================================================

def _gen_random_transaction(tb, chan, length):
    """Pick a random legal pattern (a: region-0 anchored, d: region-1-only, c: dual-SOF) for a
    transaction of `length` bytes on `chan` (and, for pattern c, an independent short region-0
    transaction on a random second channel). Returns (words, [(chan, start_byte, data), ...])."""
    pattern = random.choice(['a', 'a', 'd', 'c'])
    if pattern == 'a':
        byte_offset = random.randrange(4)
        data = rand_bytes(length)
        addr_dw = random.randrange(0, (tb.buf_size // 4) - 256)
        words = gen_words(anchor=0, addr_dw=addr_dw, chan=chan, byte_offset=byte_offset, data=data)
        return words, [(chan, addr_dw * 4 + byte_offset, data)]
    elif pattern == 'd':
        data = rand_bytes(length)
        addr_dw = random.randrange(0, (tb.buf_size // 4) - 256)
        words = gen_words(anchor=1, addr_dw=addr_dw, chan=chan, byte_offset=0, data=data, other=None)
        return words, [(chan, addr_dw * 4, data)]
    else:
        chan0 = random.randrange(tb.channels)
        len0 = random.randrange(1, REGION_BYTES + 1)
        data0 = rand_bytes(len0)
        data1 = rand_bytes(length)
        addr0_dw = random.randrange(0, (tb.buf_size // 4) - 256)
        addr1_dw = random.randrange(0, (tb.buf_size // 4) - 256)
        words = gen_words(anchor=1, addr_dw=addr1_dw, chan=chan, byte_offset=0, data=data1,
                           other=(addr0_dw, chan0, 0, data0))
        return words, [(chan0, addr0_dw * 4, data0), (chan, addr1_dw * 4, data1)]


@cocotb.test()
async def test_random_soak(dut):
    random.seed(RANDOM_SEED + 4)
    tb = Testbench(dut)
    await tb.start_clock()
    await tb.reset()

    buf_size = tb.buf_size
    # leave headroom so per-channel bump allocation never wraps within this test
    per_chan_budget = int(buf_size * 0.6)
    next_addr_dw = [0] * tb.channels

    master_words = []          # flat list of word dicts (+ None for an idle cycle)
    write_commit_index = []    # (word_index_of_last_word, chan, start_byte, data)

    def alloc(chan, nbytes):
        addr_dw = next_addr_dw[chan]
        if addr_dw * 4 + nbytes + 64 > per_chan_budget:
            return None
        next_addr_dw[chan] = addr_dw + (nbytes + 3) // 4 + 8
        return addr_dw

    TARGET_WORDS = 2000
    while len(master_words) < TARGET_WORDS:
        r = random.random()
        if r < 0.08:
            master_words.append(None)  # idle cycle
            continue
        if r < 0.14:
            master_words.append(gen_noop_word())
            continue

        chan = random.randrange(tb.channels)
        pattern = random.choice(['a', 'c', 'd'])
        length = random.randrange(1, 200)

        if pattern == 'a':
            addr_dw = alloc(chan, length)
            if addr_dw is None:
                continue
            byte_offset = random.randrange(4)
            data = rand_bytes(length)
            words = gen_words(anchor=0, addr_dw=addr_dw, chan=chan, byte_offset=byte_offset, data=data)
            start_byte = addr_dw * 4 + byte_offset
        elif pattern == 'd':
            addr_dw = alloc(chan, length)
            if addr_dw is None:
                continue
            data = rand_bytes(length)
            words = gen_words(anchor=1, addr_dw=addr_dw, chan=chan, byte_offset=0, data=data, other=None)
            start_byte = addr_dw * 4
        else:  # 'c' dual sof
            chan0 = chan
            chan1 = random.randrange(tb.channels)
            len0 = random.randrange(1, REGION_BYTES + 1)
            addr0_dw = alloc(chan0, len0)
            addr1_dw = alloc(chan1, length)
            if addr0_dw is None or addr1_dw is None:
                continue
            data0 = rand_bytes(len0)
            data1 = rand_bytes(length)
            words = gen_words(anchor=1, addr_dw=addr1_dw, chan=chan1, byte_offset=0, data=data1,
                               other=(addr0_dw, chan0, 0, data0))
            if TB_TXN_GAP:
                words.append(gen_noop_word())  # NVC_ARRAY_DEMUX_ARTIFACT mitigation
            master_words.extend(words)
            write_commit_index.append((len(master_words) - 1, chan0, addr0_dw * 4, data0))
            write_commit_index.append((len(master_words) - 1, chan1, addr1_dw * 4, data1))
            continue

        if TB_TXN_GAP:
            words.append(gen_noop_word())  # NVC_ARRAY_DEMUX_ARTIFACT mitigation
        master_words.extend(words)
        write_commit_index.append((len(master_words) - 1, chan, start_byte, data))

    cocotb.log.info(f"test_random_soak: driving {len(master_words)} words, "
                     f"{len(write_commit_index)} write transactions")

    driven_count = [0]

    async def writer():
        for w in master_words:
            if w is None:
                await tb.drive_idle(1)
            else:
                await tb.drive_word(w)
            driven_count[0] += 1
        tb.dut.PCIE_MFB_SRC_RDY.value = 0

    writer_task = cocotb.start_soon(writer())

    # Interleave reads of already-settled (committed further back than WRITE_SETTLE_MARGIN)
    # write transactions while the writer is still streaming, to exercise write-priority stalls.
    checked = 0
    attempts = 0
    while not writer_task.done() and attempts < 4000:
        attempts += 1
        eligible = [e for e in write_commit_index if e[0] + WRITE_SETTLE_MARGIN < driven_count[0]]
        if not eligible:
            await RisingEdge(dut.CLK)
            continue
        commit_idx, chan, start_byte, data = random.choice(eligible)
        got = await tb.read_range(chan, start_byte, len(data))
        assert got == data, f"soak interleaved read mismatch chan={chan} start={start_byte} len={len(data)}"
        checked += 1

    await writer_task
    await tb.drive_idle(WRITE_SETTLE_MARGIN)

    cocotb.log.info(f"test_random_soak: {checked} interleaved reads verified during the write stream")

    # Final pass: read back a few hundred random settled windows/transactions.
    sample = random.sample(write_commit_index, min(300, len(write_commit_index)))
    for commit_idx, chan, start_byte, data in sample:
        got = await tb.read_range(chan, start_byte, len(data))
        assert got == data, f"soak final read mismatch chan={chan} start={start_byte} len={len(data)}"

    cocotb.log.info(f"test_random_soak: {len(sample)} final read-back checks passed")


@cocotb.test()
async def test_random_read_patterns(dut):
    """Randomized MFB write stimulus (independent from test_random_soak) verified through three
    distinct read-side access patterns on RD_*_A: single retried reads, pipelined back-to-back
    burst reads, and burst reads issued concurrently with a second in-flight write stream."""
    random.seed(RANDOM_SEED + 5)
    tb = Testbench(dut)
    await tb.start_clock()
    await tb.reset()

    buf_size = tb.buf_size
    per_chan_budget = int(buf_size * 0.5)
    next_addr_dw = [0] * tb.channels

    def alloc(chan, nbytes):
        addr_dw = next_addr_dw[chan]
        if addr_dw * 4 + nbytes + 64 > per_chan_budget:
            return None
        next_addr_dw[chan] = addr_dw + (nbytes + 3) // 4 + 8
        return addr_dw

    entries = []  # (chan, start_byte, data)
    NUM_TXNS = 150
    attempts = 0
    while len(entries) < NUM_TXNS and attempts < NUM_TXNS * 10:
        attempts += 1
        chan = random.randrange(tb.channels)
        length = random.randrange(1, 200)
        pattern = random.choice(['a', 'd'])
        if pattern == 'a':
            byte_offset = random.randrange(4)
            addr_dw = alloc(chan, length)
            if addr_dw is None:
                continue
            data = rand_bytes(length)
            words = gen_words(anchor=0, addr_dw=addr_dw, chan=chan, byte_offset=byte_offset, data=data)
            entries.append((chan, addr_dw * 4 + byte_offset, data))
        else:
            addr_dw = alloc(chan, length)
            if addr_dw is None:
                continue
            data = rand_bytes(length)
            words = gen_words(anchor=1, addr_dw=addr_dw, chan=chan, byte_offset=0, data=data, other=None)
            entries.append((chan, addr_dw * 4, data))
        await tb.write_transaction(words)
        if random.random() < 0.3:
            await tb.drive_idle(random.randrange(1, 4))

    await tb.drive_idle(WRITE_SETTLE_MARGIN)
    cocotb.log.info(f"test_random_read_patterns: wrote {len(entries)} transactions")

    # --- Pattern 1: single retried reads, random order -------------------------------------
    order = list(range(len(entries)))
    random.shuffle(order)
    for i in order:
        chan, start_byte, data = entries[i]
        got = await tb.read_range(chan, start_byte, len(data))
        assert got == data, f"single-read pattern mismatch chan={chan} start={start_byte} len={len(data)}"

    # --- Pattern 2: pipelined back-to-back burst reads (only entries whose data fits in one
    #     64 B window can be checked exactly via a single burst request each) --------------
    single_window = [(chan, start, data) for (chan, start, data) in entries if len(data) <= MFB_BYTES]
    random.shuffle(single_window)
    reqs = [(chan, start) for chan, start, _ in single_window]
    results = await tb.read_burst(reqs)
    for (chan, start, data), window in zip(single_window, results):
        assert window is not None, f"burst-read pattern: no data for chan={chan} start={start}"
        assert window[:len(data)] == data, f"burst-read pattern mismatch chan={chan} start={start} len={len(data)}"
    cocotb.log.info(f"test_random_read_patterns: burst-read pattern verified {len(reqs)} windows")

    # --- Pattern 3: burst reads interleaved with a concurrent (independent) write stream ----
    # A fresh batch of transactions is streamed in the background while we simultaneously issue
    # pipelined burst reads of the *earlier* (already-settled) entries -- exercising write-
    # priority stalls under back-to-back read pressure.
    extra_words = []
    for _ in range(200):
        chan = random.randrange(tb.channels)
        length = random.randrange(1, 64)
        byte_offset = random.randrange(4)
        addr_dw = alloc(chan, length)
        if addr_dw is None:
            continue
        data = rand_bytes(length)
        words = gen_words(anchor=0, addr_dw=addr_dw, chan=chan, byte_offset=byte_offset, data=data)
        if TB_TXN_GAP:
            words.append(gen_noop_word())
        extra_words.extend(words)

    concurrent_reqs = [(chan, start) for chan, start, _ in single_window]
    random.shuffle(concurrent_reqs)
    concurrent_results = await tb.write_stream_and_read_burst(extra_words, concurrent_reqs)
    lookup = {(chan, start): data for chan, start, data in single_window}
    for (chan, start), window in zip(concurrent_reqs, concurrent_results):
        data = lookup[(chan, start)]
        assert window is not None, f"concurrent burst-read: no data for chan={chan} start={start}"
        assert window[:len(data)] == data, \
            f"concurrent burst-read mismatch chan={chan} start={start} len={len(data)}"

    await tb.drive_idle(WRITE_SETTLE_MARGIN)
    cocotb.log.info(f"test_random_read_patterns: concurrent burst-read pattern verified "
                     f"{len(concurrent_reqs)} windows during an in-flight write stream")


@cocotb.test()
async def test_byte_overlap_line_rate(dut):
    """Directed worst case for the banked architecture: a 1 B write to byte address X immediately
    followed -- with NO gap word, i.e. true line rate -- by a 64 B write to byte address X+1, so
    both transactions touch the SAME DWord (X's DW) of the same row, in the same or back-to-back
    cycles (same bank row driven by both memory ports with disjoint byte enables).

    Packings covered (each in its own buffer area so they can be checked independently):
      a) dual-SOF in ONE word: T1 (1 B) in region 0 + T2 (64 B, same DW) anchored at region 1;
      b) back-to-back words, same channel: T1's word immediately followed by T2's SOF word;
      c) like (b) but at a row-straddling base (T2 spans rows base/base+1 within its first word
         and continues into row base+2 territory in the next word -- both banks written back to
         back in consecutive cycles);
      d) like (b) but T1/T2 on different channels (crosses memory arrays when MEM_ARRAYS > 1).
    """
    random.seed(RANDOM_SEED)
    tb = Testbench(dut)
    await tb.start_clock()
    await tb.reset()

    async def check(chan, start, exp_bytes, tag):
        got = await tb.read_range(chan, start, len(exp_bytes))
        expm = tb.model.read(chan, start, len(exp_bytes))
        assert got == expm, (f"{tag}: DUT vs model mismatch at chan={chan} start={hex(start)}: "
                             f"got={got.hex()} exp={expm.hex()}")
        assert got == exp_bytes, (f"{tag}: DUT vs expected mismatch at chan={chan} "
                                  f"start={hex(start)}: got={got.hex()} exp={exp_bytes.hex()}")

    # ---- a) one dual-SOF word: T1 = 1 B @ 0x0 (region 0), T2 = 64 B @ 0x1 (region 1) ----------
    d1, d2 = rand_bytes(1), rand_bytes(64)
    words = gen_words(anchor=1, addr_dw=0, chan=0, byte_offset=1, data=d2,
                      other=(0, 0, 0, d1))
    await tb.drive_words(words)
    await tb.drive_idle(WRITE_SETTLE_MARGIN)
    await check(0, 0x0, d1 + d2, "a-dual-sof-same-dw")

    # ---- b) back-to-back words, same channel: T1 = 1 B @ 0x100, T2 = 64 B @ 0x101 -------------
    d1, d2 = rand_bytes(1), rand_bytes(64)
    words = gen_words(anchor=0, addr_dw=0x100 // 4, chan=0, byte_offset=0, data=d1) \
          + gen_words(anchor=0, addr_dw=0x100 // 4, chan=0, byte_offset=1, data=d2)
    await tb.drive_words(words)   # deliberately NOT write_transaction: no gap word ever
    await tb.drive_idle(WRITE_SETTLE_MARGIN)
    await check(0, 0x100, d1 + d2, "b-back-to-back-same-dw")

    # ---- c) row-straddling base: T1 = 1 B @ 0x23D (DW 0x8F), T2 = 64 B @ 0x23E (same DW; its
    # first word covers rows 8 and 9 of the channel buffer, continuation reaches DW 0x9F) -------
    d1, d2 = rand_bytes(1), rand_bytes(64)
    words = gen_words(anchor=0, addr_dw=0x23D // 4, chan=0, byte_offset=1, data=d1) \
          + gen_words(anchor=0, addr_dw=0x23D // 4, chan=0, byte_offset=2, data=d2)
    await tb.drive_words(words)
    await tb.drive_idle(WRITE_SETTLE_MARGIN)
    await check(0, 0x23D, d1 + d2, "c-row-straddle-same-dw")

    # ---- d) back-to-back words on different channels (cross-array when MEM_ARRAYS > 1) --------
    if tb.channels > 1:
        chan_b = tb.channels - 1
        d1, d2 = rand_bytes(1), rand_bytes(64)
        words = gen_words(anchor=0, addr_dw=0x40 // 4, chan=0, byte_offset=0, data=d1) \
              + gen_words(anchor=0, addr_dw=0x40 // 4, chan=chan_b, byte_offset=1, data=d2)
        await tb.drive_words(words)
        await tb.drive_idle(WRITE_SETTLE_MARGIN)
        await check(0, 0x40, d1, "d-cross-chan-t1")
        await check(chan_b, 0x41, d2, "d-cross-chan-t2")
