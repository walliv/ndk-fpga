# SPDX-License-Identifier: BSD-3-Clause
# Copyright (C) 2025 CESNET z. s. p. o.
# Author(s): Jakub Cabal <cabal@cesnet.cz>
#            Ondrej Schwarz <ondrejschwarz@cesnet.cz>

from cocotb_bus.monitors import BusMonitor
from cocotb.triggers import RisingEdge, ReadOnly
from cocotbext.ofm.mfb.utils import get_mfb_params, signal_binstr
from cocotbext.ofm.mfb.transaction import MfbTransaction
from math import log2
from copy import copy


class MFBProtocolError(Exception):
    pass


class MFBMonitor(BusMonitor):
    """Monitor for the MFB bus. `trans_type` is the returned transaction type (`bytes`, or an
    `MfbTransaction` subclass, the default); `meta_vld_with` ("sof" or "eof") names the signal that
    qualifies `meta` when present.
    """

    _signals = ["data", "sof_pos", "eof_pos", "sof", "eof", "src_rdy", "dst_rdy"]
    _optional_signals = ["meta"]

    def __init__(self, entity, name, clock, array_idx=None, mfb_params=None, trans_type: MfbTransaction | bytes = bytes, meta_vld_with: str = "sof"):
        super().__init__(entity, name, clock, array_idx=array_idx)

        self._regions, self._region_size, self._block_size, self._item_width, self._meta_width = get_mfb_params(
            self.bus, mfb_params
        )
        self._region_items = self._region_size * self._block_size

        self._trans_type  = trans_type
        self._transaction = MfbTransaction() if self._trans_type is bytes else trans_type()

        # Per-region field widths in bits, from the signal slices so they hold for inferred and
        # explicit mfb_params. SOF_POS uses log2(region_size), so the 1-bit dummy at region_size==1
        # has width 0.
        self._sof_pos_w     = int(log2(self._region_size))         # 0 when region_size==1
        self._eof_pos_w     = len(self.bus.eof_pos) // self._regions
        self._region_data_w = self._region_items*self._item_width  # data bits/region (= len(data)//regions)

        if self._meta_width > 0:
            if meta_vld_with not in ["sof", "eof"]:
                raise ValueError(f"Invalid value of {meta_vld_with} of 'meta_vld_with'. Supported values are: \"sof\", \"eof\".")

            self._meta_vld_with = meta_vld_with

        self.frame_cnt = 0
        self.item_cnt  = 0
        self._in_frame = False

    def _is_valid_word(self, signal_src_rdy, signal_dst_rdy):
        if signal_binstr(signal_src_rdy) != "1":
            return False
        return signal_dst_rdy is None or signal_binstr(signal_dst_rdy) == "1"

    def _read_control_signals(self):
        # Plain ints slice per region far cheaper than LogicArrays. A word holding any bit but 0/1
        # keeps the LogicArrays (range [W-1:0]), which _field and _data_bytes decode on their own.
        bus = self.bus
        try:
            data    = int(signal_binstr(bus.data), 2)
            sof_pos = int(signal_binstr(bus.sof_pos), 2)
            eof_pos = int(signal_binstr(bus.eof_pos), 2)
            sof     = int(signal_binstr(bus.sof), 2)
            eof     = int(signal_binstr(bus.eof), 2)
            meta    = int(signal_binstr(bus.meta), 2) if self._meta_width > 0 else None
        except ValueError:
            self._data    = bus.data.value
            self._sof_pos = bus.sof_pos.value
            self._eof_pos = bus.eof_pos.value
            self._sof     = bus.sof.value
            self._eof     = bus.eof.value
            if self._meta_width > 0:
                self._meta = bus.meta.value
            return

        self._data    = data
        self._sof_pos = sof_pos
        self._eof_pos = eof_pos
        self._sof     = [(sof >> r) & 1 for r in range(self._regions)]
        self._eof     = [(eof >> r) & 1 for r in range(self._regions)]
        if meta is not None:
            self._meta = meta

    def _field(self, vec, r, width):
        """Unsigned value of the per-region ``width``-bit field ``r`` of ``vec``, an int or a
        LogicArray."""
        if width <= 0:
            return 0
        if isinstance(vec, int):
            return (vec >> (r*width)) & ((1 << width) - 1)
        return vec[(r + 1)*width - 1 : r*width].to_unsigned()

    def _data_bytes(self, r, lo, hi):
        """Little-endian bytes of region ``r`` data bits ``[lo:hi)`` (positions LSB-first)."""
        if hi <= lo:
            return b""
        base = r*self._region_data_w
        if isinstance(self._data, int):
            n = hi - lo
            return ((self._data >> (base + lo)) & ((1 << n) - 1)).to_bytes((n + 7) // 8, byteorder="little")
        return self._data[base + hi - 1 : base + lo].to_bytes(byteorder="little")

    def _recv_trans(self):
        self.log.debug(f"received transaction: {self._transaction}")

        if self._trans_type is bytes:
            self._recv(self._transaction.data)
        else:
            self._recv(copy(self._transaction))

    async def _monitor_recv(self):
        clk_re = RisingEdge(self.clock)
        self._in_frame = False

        while True:
            await clk_re
            await ReadOnly()          # settle clocked processes; sample the stable bus
                                      # (matches MFBDriver._wait_ready, drivers.py:100)
            self.monitor_cycle()

    def monitor_cycle(self):
        """One cycle's sampling, for a bench that drives many monitors from one task of its own
        (kill() this monitor's own task first)."""
        if self.in_reset:
            return

        if self._is_valid_word(self.bus.src_rdy, self.bus.dst_rdy):
            self._read_control_signals()

            for r in range(self._regions):
                sof = int(self._sof[r])
                eof = int(self._eof[r])

                sof_pos = self._field(self._sof_pos, r, self._sof_pos_w) if sof else 0
                eof_pos = self._field(self._eof_pos, r, self._eof_pos_w) if eof else 0

                pkt_start = sof_pos * self._block_size * self._item_width
                pkt_end   = (eof_pos + 1) * self._item_width

                if self._in_frame:
                    if sof and eof:
                        # if sof appears before eof
                        if self._region_size > 1:
                            if pkt_end > pkt_start:
                                raise MFBProtocolError(f"MFB error: a start-of-frame received without an end-of-frame! ({sof_pos=}, {eof_pos=})")

                        # end of one packet
                        self._transaction.data += self._data_bytes(r, 0, pkt_end)
                        self._recv_trans()
                        self.frame_cnt += 1
                        self.item_cnt += len(self._transaction.data) * 8 // self._item_width

                        # start of another packet, in_frame stays True
                        self._transaction.data = self._data_bytes(r, pkt_start, self._region_data_w)
                        if self._meta_width > 0 and hasattr(self._transaction, "meta") and self._meta_vld_with == "sof":
                            self._transaction.meta = self._field(self._meta, r, self._meta_width)

                    elif sof:
                        # sof when the previous packet hasn't ended
                        raise MFBProtocolError(f"MFB error: a start-of-frame received without an end-of-frame! ({sof_pos=})")

                    elif eof:
                        # packet ends in this region and new one doesn't start
                        self._transaction.data += self._data_bytes(r, 0, pkt_end)
                        if self._meta_width > 0 and hasattr(self._transaction, "meta") and self._meta_vld_with == "eof":
                            self._transaction.meta = self._field(self._meta, r, self._meta_width)
                        self._recv_trans()
                        self._in_frame = False
                        self.frame_cnt += 1
                        self.item_cnt += len(self._transaction.data) * 8 // self._item_width

                    else:
                        # packet starts and ends in another region, in_frame stays True
                        self._transaction.data += self._data_bytes(r, 0, self._region_data_w)

                else:
                    if sof and eof:
                        # packet starts and ends in this region, in_frame stays False
                        self._transaction.data = self._data_bytes(r, pkt_start, pkt_end)
                        if self._meta_width > 0 and hasattr(self._transaction, "meta"):
                            self._transaction.meta = self._field(self._meta, r, self._meta_width)
                        self._recv_trans()
                        self.frame_cnt += 1
                        self.item_cnt += len(self._transaction.data) * 8 // self._item_width

                    elif sof:
                        # packet starts in this regions and ends in another one
                        self._transaction.data = self._data_bytes(r, pkt_start, self._region_data_w)
                        if self._meta_width > 0 and hasattr(self._transaction, "meta") and self._meta_vld_with == "sof":
                            self._transaction.meta = self._field(self._meta, r, self._meta_width)
                        self._in_frame = True

                    elif eof:
                        # eof when not in frame
                        raise MFBProtocolError("MFB error: an end-of-frame received before a start-of-frame!")
