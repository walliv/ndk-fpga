# cocotb_test.py: Verification of TX_DMA_PCIE_TRANS_BUFFER
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

"""Directed and randomized write traffic into TX_DMA_PCIE_TRANS_BUFFER, checked against TransBufferModel by
single, pipelined and write-concurrent reads. MEM_PARTITIONING of the elaboration selects the flat or the partitioned
tests."""

import os
import random

import cocotb
from cocotb.triggers import RisingEdge, ReadOnly

from cocotbext.ofm.utils.signals import generic_bool
from trans_buffer_model import TransBufferModel, MFB_REGIONS, MFB_BYTES, REGION_BYTES
from trans_buffer_tb import TransBufferTestbench, WRITE_SETTLE_MARGIN, collision_sweep

# The toplevel is known when cocotb imports the test module, so the test selection can follow the elaboration.
TB_FLAT = not generic_bool(cocotb.top.MEM_PARTITIONING)

# The model/DUT persists for the whole run: @cocotb.test functions share one elaborated design and
# BRAM content (RESET only clears pipeline registers), so keep one model object per run to stay in
# sync with the DUT.
_model = None


# Cycles in which the banked implementation withheld a requested read colliding with the other region's write.
_xrgn_collisions = {"cycles": 0, "counting": False}


def buffer_impl(dut):
    """The implementation the dispatch chose, from the grey-box hierarchy: "banked URAM", "banked BRAM" or "per-byte"."""
    inner = dut.tx_dma_pcie_trans_buffer_i.impl_g.trans_buffer_i
    if not hasattr(inner, "wr_bank_be"):
        return "per-byte"
    return "banked URAM" if int(inner.MAX_MEM_DEPTH.value) > 4096 else "banked BRAM"


async def _count_xrgn_collisions(dut, collision, rd_en):
    while True:
        await RisingEdge(dut.CLK)
        await ReadOnly()
        # Both are indexed (array)(region); a gated read is a requested one with a collision.
        if any(int(c) & int(e) for ca, ea in zip(collision.value, rd_en.value) for c, e in zip(ca, ea)
               if str(c) in "01" and str(e) in "01"):
            _xrgn_collisions["cycles"] += 1


def log_xrgn_collisions(test):
    if _xrgn_collisions["counting"]:
        cocotb.log.info(f"{test}: reads withheld for a cross-region write collision so far: {_xrgn_collisions['cycles']}")


def get_model(dut) -> TransBufferModel:
    global _model
    if _model is None:
        cocotb.log.info(f"TX_DMA_PCIE_TRANS_BUFFER implementation under test: {buffer_impl(dut)}")
        channels = int(dut.CHANNELS.value)
        pointer_width = int(dut.POINTER_WIDTH.value)
        _model = TransBufferModel(channels, pointer_width, partitioned=not TB_FLAT)
        cocotb.log.info(f"Created TransBufferModel(channels={channels}, pointer_width={pointer_width}, "
                        f"partitioned={not TB_FLAT})")
    return _model


# Stimulus generation: builds lists of "word" dicts, each one accepted (SRC_RDY='1') PCIE_MFB
# write word, using only the patterns TX_DMA_CALYPTE can produce.

def _word(sof0, sof1, meta0, meta1, data64: bytes):
    assert len(data64) == MFB_BYTES
    return dict(sof=(sof0, sof1), meta=(meta0, meta1), data=data64)


def gen_noop_word():
    """A 'DMA header' word: SRC_RDY=1, no SOF, all BE=0 (upstream masks SOF/BE for these)."""
    return _word(False, False, (0, 0, 0), (0, 0, 0), bytes(random.randrange(256) for _ in range(MFB_BYTES)))


