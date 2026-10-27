# fast_drivers.py: MFBDriver with a fast word accumulator, gaps inside frames and byte enables
# Copyright (C) 2024 CESNET z. s. p. o.
# Copyright (C) 2025 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Jakub Cabal <cabal@cesnet.cz>
#            Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: BSD-3-Clause OR Apache-2.0
"""MFBDriver on cocotb_bus.ValidatedBusDriver that can leave SRC_RDY low inside a frame and drive BE. Prefer it over
drivers.MFBDriver when driver speed dominates a long, wide-bus bench; drivers.MFBDriver has the idle-generator API."""

import logging
from collections import deque
from typing import Any, Union

from cocotb.triggers import RisingEdge, ReadOnly
from cocotb.types import LogicArray, Logic

from cocotb_bus.drivers import ValidatedBusDriver
from cocotbext.ofm.mfb.protocol import MfbParams
from cocotbext.ofm.mfb.utils import get_mfb_params, random_tuple_iterator
from cocotbext.ofm.mfb.transaction import MfbTransaction

# Marks "no vld_gen given" so that every driver builds its own gap generator instead of sharing one.
_DEFAULT_VLD_GEN = object()


def meta_logic(meta: Union[bytes, LogicArray, int], width: int) -> LogicArray:
    """The META of a transaction, given as bytes, a LogicArray or an int, as a LogicArray of `width` bits. Bytes are
    little-endian, as DATA and the META of drivers.MFBDriver."""
    if isinstance(meta, bytes):
        return LogicArray.from_unsigned(int.from_bytes(meta, byteorder="little"), width)
    if isinstance(meta, LogicArray):
        return meta
    if isinstance(meta, int):
        return LogicArray.from_unsigned(meta, width)
    raise TypeError(f"Unsupported type of meta in MfbTransaction: {type(meta)}")


