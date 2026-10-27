# SPDX-License-Identifier: BSD-3-Clause
# Copyright (C) 2024-2026 CESNET z. s. p. o.
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Jakub Cabal <cabal@cesnet.cz>
#            Ondrej Schwarz <ondrejschwarz@cesnet.cz>
#            Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>

from collections import deque
from dataclasses import dataclass

import cocotb
from cocotb.handle import LogicArrayObject, LogicObject
from cocotb.triggers import Event
from cocotb.types import Logic, LogicArray
from cocotb.utils import get_sim_time

from cocotbext.ofm.base.drivers import ModularBusDriver
from cocotbext.ofm.base.transaction import IdleTransaction
from cocotbext.ofm.base.types import LogicArray2D
from cocotbext.ofm.mfb.protocol import MfbProtocol
from cocotbext.ofm.mfb.transaction import MfbTransaction


class MFBDriver(ModularBusDriver):
    """Driver of an MFB bus built on the signals of an :class:`MfbProtocol`.

    A word is staged as plain integers and per-region lists and only the signals whose value differs from the last
    write are written. With nothing queued, the driver parks the bus and sleeps until the next append().
    """

    bus: MfbProtocol

    # MFBDriver stages its words without the State; it is kept for the subclasses that extend it.
    @dataclass
    class State:
        DATA    : LogicArray | bytearray = 0
        SOF_POS : LogicArray2D           = 0
        EOF_POS : LogicArray2D           = 0
        SOF     : LogicArray             = 0
        EOF     : LogicArray             = 0
        SRC_RDY : Logic                  = 0
        META    : LogicArray2D           = 0

    def __init__(self, dut, name, clock, protocol=MfbProtocol, no_inner_idles: bool = False, **kwargs):
        super().__init__(dut, name, clock, protocol=protocol, **kwargs)

        self._no_inner_idles : bool = no_inner_idles

        cocotb.start_soon(self._measure_period())

    @property
    def item_cnt(self):
        return self._item_cnt

    @property
    def frame_cnt(self):
        return self._frame_cnt

    def append(self, transaction: MfbTransaction | IdleTransaction):
        """Queue a frame, or an IdleTransaction for a gap of its length in bytes."""
        self._queue.append(transaction)

        if self._sleeping:
            self._wake.set()

    def _init_state(self):
        self.state: MFBDriver.State = MFBDriver.State()

    def _init_bus(self, protocol, *args, **kwargs):
        super()._init_bus(protocol, *args, **kwargs)

        bus = self.bus
        self._regions        : int = bus.REGIONS
        self._region_items   : int = bus.REGION_SIZE * bus.BLOCK_SIZE
        self._item_width     : int = bus.ITEM_WIDTH
        self._item_bytes     : int = bus.ITEM_WIDTH // 8
        self._block_bytes    : int = bus.BLOCK_SIZE * self._item_bytes
        self._region_bytes   : int = bus.REGION_SIZE * self._block_bytes
        self._word_bytes     : int = self._regions * self._region_bytes
        self._word_items     : int = self._regions * self._region_items

        self._init_signals()

        self._queue    : deque = deque()
        self._wake     : Event = Event()
        self._sleeping : bool  = False
        self._period   : int   = 0
        self._cursor   : int   = 0
        self._frame_cnt: int   = 0
        # the frame that started the run of frames being laid and the items sent since
        self._run              = None
        self._run_items: int   = 0

    def _init_signals(self):
        """Writers of the signals present on the bus and the X value of the per-region and whole-word ones."""
        bus = self.bus
        regions = self._regions
        self._write = {}
        self._last = {}
        self._dst_rdy = self._reader("DST_RDY")

        # (name, put_with, per-region width, X of a region, writes flat values) of the per-region signals
        self._region_signals = []
        # (name, put_with, X of the signal) of the optional signals valid with another signal of the whole word
        self._word_signals = []

        for name, descriptor in bus.signals.items():
            if name == "DST_RDY":
                continue

            self._write[name] = descriptor.writer(bus)

            put_with = descriptor.put_with
            if name in ("SOF_POS", "EOF_POS") or put_with in ("SOF", "EOF"):
                width = len(descriptor.target(bus)) // regions
                flat = getattr(MfbProtocol, name, None) is descriptor
                self._region_signals.append((name, put_with, width, "X" * width, flat))
            elif descriptor.is_optional and put_with is not None:
                self._word_signals.append((name, put_with, "X" * len(descriptor.target(bus))))

        self._region_names = tuple(s[0] for s in self._region_signals)
        self._clear_word()

    def _reader(self, name):
        """A function telling whether the 1-bit signal `name` is 1, which reads the bit string of a plain handle."""
        sig = self.bus.signals[name].target(self.bus)

        if isinstance(sig, (LogicObject, LogicArrayObject)):
            handle = sig._handle
            return lambda: handle.get_signal_val_binstr() == "1"

        return lambda: str(sig.value) == "1"

    def _clear_signals(self):
        self._clear_word()

    def _clear_word(self):
        """Empty the staged word; the cursor is kept."""
        regions = self._regions
        self._w_data     : int  = 0
        self._w_sof      : int  = 0
        self._w_eof      : int  = 0
        self._w_items    : int  = 0
        self._w_has_data : bool = False
        self._w_regions  : dict = {name: [None] * regions for name in self._region_names}
        self._w_words    : dict = {}

    def _write_to_bus(self):
        self._write_word(0)

    def _put(self, name, value):
        """Write `value` to the signal `name` unless it holds that value from the last write."""
        if self._last.get(name, self) != value:
            self._last[name] = value
            self._write[name](value)

    def _write_word(self, src_rdy: int):
        """Write the staged word with the given SRC_RDY; signals that keep their value are not written."""
        put = self._put
        put("DATA", self._w_data)
        put("SOF", self._w_sof)
        put("EOF", self._w_eof)

        for name, _, width, x_field, flat in self._region_signals:
            value = _region_value(self._w_regions[name], width, x_field)
            if self._last.get(name, self) != value:
                self._last[name] = value
                if not flat:
                    value = LogicArray2D.from_logicarray(_logic(value, width * self._regions), self._regions)
                self._write[name](value)

        for name, _, x_value in self._word_signals:
            put(name, self._w_words.get(name, x_value))

        put("SRC_RDY", src_rdy)

    async def _send_word(self):
        """Offer the staged word until DST_RDY accepts it, then count it and empty the stage."""
        self._write_word(1)
        await self._clk_re

        dst_rdy = self._dst_rdy
        while not dst_rdy():
            await self._clk_re

        self._item_cnt += self._w_items
        self._run_items += self._w_items
        self._frame_cnt += self._w_eof.bit_count()
        self._clear_word()

    async def _idle_word(self):
        """One clock of SRC_RDY low, whatever DST_RDY is."""
        self._write_word(0)
        await self._clk_re

    async def _close_word(self):
        """End the staged word: send it if it holds data, otherwise spend its clock idle."""
        if self._w_has_data:
            await self._send_word()
        else:
            await self._idle_word()

    async def _measure_period(self):
        await self._clk_re
        t1 = get_sim_time()
        await self._clk_re
        self._period = get_sim_time() - t1

    async def _sleep(self):
        """Park the bus until a transaction is queued; the idle generator learns of the idle words meanwhile."""
        self._write_word(0)
        start = get_sim_time()

        self._wake.clear()
        self._sleeping = True
        await self._wake.wait()
        self._sleeping = False

        await self._clk_re

        if self._period:
            words = round((get_sim_time() - start) / self._period)
            if words > 0:
                self._idle_gen.put(IdleTransaction(), items=words * self._word_items, end=True)

    async def _main_loop(self):
        queue = self._queue

        while True:
            if not queue:
                # a frame that ended inside the word leaves the word open; more may be queued while it is sent
                if self._cursor:
                    if self._w_has_data:
                        await self._send_word()
                    self._cursor = 0
                    self._run_end()
                    continue

                await self._sleep()
                continue

            transaction = queue.popleft()

            if isinstance(transaction, IdleTransaction):
                await self._idle(transaction)
                continue

            assert isinstance(transaction, MfbTransaction), f"Transaction must be an instance of MfbTransaction, not {type(transaction)}."

            for _ in range(self._idle_gen.get(transaction)):
                await self._idle(self._idle_fac.make())

            await self._frame(transaction)

    async def _idle(self, transaction: IdleTransaction):
        """An idle met with no word open lasts one word; inside an open word it skips its length in bytes."""
        if not self._cursor:
            await self._idle_word()
            self._idle_gen.put(transaction, items=self._word_items, end=True)
            return

        if self._no_inner_idles:
            if self._w_has_data:
                await self._send_word()
            self._cursor = 0
            self._run_end()
            return

        await self._skip(len(transaction))

    async def _skip(self, length: int):
        """Leave `length` bytes from the cursor empty, rounded up to a block; each word passed ends as it holds data."""
        word_bytes = self._word_bytes
        block_bytes = self._block_bytes
        pos = self._cursor + length

        while pos >= word_bytes:
            await self._close_word()
            pos -= word_bytes

        pos = -(-pos // block_bytes) * block_bytes
        if pos >= word_bytes:
            await self._close_word()
            pos = 0

        self._cursor = pos
        self._run_end()

    def _set_region_values(self, transaction, region: int, put_with: str):
        """Stage the transaction's values of the per-region optional signals valid with `put_with` in `region`."""
        for name, signal_put_with, width, _, _ in self._region_signals:
            if signal_put_with == put_with and name not in ("SOF_POS", "EOF_POS"):
                value = getattr(transaction, name.lower(), None)
                if value is not None:
                    self._w_regions[name][region] = _field_value(value, width, name)

    async def _frame(self, transaction: MfbTransaction):
        """Lay the frame from the cursor, sending each word it fills."""
        data = transaction.data
        length = len(data)

        if not length:
            return

        region_bytes = self._region_bytes
        block_bytes = self._block_bytes
        word_bytes = self._word_bytes
        item_bytes = self._item_bytes
        cur = self._cursor

        if not cur:
            self._run = transaction
            self._run_items = 0

        # a region that already holds a SOF or an EOF takes no new SOF
        if cur:
            region = cur // region_bytes
            if (self._w_sof | self._w_eof) >> region & 1:
                cur = (region + 1) * region_bytes
                if cur >= word_bytes:
                    await self._send_word()
                    cur = 0

        region = cur // region_bytes
        self._w_sof |= 1 << region
        if "SOF_POS" in self._w_regions:
            self._w_regions["SOF_POS"][region] = (cur % region_bytes) // block_bytes
        self._set_region_values(transaction, region, "SOF")

        pos = 0
        while True:
            take = min(length - pos, word_bytes - cur)
            self._w_data |= int.from_bytes(data[pos:pos + take], byteorder="little") << (cur * 8)
            self._w_items += take // item_bytes
            self._w_has_data = True
            for name, _, _ in self._word_signals:
                value = getattr(transaction, name.lower(), None)
                if value is not None:
                    self._w_words[name] = value
            pos += take
            cur += take

            if pos >= length:
                break

            await self._send_word()
            cur = 0

        region = (cur - 1) // region_bytes
        self._w_eof |= 1 << region
        if "EOF_POS" in self._w_regions:
            self._w_regions["EOF_POS"][region] = ((cur - 1) % region_bytes) // item_bytes
        self._set_region_values(transaction, region, "EOF")

        cur = -(-cur // block_bytes) * block_bytes
        if cur >= word_bytes:
            await self._send_word()
            cur = 0

        self._cursor = cur
        self._run_end()

    def _run_end(self):
        """Report a run of frames to the idle generator once the word it ends in is full; a run starts in an empty word."""
        if not self._cursor and self._run is not None:
            self._idle_gen.put(self._run, items=self._run_items, end=True)
            self._run = None


def _region_value(values: list, width: int, x_field: str):
    """The flat value of per-region fields: an int while every field is an int, else the bit string with X fields."""
    flat = 0

    for region, value in enumerate(values):
        if value.__class__ is not int:
            break
        flat |= value << (region * width)
    else:
        return flat

    return "".join(x_field if v is None else (v if isinstance(v, str) else format(v, f"0{width}b")) for v in reversed(values))


def _field_value(value, width: int, name: str):
    """A transaction's value of a `width`-bit field: an int, or the bit string of a LogicArray."""
    if isinstance(value, LogicArray):
        if len(value) != width:
            raise ValueError(f"{name} of {len(value)} bits does not fit the {width}-bit field of a region")
        return str(value)

    if not 0 <= value < 1 << width:
        raise ValueError(f"{name} {value:#x} does not fit the {width}-bit field of a region")
    return value


def _logic(value, width: int) -> LogicArray:
    """A flat value from _region_value as a LogicArray of `width` bits."""
    return LogicArray.from_unsigned(value, width) if isinstance(value, int) else LogicArray(value)