def gen_words(anchor: int, addr_dw: int, chan: int, byte_offset: int, data: bytes, other=None):
    """Words of one transaction of len(data) bytes at byte addr_dw*4 + byte_offset of `chan`, anchored by SOF0
    (anchor=0) or SOF1 (anchor=1); `other` packs an independent region-0 transaction into the first word."""
    assert 0 <= byte_offset <= 3
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
        words = [_word(True, False,
                       (addr_dw, chan, be_full & 0xFFFFFFFF),
                       (0, 0, (be_full >> 32) & 0xFFFFFFFF),
                       bytes(wbytes))]
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

        words = [_word(sof0, True, meta0, (addr_dw, chan, be1_local), bytes(wbytes))]
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


def gap_after_transaction():
    """A no-op word follows a generated transaction at random, so transactions also abut at line rate."""
    return random.random() < 0.5


def make_alloc(slots: int, budget: int):
    """alloc(slot, nbytes): bump-allocated DW address in `slot` (a channel), None once `budget` bytes are used, so the
    transactions of one test neither overlap nor wrap."""
    next_addr_dw = [0] * slots

    def alloc(slot, nbytes):
        addr_dw = next_addr_dw[slot]
        if addr_dw * 4 + nbytes + 64 > budget:
            return None
        next_addr_dw[slot] = addr_dw + (nbytes + 3) // 4 + 8
        return addr_dw

    return alloc


def gen_transaction(tb, pattern, chan, length, alloc, offset_first=False, flat=False):
    """A random transaction of `length` bytes placed by alloc(): 'a' SOF0-anchored at a random byte offset (drawn first
    if offset_first or flat), 'd' SOF1-only, 'c' dual-SOF behind a short one on `chan`; flat picks a random channel."""
    if pattern == 'a':
        byte_offset = random.randrange(4) if offset_first or flat else None
        addr_dw = alloc(chan, length + byte_offset if flat else length)
        if addr_dw is None:
            return None
        if byte_offset is None:
            byte_offset = random.randrange(4)
        data = rand_bytes(length)
        chan = _noise_chan(tb.channels) if flat else chan
        words = gen_words(anchor=0, addr_dw=addr_dw, chan=chan, byte_offset=byte_offset, data=data)
        return words, [(chan, addr_dw * 4 + byte_offset, data)]
    if pattern == 'd':
        addr_dw = alloc(chan, length)
        if addr_dw is None:
            return None
        data = rand_bytes(length)
        chan = _noise_chan(tb.channels) if flat else chan
        words = gen_words(anchor=1, addr_dw=addr_dw, chan=chan, byte_offset=0, data=data, other=None)
        return words, [(chan, addr_dw * 4, data)]
    assert pattern == 'c'
    chan1 = random.randrange(tb.channels)
    len0 = random.randrange(1, REGION_BYTES + 1)
    addr0_dw = alloc(chan, len0)
    addr1_dw = alloc(chan1, length)
    if addr0_dw is None or addr1_dw is None:
        return None
    data0 = rand_bytes(len0)
    data1 = rand_bytes(length)
    words = gen_words(anchor=1, addr_dw=addr1_dw, chan=chan1, byte_offset=0, data=data1,
                      other=(addr0_dw, chan, 0, data0))
    return words, [(chan, addr0_dw * 4, data0), (chan1, addr1_dw * 4, data1)]


