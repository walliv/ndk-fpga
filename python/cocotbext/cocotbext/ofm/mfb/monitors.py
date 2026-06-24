# SPDX-License-Identifier: BSD-3-Clause
# Copyright (C) 2025 CESNET z. s. p. o.
# Author(s): Jakub Cabal <cabal@cesnet.cz>
#            Ondrej Schwarz <ondrejschwarz@cesnet.cz>

from cocotb_bus.monitors import BusMonitor
from cocotb.triggers import RisingEdge, ReadOnly
from cocotbext.ofm.mfb.utils import get_mfb_params
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
                         if the 'meta' signal is present. Must be either "sof" (start of frame)
                         or "eof" (end of frame).
    """

    _signals = ["data", "sof_pos", "eof_pos", "sof", "eof", "src_rdy", "dst_rdy"]
    _optional_signals = ["meta"]

    def __init__(self, entity, name, clock, array_idx=None, mfb_params=None, trans_type: MfbTransaction | bytes = MfbTransaction, meta_vld_with: str = "sof"):
        super().__init__(entity, name, clock, array_idx=array_idx)

        self._regions, self._region_size, self._block_size, self._item_width, self._meta_width = get_mfb_params(
            self.bus, mfb_params
        )
        self._region_items = self._region_size * self._block_size

        self._trans_type  = trans_type
        self._transaction = MfbTransaction() if self._trans_type is bytes else trans_type()

        # Per-region field widths in bits, taken from the ACTUAL signal slices so
        # they stay in range whether mfb_params were inferred or passed explicitly.
        # EOF_POS width is read straight off the signal (len(eof_pos)//regions);
        # SOF_POS uses log2(region_size) so the region_size==1 placeholder bit
        # (a 1-bit dummy SOF_POS) is treated as width 0. The bus values are read
        # each cycle as cocotb LogicArray/Logic snapshots; _field()/_data_bytes()
        # slice them.
        self._sof_pos_w     = int(log2(self._region_size))         # 0 when region_size==1
        self._eof_pos_w     = len(self.bus.eof_pos) // self._regions
        self._region_data_w = self._region_items*self._item_width  # data bits/region (= len(data)//regions)

        if self._meta_width > 0:
            if meta_vld_with not in ["sof", "eof"]:
                raise ValueError(f"Invalid value of {meta_vld_with} of 'meta_vld_with'. Supported values are: \"sof\", \"eof\".")

            self._meta_vld_with = meta_vld_with

        self.frame_cnt = 0
        self.item_cnt  = 0

    def _is_valid_word(self, signal_src_rdy, signal_dst_rdy):
        if signal_dst_rdy is None:
            return (signal_src_rdy.value == 1)
        else:
            return (signal_src_rdy.value == 1) and (signal_dst_rdy.value == 1)

    def _read_control_signals(self):
        # Snapshot the bus as cocotb LogicArray/Logic values (range [W-1:0]).
        self._data    = self.bus.data.value
        self._sof_pos = self.bus.sof_pos.value
        self._eof_pos = self.bus.eof_pos.value
        self._sof     = self.bus.sof.value
        self._eof     = self.bus.eof.value

        if self._meta_width > 0:
            self._meta = self.bus.meta.value

    def _field(self, vec, r, width):
        """Unsigned value of the per-region ``width``-bit field ``r`` of LogicArray ``vec``."""
        if width <= 0:
            return 0
        return vec[(r + 1)*width - 1 : r*width].to_unsigned()

    def _data_bytes(self, r, lo, hi):
        """Little-endian bytes of region ``r`` data bits ``[lo:hi)`` (positions LSB-first)."""
        if hi <= lo:
            return b""
        base = r*self._region_data_w
        return self._data[base + hi - 1 : base + lo].to_bytes(byteorder="little")

    def _recv_trans(self):
        self.log.debug(f"received transaction: {self._transaction}")

        if self._trans_type is bytes:
            self._recv(self._transaction.data)
        else:
            self._recv(copy(self._transaction))

    async def _monitor_recv(self):
        clk_re = RisingEdge(self.clock)
        in_frame = False

        while True:
            await clk_re
            await ReadOnly()          # settle clocked processes; sample the stable bus
                                      # (matches MFBDriver._wait_ready, drivers.py:100)

            if self.in_reset:
                continue

            if self._is_valid_word(self.bus.src_rdy, self.bus.dst_rdy):
                self._read_control_signals()

                for r in range(self._regions):
                    sof = int(self._sof[r])
                    eof = int(self._eof[r])

                    sof_pos = self._field(self._sof_pos, r, self._sof_pos_w) if sof else 0
                    eof_pos = self._field(self._eof_pos, r, self._eof_pos_w) if eof else 0

                    pkt_start = sof_pos * self._block_size * self._item_width
                    pkt_end   = (eof_pos + 1) * self._item_width

                    if in_frame:
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
                            in_frame = False
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
                            in_frame = True

                        elif eof:
                            # eof when not in frame
                            raise MFBProtocolError("MFB error: an end-of-frame received before a start-of-frame!")
