# SPDX-License-Identifier: BSD-3-Clause
# Copyright (C) 2024-2026 CESNET z. s. p. o.
# Author(s): Jakub Cabal <cabal@cesnet.cz>
#            Ondrej Schwarz <ondrejschwarz@cesnet.cz>

from cocotb.triggers import RisingEdge
from cocotb.types import LogicArray
from cocotbext.ofm.base.types import LogicArray2D
from cocotbext.ofm.base.monitors import BusMonitor
from cocotbext.ofm.mfb.utils import get_mfb_params, region_frame_event
from cocotbext.ofm.mfb.transaction import MfbTransaction
from math import log2
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

        meta_valid_with: Specifies which signal indicates the validity of metadata
                         if the 'meta' or similar signal is present. Must be either "sof" (start of frame)
                         or "eof" (end of frame).
    """

    _signals = ["data", "sof_pos", "eof_pos", "sof", "eof", "src_rdy", "dst_rdy"]
    _optional_signals = ["meta"]

    def __init__(self, entity, name, clock, array_idx=None, mfb_params=None, trans_type: MfbTransaction | bytes = bytes):
        super().__init__(entity, name, clock, array_idx=array_idx)

        self._regions, self._region_size, self._block_size, self._item_width, self._meta_width, self._os_vld_with = get_mfb_params(
            self.bus, mfb_params
        )
        self._region_items = self._region_size * self._block_size
        self._region_data_w = self._region_items * self._item_width
        self._os = [s for s in self._optional_signals if hasattr(self.bus, s)]
        self._os_widths = {s: len(getattr(self.bus, s)) // self._regions for s in self._os}

        self._trans_type  = trans_type
        self._transaction = MfbTransaction() if self._trans_type is bytes else trans_type()

        self._data    = LogicArray2D(self._regions)(self._region_items * self._item_width)
        self._sof_pos = LogicArray2D(self._regions)(int(log2(self._region_size)))
        self._eof_pos = LogicArray2D(self._regions)(int(log2(self._region_size*self._block_size)))
        self._sof     = LogicArray(0, self._regions)
        self._eof     = LogicArray(0, self._regions)
        self._os_data = {s: LogicArray2D(self._regions)(self._os_widths[s]) for s in self._os}

        self.frame_cnt = 0
        self.item_cnt  = 0
        self._in_frame = False

    def _is_valid_word(self, signal_src_rdy, signal_dst_rdy):
        if signal_dst_rdy is None:
            return (signal_src_rdy.value == 1)
        else:
            return (signal_src_rdy.value == 1) and (signal_dst_rdy.value == 1)

    def _read_control_signals(self):
        self._data.deserialize(self.bus.data.value)

        if self._sof_pos is not None:
            self._sof_pos.deserialize(self.bus.sof_pos.value)

        if self._eof_pos is not None:
            self._eof_pos.deserialize(self.bus.eof_pos.value)

        self._sof = self.bus.sof.value
        self._eof = self.bus.eof.value

        for s in self._os:
            sig_val = getattr(self.bus, s).value

            if len(sig_val) > 0:
                self._os_data[s].deserialize(sig_val)

    def _word_valid(self):
        return self._is_valid_word(self.bus.src_rdy, self.bus.dst_rdy)

    def _region_ctrl(self, r):
        """SOF, EOF, SOF_POS and EOF_POS of region `r`, a position 0 where its flag is not set."""
        sof = self._sof[r]
        eof = self._eof[r]

        if self._sof_pos is not None:
            sof_pos = self._sof_pos[r].to_unsigned() if sof else 0
        else:
            sof_pos = 0

        if self._eof_pos is not None:
            eof_pos = self._eof_pos[r].to_unsigned() if eof else 0
        else:
            eof_pos = 0

        return sof, eof, sof_pos, eof_pos

    def _data_bytes(self, r, lo, hi):
        """Little-endian bytes of region `r` data bits [lo:hi), counted from the LSB."""
        return self._data[r][hi - 1:lo].to_bytes(byteorder="little")

    def _set_os(self, r, vld_with=None):
        """Read the optional signals of region `r` when they are valid with `vld_with`, or unconditionally when None."""
        if vld_with is not None and vld_with != self._os_vld_with:
            return
        for s in self._os:
            if self._os_data[s] is not None:
                setattr(self._transaction, s, self._os_data[s][r].to_unsigned())

    def _recv_trans(self):
        self.log.debug(f"received transaction: {self._transaction}")

        if self._trans_type is bytes:
            self._recv(self._transaction.data)
        else:
            self._recv(copy(self._transaction))

    def _frame_received(self):
        self._recv_trans()
        self.frame_cnt += 1
        self.item_cnt += (len(self._transaction.data) * 8) // self._item_width

    async def _monitor_recv(self):
        clk_re = RisingEdge(self.clock)
        self._in_frame = False

        while True:
            await clk_re
            self.monitor_cycle()

    def monitor_cycle(self):
        """One cycle's sampling of the bus."""
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
                    self._transaction.data = self._data_bytes(r, pkt_start, self._region_data_w)
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
                    self._transaction.data = self._data_bytes(r, pkt_start, self._region_data_w)
                    self._set_os(r, "sof")
                    self._in_frame = True

                elif event == "end":
                    # eof when not in frame
                    raise MFBProtocolError("MFB error: an end-of-frame received before a start-of-frame!")