class Testbench(TransBufferTestbench):
    def __init__(self, dut):
        super().__init__(dut, get_model(dut), MFB_REGIONS, REGION_BYTES)

    def start_monitors(self):
        inner = self.dut.tx_dma_pcie_trans_buffer_i.impl_g.trans_buffer_i
        if hasattr(inner, "rd_xrgn_collision"):
            _xrgn_collisions["counting"] = True
            cocotb.start_soon(_count_xrgn_collisions(self.dut, inner.rd_xrgn_collision, inner.rd_en_bram_demux))

    async def drive_words(self, words):
        for w in words:
            await self.drive_word(w)
        self.dut.PCIE_MFB_SRC_RDY.value = 0

    async def write_transaction(self, words):
        """Drive one generated transaction's words, then possibly one no-op word (gap_after_transaction)."""
        await self.drive_words(words)
        if gap_after_transaction():
            await self.drive_word(gen_noop_word())
        self.dut.PCIE_MFB_SRC_RDY.value = 0

    def row_word(self, chan: int, addr_byte: int, data: bytes):
        words = gen_words(anchor=0, addr_dw=addr_byte // 4, chan=chan, byte_offset=0, data=data)
        assert len(words) == 1, "a 64 B, byte_offset=0, anchor=0 write must be exactly one MFB word"
        return words[0]

    async def write_row(self, chan: int, addr_byte: int, data: bytes):
        await self.write_transaction(gen_words(anchor=0, addr_dw=addr_byte // 4, chan=chan, byte_offset=0, data=data))

    async def read_window(self, chan: int, addr: int, timeout=10000) -> bytes:
        """Read 64 bytes starting at byte address `addr` (mod buffer size) of `chan`. Retries
        (re-issuing RD_EN_A) while write-priority stalls RD_DATA_VLD_A."""
        for _ in range(timeout):
            await self.issue_read(chan, addr)
            await self.read_latency_wait()
            await self.read_sample_point()
            vld, data = self.sample_read()
            # Leave the ReadOnly phase before returning control to the caller, which may want to
            # drive signals (e.g. the next read/write) right away.
            await RisingEdge(self.dut.CLK)
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

    async def capture(self, reqs, drain=0):
        """Samples one result per cycle for the (chan, addr) requests an issuer coroutine started this cycle pulses on
        consecutive edges; after `drain` more cycles, a request stalled by a write is retried with read_window()."""
        dut = self.dut
        results = [None] * len(reqs)
        await RisingEdge(dut.CLK)  # aligns with issuer's first edge (issues reqs[0])
        await self.read_latency_wait()
        missed = []
        for idx in range(len(reqs)):
            await RisingEdge(dut.CLK)
            await self.read_sample_point()
            vld, data = self.sample_read()
            if vld:
                results[idx] = data
            else:
                missed.append(idx)
        for _ in range(drain):
            await RisingEdge(dut.CLK)

        for idx in missed:
            results[idx] = await self.read_window(*reqs[idx])
        return results

    async def read_burst(self, reqs):
        """One RD_EN_A pulse per cycle for each (chan, addr) request, a request stalled by a write retried with
        read_window(). Returns the 64 B windows in request order."""
        dut = self.dut

        async def issuer():
            for chan, addr in reqs:
                await RisingEdge(dut.CLK)
                self.set_read(chan, addr)
            await RisingEdge(dut.CLK)
            dut.RD_EN_A.value = 0

        cocotb.start_soon(issuer())
        return await self.capture(reqs)

    async def write_stream_and_read_burst(self, write_words, read_reqs):
        """One write word and one read request per cycle from a single issuer coroutine, since separate writer
        coroutines raced the ReadOnly capture loop. Returns the 64 B results per read_reqs entry, retried on stalls."""
        dut = self.dut
        nw = len(write_words)
        nr = len(read_reqs)

        async def issuer():
            for i in range(max(nw, nr)):
                await RisingEdge(dut.CLK)
                if i < nw:
                    self.put_word(write_words[i])
                else:
                    dut.PCIE_MFB_SRC_RDY.value = 0
                if i < nr:
                    self.set_read(*read_reqs[i])
                else:
                    dut.RD_EN_A.value = 0
            await RisingEdge(dut.CLK)
            dut.PCIE_MFB_SRC_RDY.value = 0
            dut.RD_EN_A.value = 0

        cocotb.start_soon(issuer())
        # let the write side finish streaming even if reads completed first
        return await self.capture(read_reqs, drain=max(0, nw - nr) + 1)


async def soak(tb, name, next_transaction, flat=False):
    """About 2000 words of idle cycles, no-op words and next_transaction()'s (words, checks), None skipping one (ending
    the stream if flat), checked by retried reads, while writing and after; flat reads through a random channel."""
    dut = tb.dut
    master_words = []          # flat list of word dicts (+ None for an idle cycle)
    write_commit_index = []    # (word_index_of_last_word, chan, start_byte, data)

    TARGET_WORDS = 2000
    while len(master_words) < TARGET_WORDS:
        r = random.random()
        if r < 0.08:
            master_words.append(None)  # idle cycle
            continue
        if r < 0.14:
            master_words.append(gen_noop_word())
            continue

        transaction = next_transaction()
        if transaction is None:
            if flat:
                break
            continue
        words, checks = transaction
        master_words.extend(words)
        write_commit_index.extend((len(master_words) - 1, *check) for check in checks)

    cocotb.log.info(f"{name}: driving {len(master_words)} words, {len(write_commit_index)} write transactions")

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
        chan = _noise_chan(tb.channels) if flat else chan
        got = await tb.read_range(chan, start_byte, len(data))
        assert got == data, f"{name}: interleaved read mismatch chan={chan} start={start_byte} len={len(data)}"
        checked += 1

    await writer_task
    await tb.drive_idle(WRITE_SETTLE_MARGIN)

    cocotb.log.info(f"{name}: {checked} interleaved reads verified during the write stream")

    # Final pass: read back a few hundred random settled windows/transactions.
    sample = random.sample(write_commit_index, min(300, len(write_commit_index)))
    for commit_idx, chan, start_byte, data in sample:
        chan = _noise_chan(tb.channels) if flat else chan
        got = await tb.read_range(chan, start_byte, len(data))
        assert got == data, f"{name}: final read mismatch chan={chan} start={start_byte} len={len(data)}"

    cocotb.log.info(f"{name}: {len(sample)} final read-back checks passed")
    log_xrgn_collisions(name)


# =================================================================================================
# Directed regression tests
# =================================================================================================

@cocotb.test(skip=TB_FLAT)
async def test_smoke(dut):
    tb = await Testbench.setup(dut, 0)

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


@cocotb.test(skip=TB_FLAT)
async def test_unaligned_sweep(dut):
    tb = await Testbench.setup(dut, 1)

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


@cocotb.test(skip=TB_FLAT)
async def test_dual_sof(dut):
    tb = await Testbench.setup(dut, 2)

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


@cocotb.test(skip=TB_FLAT)
async def test_wraparound(dut):
    tb = await Testbench.setup(dut, 3)

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


@cocotb.test(skip=TB_FLAT)
async def test_random_soak(dut):
    """Pure random legal MFB write stimulus, modeled in lockstep, with single-shot retried reads
    interleaved into the still-running write stream (exercising the write-priority BRAM
    stall/retry path), plus a final read-back pass."""
    tb = await Testbench.setup(dut, 4)
    # leave headroom so per-channel bump allocation never wraps within this test
    alloc = make_alloc(tb.channels, int(tb.buf_size * 0.6))

    def next_transaction():
        chan = random.randrange(tb.channels)
        pattern = random.choice(['a', 'c', 'd'])
        length = random.randrange(1, 200)
        transaction = gen_transaction(tb, pattern, chan, length, alloc)
        if transaction is not None and gap_after_transaction():
            transaction[0].append(gen_noop_word())
        return transaction

    await soak(tb, "test_random_soak", next_transaction)


@cocotb.test(skip=TB_FLAT)
async def test_random_read_patterns(dut):
    """Random writes checked through single retried reads, pipelined burst reads and burst reads concurrent with a
    second write stream on RD_*_A."""
    tb = await Testbench.setup(dut, 5)
    alloc = make_alloc(tb.channels, int(tb.buf_size * 0.5))

    entries = []  # (chan, start_byte, data)
    NUM_TXNS = 150
    attempts = 0
    while len(entries) < NUM_TXNS and attempts < NUM_TXNS * 10:
        attempts += 1
        chan = random.randrange(tb.channels)
        length = random.randrange(1, 200)
        pattern = random.choice(['a', 'd'])
        transaction = gen_transaction(tb, pattern, chan, length, alloc, offset_first=True)
        if transaction is None:
            continue
        words, checks = transaction
        entries.extend(checks)
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

    # Pattern 3: stream a fresh batch of transactions in the background while issuing pipelined
    # burst reads of earlier, already-settled entries, exercising write-priority stalls under
    # back-to-back read pressure.
    extra_words = []
    for _ in range(200):
        chan = random.randrange(tb.channels)
        length = random.randrange(1, 64)
        transaction = gen_transaction(tb, 'a', chan, length, alloc, offset_first=True)
        if transaction is None:
            continue
        words = transaction[0]
        if gap_after_transaction():
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
    log_xrgn_collisions("test_random_read_patterns")


@cocotb.test(skip=TB_FLAT)
async def test_byte_overlap_line_rate(dut):
    """A 1 B write to byte X followed without a gap by a 64 B write to X+1, both on the same DWord: in one dual-SOF
    word, back to back on one channel, at a row-straddling base, and on different channels."""
    tb = await Testbench.setup(dut, 0)

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


@cocotb.test(skip=TB_FLAT)
async def test_odd_row_straddle(dut):
    """Read windows starting at every byte of an odd row and of the following even row, so each
    window straddles into the next row's opposite bank. Without split read ports, a read may be
    served by either region slot and must straddle on both."""
    tb = await Testbench.setup(dut, 6)

    chan = random.randrange(tb.channels)
    rows = tb.buf_size // MFB_BYTES
    base_row = 2 * random.randrange(1, rows // 2 - 3)
    data = rand_bytes(4 * MFB_BYTES)
    words = gen_words(anchor=0, addr_dw=base_row * MFB_BYTES // 4, chan=chan, byte_offset=0, data=data)
    await tb.write_transaction(words)
    await tb.drive_idle(WRITE_SETTLE_MARGIN)

    for row in (base_row + 1, base_row + 2):
        for off in range(MFB_BYTES):
            start = row * MFB_BYTES + off
            got = await tb.read_window(chan, start)
            exp = tb.model.read(chan, start, MFB_BYTES)
            assert got == exp, (f"odd_row_straddle mismatch chan={chan} row={row} off={off}: "
                                f"got={got.hex()} exp={exp.hex()}")
    cocotb.log.info(f"test_odd_row_straddle: {2 * MFB_BYTES} windows from rows {base_row + 1} and "
                    f"{base_row + 2} of chan {chan} verified")


# MEM_PARTITIONING=FALSE (TB_FLAT): the whole array is one flat space, so a channel's
# pointer addresses any region and the channel index does not select the physical region.

def _noise_chan(channels):
    return random.randrange(channels) if channels > 1 else 0


@cocotb.test(skip=not TB_FLAT)
async def test_flat_smoke(dut):
    """Write 64 B into the physical region that would be 'channel 1' in partitioned terms, reached by
    the flat address alone while driving channel-field = 0 (must be ignored). Read it back."""
    tb = await Testbench.setup(dut, 100)

    per_chan = 1 << tb.model.pointer_width
    addr_byte = per_chan + 4096          # inside the second channel's physical region
    addr_dw = addr_byte // 4
    data = rand_bytes(MFB_BYTES)

    # channel field deliberately 0 (would select the *first* region under partitioning) -- ignored
    words = gen_words(anchor=0, addr_dw=addr_dw, chan=0, byte_offset=0, data=data)
    await tb.write_transaction(words)
    await tb.drive_idle(WRITE_SETTLE_MARGIN)

    got = await tb.read_range(_noise_chan(tb.channels), addr_byte, len(data))
    exp = tb.model.read(0, addr_byte, len(data))
    assert got == data, f"flat_smoke mismatch: got={got.hex()} exp={data.hex()}"
    assert got == exp


@cocotb.test(skip=not TB_FLAT)
async def test_flat_channel_ignored(dut):
    """Write the SAME flat address three times, each with a different channel-field value; the last
    write must win (they all target the identical physical location because the channel is ignored)."""
    tb = await Testbench.setup(dut, 101)

    per_chan = 1 << tb.model.pointer_width
    addr_byte = 3 * (per_chan // 2)      # straddles into the upper region, arbitrary
    addr_dw = addr_byte // 4

    last = None
    for ch in range(tb.channels):
        data = rand_bytes(MFB_BYTES)
        words = gen_words(anchor=0, addr_dw=addr_dw, chan=ch, byte_offset=0, data=data)
        await tb.write_transaction(words)
        await tb.drive_idle(WRITE_SETTLE_MARGIN)
        last = data

    got = await tb.read_range(_noise_chan(tb.channels), addr_byte, MFB_BYTES)
    assert got == last, f"flat_channel_ignored: channel field not ignored (got={got.hex()} exp={last.hex()})"


@cocotb.test(skip=not TB_FLAT)
async def test_flat_cross_boundary(dut):
    """Flat mode: one write frame streams across a 2**POINTER_WIDTH boundary, so the running address, not a latched
    channel, carries it into the next channel slot; checked at several boundaries."""
    tb = await Testbench.setup(dut, 102)

    per_chan = 1 << tb.model.pointer_width
    # every internal 2**POINTER_WIDTH boundary (there are `channels`-1 of them)
    for b in range(1, tb.channels):
        boundary = b * per_chan
        for pre in (96, 32, 4):
            start = boundary - pre
            addr_dw = start // 4
            data = rand_bytes(256)               # 256 B = 4 words: crosses the boundary mid-frame
            words = gen_words(anchor=0, addr_dw=addr_dw, chan=_noise_chan(tb.channels),
                              byte_offset=0, data=data)
            await tb.write_transaction(words)
            await tb.drive_idle(WRITE_SETTLE_MARGIN)

            got = await tb.read_range(_noise_chan(tb.channels), start, len(data))
            exp = tb.model.read(0, start, len(data))
            assert got == data, (f"flat_cross_boundary mismatch at boundary {hex(boundary)} "
                                 f"start={hex(start)}: got={got.hex()} exp={data.hex()}")
            assert got == exp


@cocotb.test(skip=not TB_FLAT)
async def test_flat_random_soak(dut):
    """Flat mode: random writes over the whole address space with a noise channel each, checked by reads during the
    write stream and a final read-back."""
    tb = await Testbench.setup(dut, 103)
    # one bump allocator over the channels * 2**pointer_width flat space
    alloc = make_alloc(1, int(tb.buf_size * 0.8))

    def next_transaction():
        length = random.randrange(1, 200)
        pattern = random.choice(['a', 'a', 'd'])
        return gen_transaction(tb, pattern, 0, length, alloc, flat=True)

    await soak(tb, "test_flat_random_soak", next_transaction, flat=True)


# ==== Collision probe, report-only ====
# TB_COLLISION_PROBE=1 sweeps one read against a write to the same row and logs, per cycle offset, whether the read
# returns the old data, the new data or no RD_DATA_VLD_A.

TB_COLLISION_PROBE = os.environ.get("TB_COLLISION_PROBE", "0") == "1"


@cocotb.test(skip=(TB_FLAT or not TB_COLLISION_PROBE))
async def test_collision_probe_partitioned(dut):
    """Report-only collision probe of a partitioned elaboration, at address 0 of channel 0."""
    tb = await Testbench.setup(dut, 200)

    await collision_sweep(tb, chan=0, addr_byte=0, label="partitioned")


@cocotb.test(skip=((not TB_FLAT) or not TB_COLLISION_PROBE))
async def test_collision_probe_flat(dut):
    """Report-only collision probe of a flat elaboration, at a row-aligned address in channel 0's slice."""
    tb = await Testbench.setup(dut, 201)

    addr_byte = 4096  # inside channel 0's [0, 2**POINTER_WIDTH) physical slice, 64 B row-aligned
    await collision_sweep(tb, chan=_noise_chan(tb.channels), addr_byte=addr_byte, label="flat")
