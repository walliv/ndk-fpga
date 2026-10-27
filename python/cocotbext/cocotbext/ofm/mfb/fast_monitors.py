# fast_monitors.py: MFBMonitor that reads the bus as plain integers
# Copyright (C) 2025 CESNET z. s. p. o.
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Jakub Cabal <cabal@cesnet.cz>
#            Ondrej Schwarz <ondrejschwarz@cesnet.cz>
#            Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: BSD-3-Clause OR Apache-2.0
"""MFBMonitor that samples with the simulator's bit strings and plain integers instead of LogicArrays. Prefer it over
monitors.MFBMonitor when monitor speed dominates a bench; it captures META only and its callbacks run in ReadOnly."""

from cocotb.triggers import RisingEdge, ReadOnly

from cocotbext.ofm.mfb import monitors
from cocotbext.ofm.mfb.transaction import MfbTransaction
from cocotbext.ofm.utils.signals import signal_binstr


class MFBMonitor(monitors.MFBMonitor):
    """Monitor for the MFB bus. `trans_type` is `bytes` or an `MfbTransaction` subclass; `meta_vld_with`
    ("sof" or "eof", default `os_vld_with`) qualifies META. Callbacks run in ReadOnly and must not write signals."""

    def __init__(self, entity, name, clock, array_idx=None, mfb_params=None, trans_type: MfbTransaction | bytes = bytes,
                 meta_vld_with: str | None = None, start: bool = True):
        super().__init__(entity, name, clock, array_idx=array_idx, mfb_params=mfb_params, trans_type=trans_type,
                         start=start)

        # The per-region field widths come from the signals, so they hold for inferred and explicit mfb_params.
        self._sof_pos_w = (self._region_size - 1).bit_length()
        self._eof_pos_w = len(self.bus.eof_pos) // self._regions

        # The bit string is taken from the simulator handle under the BusProxy; with an array_idx the handle
        # holds the whole array, so that case reads the proxied value instead.
        if array_idx is None:
            self._rbus = getattr(self.bus, "_bus", self.bus)
            self._binstr = signal_binstr
        else:
            self._rbus = self.bus
            self._binstr = lambda sig: str(sig.value)

        self._meta_vld_with = meta_vld_with or self._os_vld_with
        if self._meta_vld_with not in ["sof", "eof"]:
            raise ValueError(f"Invalid value of {self._meta_vld_with} of 'meta_vld_with'. Supported values are: \"sof\", \"eof\".")

    def _is_valid_word(self, signal_src_rdy, signal_dst_rdy):
        if self._binstr(signal_src_rdy) != "1":
            return False
        return signal_dst_rdy is None or self._binstr(signal_dst_rdy) == "1"

    def _word_valid(self):
        return self._is_valid_word(self._rbus.src_rdy, self._rbus.dst_rdy)

    def _read_control_signals(self):
        # Plain ints slice per region far cheaper than LogicArrays. A word holding any bit but 0 or 1 keeps the
        # LogicArrays, which _field and _data_bytes decode on their own.
        bus = self._rbus
        try:
            data = int(self._binstr(bus.data), 2)
            sof_pos = int(self._binstr(bus.sof_pos), 2)
            eof_pos = int(self._binstr(bus.eof_pos), 2)
            sof = int(self._binstr(bus.sof), 2)
            eof = int(self._binstr(bus.eof), 2)
            meta = int(self._binstr(bus.meta), 2) if self._meta_width > 0 else None
        except ValueError:
            self._data = bus.data.value
            self._sof_pos = bus.sof_pos.value
            self._eof_pos = bus.eof_pos.value
            self._sof = bus.sof.value
            self._eof = bus.eof.value
            if self._meta_width > 0:
                self._meta = bus.meta.value
            return

        self._data = data
        self._sof_pos = sof_pos
        self._eof_pos = eof_pos
        self._sof = [(sof >> r) & 1 for r in range(self._regions)]
        self._eof = [(eof >> r) & 1 for r in range(self._regions)]
        if meta is not None:
            self._meta = meta

    def _field(self, vec, r, width):
        """Unsigned value of the per-region `width`-bit field `r` of `vec`, an int or a LogicArray."""
        if width <= 0:
            return 0
        if isinstance(vec, int):
            return (vec >> (r * width)) & ((1 << width) - 1)
        return vec[(r + 1) * width - 1:r * width].to_unsigned()

    def _region_ctrl(self, r):
        sof = int(self._sof[r])
        eof = int(self._eof[r])
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
        """Capture META of region `r` when it is valid with `vld_with`, or unconditionally when that is None."""
        if self._meta_width > 0 and hasattr(self._transaction, "meta") and vld_with in (None, self._meta_vld_with):
            self._transaction.meta = self._field(self._meta, r, self._meta_width)

    async def _monitor_recv(self):
        clk_re = RisingEdge(self.clock)
        self._in_frame = False

        while True:
            await clk_re
            # ReadOnly samples the settled bus, the same point at which the drivers read DST_RDY.
            await ReadOnly()
            self.monitor_cycle()
