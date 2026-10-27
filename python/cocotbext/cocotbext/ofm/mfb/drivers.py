# SPDX-License-Identifier: BSD-3-Clause
# Copyright (C) 2024-2026 CESNET z. s. p. o.
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Jakub Cabal <cabal@cesnet.cz>
#            Ondrej Schwarz <ondrejschwarz@cesnet.cz>
#            Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>

from collections import deque
from dataclasses import asdict, dataclass
from types import SimpleNamespace

import cocotb
from cocotb.handle import LogicArrayObject, LogicObject
from cocotb.triggers import Event
from cocotb.types import Logic, LogicArray
from cocotb.utils import get_sim_time

from cocotbext.ofm.base.drivers import ModularBusDriver
from cocotbext.ofm.base.transaction import IdleTransaction
from cocotbext.ofm.base.types import LogicArray2D
from cocotbext.ofm.mfb.protocol import MfbParams, MfbProtocol
from cocotbext.ofm.mfb.transaction import MfbTransaction
from cocotbext.ofm.mfb.utils import get_mfb_params


class _Aborted(Exception):
    """Unwinds the driving loop after abort() has dropped the word and the frame it was working on."""


class MFBDriver(ModularBusDriver):
    """Driver of an MFB bus built on the signals of an :class:`MfbProtocol`.

    The geometry comes from `mfb_params` (a dict as get_mfb_params takes it, or MfbParams) where given, else from the
    generics of the protocol (see `generics_prefix`), else from the widths of the signals.

    A word is staged as plain integers and per-region lists and only the signals whose value differs from the last
    write are written. With nothing queued, the driver parks the bus and sleeps until the next append().

    An idle generator with frame_gaps set, e.g. OnOffIdleGenerator, counts blocks: its gap before a frame leaves blocks
    empty, inside a frame it is asked before each later word for whole idle words. Others put idle transactions first.

    With hold_on_idle, an idle word keeps the signals of the last word and drops SRC_RDY only, as a FIFO that runs
    empty does; otherwise DATA, SOF and EOF are 0 and the per-region and optional signals X.

    BE, where the bus has it, enables the bytes in the frame's `be`, an int or a LogicArray with a bit per payload byte,
    or every payload byte without it; bytes outside a frame are disabled.
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

    def __init__(self, dut, name, clock, protocol=MfbProtocol, no_inner_idles: bool = False,
                 mfb_params: dict | MfbParams | None = None, hold_on_idle: bool = False, **kwargs):
        self._mfb_params = asdict(mfb_params) if isinstance(mfb_params, MfbParams) else mfb_params
        self._hold_on_idle = hold_on_idle
        super().__init__(dut, name, clock, protocol=protocol, **kwargs)

        self._no_inner_idles : bool = no_inner_idles

        cocotb.start_soon(self._measure_period())

    @property
    def item_cnt(self):
        return self._item_cnt

    @property
    def frame_cnt(self):
        return self._frame_cnt

    @property
    def pending(self) -> int:
        """Frames appended and not yet accepted by the sink."""
        return self._appended - self._frame_cnt

    def append(self, transaction: MfbTransaction | IdleTransaction, callback=None, event: Event | None = None):
        """Queue a frame, an MfbTransaction or plain bytes or LogicArray, or an IdleTransaction for a gap of its length
        in bytes. Once the sink accepts the frame, `event` is set and `callback` is called with the frame."""
        self._queue.append(transaction)

        if not isinstance(transaction, IdleTransaction):
            self._appended += 1
            if callback is not None or event is not None:
                self._waiters.append((self._appended, transaction, callback, event))

        if self._sleeping:
            self._wake.set()

    async def send(self, transaction: MfbTransaction | IdleTransaction):
        """Queue a transaction like append() and return once the sink has accepted the frame."""
        if isinstance(transaction, IdleTransaction):
            self.append(transaction)
            return

        accepted = Event()
        self.append(transaction, event=accepted)
        await accepted.wait()

    def abort(self):
        """Drop the queued frames and the one being sent and park the bus, e.g. for a DUT reset mid-frame. A send()
        awaiting a dropped frame never returns, so its task is to be cancelled."""
        self._queue.clear()
        self._waiters.clear()
        self._appended = self._frame_cnt
        self._cursor = 0
        self._run = None
        self._clear_word()
        self._epoch += 1

        self._last.clear()
        self._idle_bus()

        if self._sleeping:
            self._wake.set()

    def _init_state(self):
        self.state: MFBDriver.State = MFBDriver.State()

    def _init_bus(self, protocol, *args, **kwargs):
        super()._init_bus(protocol, *args, **kwargs)

        bus = self.bus
        if self._mfb_params is not None or None in (bus.REGIONS, bus.REGION_SIZE, bus.BLOCK_SIZE, bus.ITEM_WIDTH):
            signals = SimpleNamespace(**{name.lower(): bus.signals[name].target(bus) for name in
                                         ("DATA", "SOF", "SOF_POS", "EOF_POS", "META") if name in bus.signals})
            bus.REGIONS, bus.REGION_SIZE, bus.BLOCK_SIZE, bus.ITEM_WIDTH, _, _ = get_mfb_params(signals, self._mfb_params)

        self._regions        : int = bus.REGIONS
        self._region_items   : int = bus.REGION_SIZE * bus.BLOCK_SIZE
        self._item_width     : int = bus.ITEM_WIDTH
        self._item_bytes     : int = bus.ITEM_WIDTH // 8
        self._block_bytes    : int = bus.BLOCK_SIZE * self._item_bytes
        self._region_bytes   : int = bus.REGION_SIZE * self._block_bytes
        self._word_bytes     : int = self._regions * self._region_bytes
        self._word_items     : int = self._regions * self._region_items
        self._word_blocks    : int = self._regions * bus.REGION_SIZE

        self._init_signals()

        self._queue    : deque = deque()
        self._wake     : Event = Event()
        self._sleeping : bool  = False
        self._period   : int   = 0
        self._epoch    : int   = 0
        self._cursor   : int   = 0
        self._appended : int   = 0
        # (frame count at which it is accepted, frame, callback, event) of each frame someone waits for
        self._waiters  : deque = deque()
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
            if name in ("DST_RDY", "BE"):
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

        # a BE of another width, e.g. the first and last byte enables of PCIe, is not this one and is left alone
        self._has_be = "BE" in bus.signals and len(bus.signals["BE"].target(bus)) == self._word_bytes
        if self._has_be:
            self._write["BE"] = bus.signals["BE"].writer(bus)
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
        self._w_be       : int  = 0
        self._w_sof      : int  = 0
        self._w_eof      : int  = 0
        self._w_items    : int  = 0
        self._w_has_data : bool = False
        self._w_regions  : dict = {name: [None] * regions for name in self._region_names}
        self._w_words    : dict = {}

    def _write_to_bus(self):
        self._idle_bus()

    def _idle_bus(self):
        """Write the bus of an idle word: the staged word, which is empty, or only SRC_RDY low with hold_on_idle."""
        if self._hold_on_idle and self._last:
            self._put("SRC_RDY", 0)
        else:
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

        if self._has_be:
            put("BE", self._w_be)

        put("SRC_RDY", src_rdy)

    async def _send_word(self):
        """Offer the staged word until DST_RDY accepts it, then count it and empty the stage."""
        self._write_word(1)
        await self._edge()

        dst_rdy = self._dst_rdy
        while not dst_rdy():
            await self._edge()

        self._item_cnt += self._w_items
        self._run_items += self._w_items
        eofs = self._w_eof.bit_count()
        self._clear_word()

        if eofs:
            self._frame_cnt += eofs
            self._release()

    def _release(self):
        """Wake the senders of the accepted frames; raises _Aborted if one of their callbacks called abort()."""
        waiters = self._waiters

        while waiters and waiters[0][0] <= self._frame_cnt:
            _, transaction, callback, event = waiters.popleft()
            if event is not None:
                event.set()
            if callback is not None:
                callback(transaction)

        if self._epoch != self._loop_epoch:
            raise _Aborted()

    async def _idle_word(self):
        """One clock of SRC_RDY low, whatever DST_RDY is."""
        self._idle_bus()
        await self._edge()

    async def _edge(self):
        """Wait for the next rising edge; raises _Aborted if abort() was called meanwhile."""
        await self._clk_re

        if self._epoch != self._loop_epoch:
            raise _Aborted()

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
        self._idle_bus()
        start = get_sim_time()

        self._wake.clear()
        self._sleeping = True
        await self._wake.wait()
        self._sleeping = False

        if self._epoch != self._loop_epoch:
            raise _Aborted()

        await self._edge()

        if self._period:
            words = round((get_sim_time() - start) / self._period)
            if words > 0:
                self._idle_gen.put(IdleTransaction(), items=words * self._word_items, end=True)

    async def _main_loop(self):
        while True:
            self._loop_epoch = self._epoch

            try:
                await self._drive()
            except _Aborted:
                pass

    async def _drive(self):
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

            assert isinstance(transaction, (MfbTransaction, bytes, bytearray, LogicArray)), \
                f"Transaction must be an MfbTransaction, bytes or a LogicArray, not {type(transaction)}."

            if self._idle_gen.frame_gaps:
                gap = self._idle_gen.get(transaction)
                if gap:
                    await self._skip(gap * self._block_bytes)
            else:
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

    def _set_region_values(self, fields, region: int, put_with: str):
        """Stage the values in `fields`, an MfbTransaction or None, of the per-region optional signals valid with
        `put_with` in `region`."""
        for name, signal_put_with, width, _, _ in self._region_signals:
            if signal_put_with == put_with and name not in ("SOF_POS", "EOF_POS"):
                value = getattr(fields, name.lower(), None)
                if value is not None:
                    self._w_regions[name][region] = _field_value(value, width, name)

    async def _frame(self, transaction: MfbTransaction | bytes | bytearray | LogicArray):
        """Lay the frame from the cursor, sending each word it fills. Plain bytes or a LogicArray are a frame without
        values of optional signals."""
        fields = transaction if isinstance(transaction, MfbTransaction) else None
        data = transaction.data if fields is not None else transaction
        if isinstance(data, LogicArray):
            data = data.to_bytes(byteorder="little")
        length = len(data)

        if not length:
            return

        region_bytes = self._region_bytes
        block_bytes = self._block_bytes
        word_bytes = self._word_bytes
        item_bytes = self._item_bytes
        cur = self._cursor

        gen = self._idle_gen
        frame_gaps = gen.frame_gaps

        if not cur and not frame_gaps:
            self._run = transaction
            self._run_items = 0

        # a region takes a second SOF never and a SOF after an EOF only for a frame that does not end there too
        if cur:
            region = cur // region_bytes
            if self._w_sof >> region & 1 or (self._w_eof >> region & 1 and cur % region_bytes + length <= region_bytes):
                cur = (region + 1) * region_bytes
                if cur >= word_bytes:
                    await self._send_word()
                    cur = 0

        if self._has_be:
            be = getattr(fields, "be", None)
            if be is None:
                be = (1 << length) - 1
            elif isinstance(be, LogicArray):
                be = be.to_unsigned()

        region = cur // region_bytes
        self._w_sof |= 1 << region
        if "SOF_POS" in self._w_regions:
            self._w_regions["SOF_POS"][region] = (cur % region_bytes) // block_bytes
        self._set_region_values(fields, region, "SOF")

        pos = 0
        while True:
            take = min(length - pos, word_bytes - cur)
            self._w_data |= int.from_bytes(data[pos:pos + take], byteorder="little") << (cur * 8)
            self._w_items += take // item_bytes
            self._w_has_data = True
            if self._has_be:
                self._w_be |= (be >> pos & (1 << take) - 1) << cur
            for name, _, _ in self._word_signals:
                value = getattr(fields, name.lower(), None)
                if value is not None:
                    self._w_words[name] = value
            if frame_gaps:
                gen.put(transaction, items=take // item_bytes, blocks=-(-take // block_bytes), first=pos // item_bytes,
                        last=(pos + take) // item_bytes - 1, start=not pos, end=pos + take >= length)
            pos += take
            cur += take

            if pos >= length:
                break

            await self._send_word()
            cur = 0

            if frame_gaps:
                gap = gen.get(transaction, first=pos // item_bytes, last=length // item_bytes - 1)
                for _ in range(-(-gap // self._word_blocks)):
                    await self._idle_word()
                    gen.put(IdleTransaction(), items=self._word_items, end=True)

        region = (cur - 1) // region_bytes
        self._w_eof |= 1 << region
        if "EOF_POS" in self._w_regions:
            self._w_regions["EOF_POS"][region] = ((cur - 1) % region_bytes) // item_bytes
        self._set_region_values(fields, region, "EOF")

        cur = -(-cur // block_bytes) * block_bytes
        if cur >= word_bytes:
            await self._send_word()
            cur = 0

        self._cursor = cur
        self._run_end()

    def _run_end(self):
        """Report a run of frames to the idle generator once the word it ends in is full; a run starts in an empty word."""
        if not self._cursor and self._run is not None:
            if not self._idle_gen.frame_gaps:
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


def _field_value(value, width: int, name: str = "value"):
    """A transaction's value of a `width`-bit field, an int, little-endian bytes or a LogicArray, as an int or as the
    bit string of a LogicArray."""
    if isinstance(value, LogicArray):
        if len(value) != width:
            raise ValueError(f"{name} of {len(value)} bits does not fit the {width}-bit field of a region")
        return str(value)

    if isinstance(value, (bytes, bytearray)):
        value = int.from_bytes(value, byteorder="little")
    elif not isinstance(value, int):
        raise TypeError(f"Unsupported type of {name}: {type(value)}")

    if not 0 <= value < 1 << width:
        raise ValueError(f"{name} {value:#x} does not fit the {width}-bit field of a region")
    return value


def _logic(value, width: int) -> LogicArray:
    """A flat value from _region_value as a LogicArray of `width` bits."""
    return LogicArray.from_unsigned(value, width) if isinstance(value, int) else LogicArray(value)