class MFBDriver(ValidatedBusDriver):
    _signals = ["data", "sof_pos", "eof_pos", "sof", "eof", "src_rdy", "dst_rdy"]
    _optional_signals = ["meta", "be"]

    # Passing vld_gen=None makes the driver send at full throughput.
    def __init__(self, entity, name, clock, mfb_params=None, vld_gen=_DEFAULT_VLD_GEN, **kwargs):
        if vld_gen is _DEFAULT_VLD_GEN:
            vld_gen = random_tuple_iterator(1, 100, 1, 100)
        super().__init__(entity, name, clock, valid_generator=vld_gen, **kwargs)
        self.clock = clock
        self.frame_cnt = 0
        # Counts driven items like MFBMonitor.item_cnt, which ThroughputProbeMfbInterface expects.
        self.item_cnt = 0
        self._regions, self._region_size, self._block_size, self._item_width, self._meta_width, _ = get_mfb_params(
            self.bus, mfb_params
        )

        geom = MfbParams(self._regions, self._region_size, self._block_size, self._item_width)
        # ThroughputProbeMfbInterface reads _regions * _region_items as the bus capacity per cycle.
        self._region_items = geom.region_items
        self._word_bit_width = geom.word_width
        self._rgn_bit_width = self._region_items * self._item_width
        self._blk_bit_width = self._block_size * self._item_width
        self._blk_byte_width = self._block_size * self._item_width // 8
        self._last_blk_idx = 0
        self._last_rgn_idx = 0

        self.log.debug(f"Inferred MFB configuration: {self._regions=}, {self._region_size=}, {self._block_size=}, {self._item_width=}, {self._meta_width=}")

        # Widths per region
        self._sof_pos_w_pr = geom.sof_pos_width
        self._eof_pos_w_pr = geom.eof_pos_width

        assert self._regions > 0
        assert self._region_size > 0
        assert self._block_size > 0
        assert self._item_width > 0
        assert self._item_width % 8 == 0
        assert self._meta_width >= 0
        if hasattr(self.bus, "be"):
            assert len(self.bus.be) == self._word_bit_width // 8

        self._clr_physical_bus()
        self._clr_internal_bus()

        self._wordQ = deque()
        self._sending = False

    def _clr_physical_bus(self):
        if hasattr(self.bus, 'meta'):
            self.bus.meta.value = 0
        if hasattr(self.bus, 'be'):
            self.bus.be.value = 0

        self.bus.data.value = 0
        self.bus.sof.value = 0
        self.bus.eof.value = 0
        self.bus.sof_pos.value = 0
        self.bus.eof_pos.value = 0
        self.bus.src_rdy.value = 0

    def _clr_internal_bus(self):
        # Optional signals
        if hasattr(self.bus, 'meta'):
            self._meta_int = LogicArray(0, self._regions*self._meta_width)
        else:
            self._meta_int = None

        if hasattr(self.bus, 'be'):
            self._be_int = LogicArray(0, self._word_bit_width // 8)
        else:
            self._be_int = None

        # A plain int accumulates the word because LogicArray.__setitem__ builds a Logic per bit,
        # which is the hot-path cost for a wide word; it converts once on assignment to bus.data.
        self._data_int = 0
        self._sof_int = LogicArray(0, self._regions)
        self._eof_int = LogicArray(0, self._regions)
        self._sof_pos_int = LogicArray(0, self._regions*max(1, self._sof_pos_w_pr))
        self._eof_pos_int = LogicArray(0, self._regions*max(1, self._eof_pos_w_pr))
        self._src_rdy_int = Logic("0")

    async def _wait_ready(self):
        await ReadOnly()
        while not bool(self.bus.dst_rdy.value):
            self.log.debug(f"DST_RDY: {bool(self.bus.dst_rdy.value)}")
            await RisingEdge(self.clock)
            await ReadOnly()

    async def _driver_send(self, trans: Union[MfbTransaction, LogicArray, bytes], sync: bool = True, **kwargs: Any) -> None:
        # The word accumulator and (rgn, blk) cursor are per-instance, so concurrent sends would
        # interleave bus writes in one timestep and the later one would silently cost a frame its SOF.
        if self._sending:
            raise RuntimeError(
                f"MFBDriver({self.name}): send() called while another send is in flight. Await the "
                f"previous send, or use append(), which _send_thread serialises.")
        self._sending = True
        try:
            await self._driver_send_impl(trans, sync=sync, **kwargs)
        finally:
            self._sending = False

    async def _driver_send_impl(self, trans, sync: bool = True, **kwargs: Any) -> None:
        ce = RisingEdge(self.clock)

        data = None
        meta = None
        be = None
        # Raw payload bytes allow per-block slicing without an O(n^2) pass over a whole-payload LogicArray.
        data_bytes = None

        if isinstance(trans, MfbTransaction):
            if isinstance(trans.data, (bytes, bytearray)):
                data_bytes = bytes(trans.data)
                data_byte_len = len(trans.data)
                data_bit_len = data_byte_len * 8
            elif isinstance(trans.data, LogicArray):
                data = trans.data
                data_byte_len = len(trans.data) // 8
                data_bit_len = len(trans.data)
                assert data_bit_len % 8 == 0
            else:
                raise TypeError(f"Unsupported type of data in MfbTransaction: {type(trans.data)}")

            if hasattr(self.bus, "meta"):
                # A bus without META keeps meta as None, because LogicArray(0, 0) cannot be built.
                if hasattr(trans, "meta"):
                    meta = meta_logic(trans.meta, self._meta_width)
                else:
                    meta = LogicArray(0, self._meta_width)

            if hasattr(self.bus, "be") and hasattr(trans, "be"):
                if isinstance(trans.be, int):
                    be = LogicArray.from_unsigned(trans.be, data_byte_len)
                elif isinstance(trans.be, LogicArray):
                    be = trans.be
                else:
                    raise TypeError(f"Unsupported type of be in MfbTransaction: {type(trans.be)}")

        elif isinstance(trans, (bytes, bytearray)):
            data_bytes = bytes(trans)
            data_bit_len = len(trans) * 8
            if hasattr(self.bus, 'meta'):
                meta = LogicArray(0, self._meta_width)

        elif isinstance(trans, LogicArray):
            data = trans
            data_bit_len = len(trans)
            if hasattr(self.bus, 'meta'):
                meta = LogicArray(0, self._meta_width)
        else:
            raise TypeError(f"Unsupported type of transaction: {type(trans)}")

        # Without an explicit BE every byte of the payload is enabled.
        if hasattr(self.bus, "be") and be is None:
            be = LogicArray.from_unsigned((1 << (data_bit_len // 8)) - 1, data_bit_len // 8)

        # hex() of a whole-payload LogicArray is O(payload), so it is built only when logging.
        if self.log.isEnabledFor(logging.DEBUG):
            data_disp = data if data is not None else LogicArray.from_bytes(data_bytes, byteorder="little")
            self.log.debug(f"Data: (len {data_bit_len} bits = {data_bit_len // 8} bytes)\n{hex(data_disp)}")
            if meta is not None:
                self.log.debug(f"Meta: (len {len(meta)} bits)\n{hex(meta)}")
            if be is not None:
                self.log.debug(f"BE: {hex(be)}")

        # inp_data_blk_idx counts the input blocks consumed so far.
        inp_data_blk_idx = 0
        pkt_finished = False

        # A packet cannot start in a region that already holds a SOF, nor in one whose EOF it would
        # follow within the same region, since that would put two EOFs in the region.
        if self._sof_int[self._last_rgn_idx] == 1 or (self._eof_int[self._last_rgn_idx] == 1 and (self._rgn_bit_width >= (self._last_blk_idx*self._blk_bit_width + data_bit_len))):
            self.log.debug(f"Either a SOF: {self._sof_int[self._last_rgn_idx]} or an EOF: {self._eof_int[self._last_rgn_idx]} is in the current region but the packet is too small.")
            self._last_rgn_idx = (self._last_rgn_idx + 1) % self._regions
            self._last_blk_idx = 0

            # The new region lies in the next bus word, so the word being prepared is dispatched first.
            if self._last_rgn_idx == 0:
                self._wordQ.appendleft((self._data_int, self._meta_int, self._sof_int, self._eof_int, self._sof_pos_int, self._eof_pos_int, self._src_rdy_int, self._be_int))
                self._clr_internal_bus()

        while inp_data_blk_idx*self._blk_bit_width < data_bit_len:
            self.log.debug("==================================================================================================")
            self.log.debug(f"Initiated new word starting in {inp_data_blk_idx*self._blk_bit_width} bit of input data.")
            self.log.debug(f"(RGN, BLK) = ({self._last_rgn_idx}, {self._last_blk_idx})")

            # Iterate over regions in the MFB word
            for rgn_idx in range(self._last_rgn_idx, self._regions):
                # Iterate over blocks in every region
                for blk_idx in range(self._last_blk_idx, self._region_size):
                    self.log.debug("--------------------------------------------------------------------------------------------------")
                    self.log.debug(f"Processing (RGN, BLK) = ({rgn_idx}, {blk_idx}) and bits {inp_data_blk_idx*self._blk_bit_width}/{data_bit_len} of data")
                    self.log.debug(f"Valid blocks: {self.on}, invalid blocks: {self.off}")

                    self._src_rdy_int = 1

                    if (inp_data_blk_idx == 0):
                        if hasattr(self.bus, 'meta'):
                            self._meta_int[rgn_idx*self._meta_width + self._meta_width-1 : rgn_idx*self._meta_width] = meta
                        self._sof_int[rgn_idx] = 1
                        if self._sof_pos_w_pr > 0:
                            self._sof_pos_int[rgn_idx*self._sof_pos_w_pr + self._sof_pos_w_pr - 1 : rgn_idx*self._sof_pos_w_pr] = blk_idx

                    # Truncate as necessary if this is a last block, otherwise keep the size of the MFB block
                    data_rest_len = data_bit_len - inp_data_blk_idx*self._blk_bit_width
                    data_rest_len = self._blk_bit_width if self._blk_bit_width < data_rest_len else data_rest_len
                    assert data_rest_len >= 0

                    bus_idx_low = rgn_idx*self._rgn_bit_width + blk_idx*self._blk_bit_width
                    bus_idx_high = rgn_idx*self._rgn_bit_width + blk_idx*self._blk_bit_width + data_rest_len - 1
                    self.log.debug(f"Bus range to write [{bus_idx_high} : {bus_idx_low}]")
                    self.log.debug(f"Range of input data [{inp_data_blk_idx*self._blk_bit_width + data_rest_len - 1} : {inp_data_blk_idx*self._blk_bit_width}]")
                    if data_bytes is not None:
                        # Block boundaries are byte-aligned, so the raw bytes are sliced per block.
                        byte_lo = (inp_data_blk_idx*self._blk_bit_width) // 8
                        byte_hi = byte_lo + (data_rest_len // 8)
                        blk_value = int.from_bytes(data_bytes[byte_lo:byte_hi], byteorder="little")
                    else:
                        blk_value = int(data[inp_data_blk_idx*self._blk_bit_width + data_rest_len - 1 : inp_data_blk_idx*self._blk_bit_width])
                    # Clearing the destination bits first keeps the last write winning.
                    blk_mask = (1 << data_rest_len) - 1
                    self._data_int &= ~(blk_mask << bus_idx_low)
                    self._data_int |= (blk_value & blk_mask) << bus_idx_low
                    if hasattr(self.bus, 'be'):
                        self.log.debug(f"BE Bus range to write [{bus_idx_high // 8} : {bus_idx_low // 8}]")
                        self.log.debug(f"Range of input BE [{inp_data_blk_idx*self._blk_byte_width + (data_rest_len // 8) - 1} : {inp_data_blk_idx*self._blk_byte_width}]")
                        self._be_int[bus_idx_high // 8 : bus_idx_low // 8] \
                            = be[inp_data_blk_idx*self._blk_byte_width + (data_rest_len // 8) - 1 : inp_data_blk_idx*self._blk_byte_width]

                    inp_data_blk_idx += 1

                    if self.on is not True and self.on > 0:
                        self.on -= 1

                    if data_bit_len <= inp_data_blk_idx*self._blk_bit_width:
                        self._eof_int[rgn_idx] = 1
                        self._eof_pos_int[rgn_idx*self._eof_pos_w_pr + self._eof_pos_w_pr - 1 : rgn_idx*self._eof_pos_w_pr] \
                            = (blk_idx * self._blk_bit_width + data_rest_len - 1) // self._item_width
                        self.log.debug(f"setting EOF_POS = {(blk_idx * self._blk_bit_width + data_rest_len - 1) // self._item_width}")
                        self._last_blk_idx = (blk_idx + 1) % self._region_size

                        if blk_idx == self._region_size-1:
                            self._last_rgn_idx = (rgn_idx + 1) % self._regions
                        else:
                            self._last_rgn_idx = rgn_idx

                        pkt_finished = True
                        break
                else:
                    self._last_blk_idx = 0

                if pkt_finished:
                    break
            else:
                self._last_rgn_idx = 0

            word_finished = not pkt_finished and self._last_blk_idx == 0 and self._last_rgn_idx == 0
            no_space = pkt_finished and self._last_blk_idx == 0 and self._last_rgn_idx == 0
            no_next_pkt = pkt_finished and not self._sendQ
            no_vld_blocks = self.on is not True and self.on <= 0
            self.log.debug(f"Valid word: {word_finished=}, {no_space=}, {no_next_pkt=}, {no_vld_blocks=}, {self._last_rgn_idx=}, {self._last_blk_idx=}")

            if word_finished or no_space or no_next_pkt or no_vld_blocks:
                self.log.debug(f"Writing word into deque SOF: {bin(self._sof_int)}, EOF: {bin(self._eof_int)}, SOF_POS: {bin(self._sof_pos_int)}, EOF_POS: {bin(self._eof_pos_int)}")
                self._wordQ.appendleft((self._data_int, self._meta_int, self._sof_int, self._eof_int, self._sof_pos_int, self._eof_pos_int, self._src_rdy_int, self._be_int))
                self._clr_internal_bus()

            # Consume invalid blocks
            if no_vld_blocks:
                inv_finished = False

                while self.off > 0:

                    self.log.debug("--------------------------------------------------------------------")
                    self.log.debug(f"Consuming invalid blocks {self.off=}, {self._last_rgn_idx=}, {self._last_blk_idx=}")

                    # Either the packet finishes in this word and the invalid blocks count from here, or the word
                    # fills up and they count from the next one.
                    for rgn_idx in range(self._last_rgn_idx, self._regions):
                        for blk_idx in range(self._last_blk_idx, self._region_size):
                            self.off -= 1

                            if self.off <= 0:
                                inv_finished = True
                                # After a finished packet the next one may start mid-region, so a partly invalid word
                                # is possible; mid-packet only whole invalid words are.
                                if pkt_finished:
                                    self._last_blk_idx = (blk_idx + 1) % self._region_size

                                    if blk_idx == self._region_size-1:
                                        self._last_rgn_idx = (rgn_idx + 1) % self._regions
                                    else:
                                        self._last_rgn_idx = rgn_idx
                                    break
                        else:
                            self._last_blk_idx = 0

                        if inv_finished:
                            break
                    else:
                        self._last_rgn_idx = 0

                    self.log.debug(f"The counting of invalid or partially invalid word finished: {self._last_rgn_idx=}, {self._last_blk_idx=}, {inv_finished=}")
                    # A finished packet queues its partly invalid word only once it ended in the last block.
                    if (not pkt_finished) or (pkt_finished and no_space):
                        self.log.debug("Invalid word written to queue...")
                        self._wordQ.appendleft((self._data_int, self._meta_int, self._sof_int, self._eof_int, self._sof_pos_int, self._eof_pos_int, self._src_rdy_int, self._be_int))

                self._next_valids()
                self.log.debug("----------------------------------------------------------------------")

        while self._wordQ:
            await ce
            data_w, meta_w, sof_w, eof_w, sof_pos_w, eof_pos_w, src_rdy_w, be_w = self._wordQ.pop()

            self.bus.data.value = data_w
            if hasattr(self.bus, 'meta'):
                self.bus.meta.value = meta_w
            if hasattr(self.bus, 'be'):
                self.bus.be.value = be_w
            self.bus.sof.value = sof_w
            self.bus.eof.value = eof_w
            self.bus.sof_pos.value = sof_pos_w
            self.bus.eof_pos.value = eof_pos_w
            self.bus.src_rdy.value = src_rdy_w

            # A word with SRC_RDY low transfers nothing, so it takes one clock whatever DST_RDY is.
            if int(src_rdy_w):
                await self._wait_ready()

        # If there are no more packets, put 0 to the output bus
        if not self._sendQ:
            await ce
            self._clr_physical_bus()

        # Check if word queue is empty
        assert not self._wordQ

        self.frame_cnt += 1
        # The sink has accepted every word of the frame by now, so only transferred items are counted.
        self.item_cnt += data_bit_len // self._item_width
        self.log.debug("Transaction send finished!")
        self.log.debug("==================================================================================================")
