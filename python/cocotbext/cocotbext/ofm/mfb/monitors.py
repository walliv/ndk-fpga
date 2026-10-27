# SPDX-License-Identifier: BSD-3-Clause
# Copyright (C) 2024-2026 CESNET z. s. p. o.
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Jakub Cabal <cabal@cesnet.cz>
#            Ondrej Schwarz <ondrejschwarz@cesnet.cz>
#            Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>

from cocotb.triggers import ReadOnly, RisingEdge
from cocotbext.ofm.base.monitors import BusMonitor
from cocotbext.ofm.mfb.utils import get_mfb_params, region_frame_event
from cocotbext.ofm.mfb.transaction import MfbTransaction
from cocotbext.ofm.utils.signals import signal_binstr
from copy import copy


class MFBProtocolError(Exception):
    pass


class MFBMonitor(BusMonitor):
    """
    Monitor for the MFB bus.

    Args:
        trans_type: The desired type for the transactions returned by the monitor.
                    Defaults to `bytes` for backward compatibility.
                    Consider using a child class of `MfbTransaction` for more structured data.

        meta_vld_with: Which signal qualifies META, "sof" (start of frame) or "eof" (end of frame); defaults to the
                       `os_vld_with` of `mfb_params`, which qualifies the other optional signals.

        start: Whether the monitor samples the bus in a task of its own. With False, the bench calls
               `monitor_cycle()` once per clock instead, e.g. from one task that samples many monitors.

        read_only: Sample at ReadOnly after each edge and at start; callbacks must not write signals then. Only where
                   a bus signal can change in the edge's timestep before the edge read: a clock deltas behind the bus
                   registers, a write outside the scheduler.

    An optional signal is captured into the transaction field of its name where the transaction has one.
    """

    _signals = ["data", "sof_pos", "eof_pos", "sof", "eof", "src_rdy", "dst_rdy"]
    _optional_signals = ["meta"]

    def __init__(self, entity, name, clock, array_idx=None, mfb_params=None, trans_type: MfbTransaction | bytes = bytes,
                 start: bool = True, meta_vld_with: str | None = None, read_only: bool = False):
        super().__init__(entity, name, clock, array_idx=array_idx)
        if not start:
            self._thread.cancel()
            self._thread = None
        self._read_only = read_only

        self._regions, self._region_size, self._block_size, self._item_width, self._meta_width, self._os_vld_with = get_mfb_params(
            self.bus, mfb_params
        )
        self._region_items = self._region_size * self._block_size
        self._region_data_w = self._region_items * self._item_width
        self._os = [s for s in self._optional_signals if hasattr(self.bus, s)]
        self._os_widths = {s: len(getattr(self.bus, s)) // self._regions for s in self._os}

        self._meta_vld_with = meta_vld_with or self._os_vld_with
        if self._meta_vld_with not in ["sof", "eof"]:
            raise ValueError(f"Invalid value of {self._meta_vld_with} of 'meta_vld_with'. Supported values are: \"sof\", \"eof\".")

        self._trans_type  = trans_type
        self._transaction = MfbTransaction() if self._trans_type is bytes else trans_type()

        # The per-region field widths come from the signals, so they hold for inferred and explicit mfb_params.
        self._sof_pos_w = (self._region_size - 1).bit_length()
        self._eof_pos_w = len(self.bus.eof_pos) // self._regions

        # The bit strings are read from the simulator handles under the BusProxy; with an array_idx a handle holds
        # the whole array, so that case reads the proxied values instead.
        if array_idx is None:
            self._rbus = getattr(self.bus, "_bus", self.bus)
            self._binstr = signal_binstr
        else:
            self._rbus = self.bus
            self._binstr = lambda sig: str(sig.value)

        self._data    = 0
        self._sof_pos = 0
        self._eof_pos = 0
        self._sof     = [0] * self._regions
        self._eof     = [0] * self._regions
        self._os_data = {s: 0 for s in self._os}

        self.frame_cnt = 0
        self.item_cnt  = 0
        self._in_frame = False

    def _is_valid_word(self, signal_src_rdy, signal_dst_rdy):
        if str(signal_src_rdy.value) != "1":
            return False
        return signal_dst_rdy is None or str(signal_dst_rdy.value) == "1"

    def _word_valid(self):
        bus = self._rbus
        if self._binstr(bus.src_rdy) != "1":
            return False
        return bus.dst_rdy is None or self._binstr(bus.dst_rdy) == "1"

    def _int_or_logic(self, sig):
        """A signal's value as an int, or as a LogicArray when it holds a bit but 0 or 1."""
        try:
            return int(self._binstr(sig), 2)
        except ValueError:
            return sig.value

    def _read_control_signals(self):
        # Plain ints slice per region far cheaper than LogicArrays. A field holding any bit but 0 or 1 keeps its
        # LogicArray, which _field and _data_bytes decode on their own, so X on META or the positions spares DATA.
        bus = self._rbus
        self._data = self._int_or_logic(bus.data)
        self._sof_pos = self._int_or_logic(bus.sof_pos)
        self._eof_pos = self._int_or_logic(bus.eof_pos)
        sof = self._int_or_logic(bus.sof)
        eof = self._int_or_logic(bus.eof)
        self._sof = [(sof >> r) & 1 for r in range(self._regions)] if isinstance(sof, int) else [int(sof[r]) for r in range(self._regions)]
        self._eof = [(eof >> r) & 1 for r in range(self._regions)] if isinstance(eof, int) else [int(eof[r]) for r in range(self._regions)]

        for s in self._os:
            self._os_data[s] = self._int_or_logic(getattr(bus, s))

    def _field(self, vec, r, width):
        """Unsigned value of the per-region `width`-bit field `r` of `vec`, an int or a LogicArray."""
        if width <= 0:
            return 0
        if isinstance(vec, int):
            return (vec >> (r * width)) & ((1 << width) - 1)
        return vec[(r + 1) * width - 1:r * width].to_unsigned()

    def _region_ctrl(self, r):
        """SOF, EOF, SOF_POS and EOF_POS of region `r`, a position 0 where its flag is not set."""
        sof = self._sof[r]
        eof = self._eof[r]
        sof_pos = self._field(self._sof_pos, r, self._sof_pos_w) if sof else 0
        eof_pos = self._field(self._eof_pos, r, self._eof_pos_w) if eof else 0
        return sof, eof, sof_pos, eof_pos

    def _data_bytes(self, r, lo, hi):
        """Little-endian bytes of region `r` data bits [lo:hi), counted from the LSB."""
        if hi <= lo:
            return b""
        base = r * self._region_data_w
        if isinstance(self._data, int):
            n = hi - lo
            return ((self._data >> (base + lo)) & ((1 << n) - 1)).to_bytes((n + 7) // 8, byteorder="little")
        return self._data[base + hi - 1:base + lo].to_bytes(byteorder="little")

    def _set_os(self, r, vld_with=None):
        """Read the optional signals of region `r` when they are valid with `vld_with`, or unconditionally when None."""
        for s in self._os:
            qualifier = self._meta_vld_with if s == "meta" else self._os_vld_with
            if vld_with in (None, qualifier) and self._os_widths[s] > 0 and hasattr(self._transaction, s):
                setattr(self._transaction, s, self._field(self._os_data[s], r, self._os_widths[s]))

    def _recv_trans(self):
        self.log.debug("received transaction: %s", self._transaction)

        if self._trans_type is bytes:
            self._recv(self._transaction.data)
        else:
            self._recv(copy(self._transaction))

    def _frame_received(self):
        self._transaction.data = bytes(self._transaction.data)
        self._recv_trans()
        self.frame_cnt += 1
        self.item_cnt += (len(self._transaction.data) * 8) // self._item_width

    async def _monitor_recv(self):
        clk_re = RisingEdge(self.clock)
        self._in_frame = False

        if self._read_only:
            # the first sample is the word on the bus when the monitor starts, which the next edge transfers
            read_only = ReadOnly()
            while True:
                await read_only
                self.monitor_cycle()
                await clk_re

        while True:
            await clk_re
            self.monitor_cycle()

    def monitor_cycle(self):
        """One cycle's sampling of the bus, for a monitor constructed with start=False."""
        if self.in_reset:
            return

        if not self._word_valid():
            return

        self._read_control_signals()

        for r in range(self._regions):
            sof, eof, sof_pos, eof_pos = self._region_ctrl(r)

            pkt_start = sof_pos * self._block_size * self._item_width
            pkt_end   = (eof_pos + 1) * self._item_width
            event = region_frame_event(sof, eof, sof_pos * self._block_size, eof_pos)

            if self._in_frame:
                if event in ("whole", "end_start"):
                    # if sof appears before eof
                    if event == "whole" and self._region_size > 1:
                        raise MFBProtocolError(f"MFB error: a start-of-frame received without an end-of-frame! ({sof_pos=}, {eof_pos=})")

                    # end of one packet
                    self._transaction.data += self._data_bytes(r, 0, pkt_end)
                    self._set_os(r, "eof")
                    self._frame_received()

                    # start of another packet, in_frame stays True
                    self._transaction.data = bytearray(self._data_bytes(r, pkt_start, self._region_data_w))
                    self._set_os(r, "sof")

                elif event == "start":
                    # sof when the previous packet hasn't ended
                    raise MFBProtocolError(f"MFB error: a start-of-frame received without an end-of-frame! ({sof_pos=})")

                elif event == "end":
                    # packet ends in this region and new one doesn't start
                    self._transaction.data += self._data_bytes(r, 0, pkt_end)
                    self._set_os(r, "eof")
                    self._frame_received()
                    self._in_frame = False

                else:
                    # packet starts and ends in another region, in_frame stays True
                    self._transaction.data += self._data_bytes(r, 0, self._region_data_w)

            else:
                if event in ("whole", "end_start"):
                    # packet starts and ends in this region, in_frame stays False
                    self._transaction.data = self._data_bytes(r, pkt_start, pkt_end)
                    self._set_os(r)
                    self._frame_received()

                elif event == "start":
                    # packet starts in this regions and ends in another one
                    self._transaction.data = bytearray(self._data_bytes(r, pkt_start, self._region_data_w))
                    self._set_os(r, "sof")
                    self._in_frame = True

                elif event == "end":
                    # eof when not in frame
                    raise MFBProtocolError("MFB error: an end-of-frame received before a start-of-frame!")
