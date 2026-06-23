# drivers.py: MFBDriver
# Copyright (C) 2024 CESNET z. s. p. o.
# Copyright (C) 2025 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Jakub Cabal <cabal@cesnet.cz>
#            Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: BSD-3-Clause OR Apache-2.0

from math import log2
from typing import Any, Union
from collections import deque

import cocotb
from cocotb.triggers import RisingEdge, ReadOnly
from cocotb.types import LogicArray, Logic

from cocotb_bus.drivers import ValidatedBusDriver
from cocotbext.ofm.mfb.utils import get_mfb_params, random_tuple_iterator
from cocotbext.ofm.mfb.transaction import MfbTransaction
from cocotbext.ofm.pcie.PcieHeaders import CQMfbMeta

# NOTE: There were many achievements in this implementation of a general MFB Driver that also inserts
# some gaps between packets if vld_gen is not null. Although there are many of its parts written
# with an explaining commentary, some parts originate from a testing and its reasoning remains
# unknown. We attribute these to divine providence.

class MFBDriver(ValidatedBusDriver):
    _signals = ["data", "sof_pos", "eof_pos", "sof", "eof", "src_rdy", "dst_rdy"]
    _optional_signals = ["meta", "be"]

    # By passing vld_gen as Null, the driver generates on full throughput
    def __init__(self, entity, name, clock, mfb_params=None, vld_gen=random_tuple_iterator(1,100,1,100), **kwargs):
        super().__init__(entity, name, clock, valid_generator=vld_gen, **kwargs)
        self.clock = clock
        self.frame_cnt = 0
        self._regions, self._region_size, self._block_size, self._item_width, self._meta_width = get_mfb_params(
            self.bus, mfb_params
        )

        self._word_bit_width = self._regions*self._region_size * self._block_size * self._item_width
        self._rgn_bit_width = self._region_size * self._block_size * self._item_width
        self._blk_bit_width = self._block_size * self._item_width
        self._blk_byte_width = self._block_size * self._item_width // 8
        self._last_blk_idx = 0
        self._last_rgn_idx = 0

        self.log.debug(f"Inferred MFB configuration: {self._regions=}, {self._region_size=}, {self._block_size=}, {self._item_width=}, {self._meta_width=}")

        # Widths per region
        self._sof_pos_w_pr = int(log2(self._region_size))
        self._eof_pos_w_pr = int(log2(self._region_size*self._block_size))

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

        # Base signals
        self._data_int = LogicArray(0, self._word_bit_width)
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

    async def _driver_send(self, trans : Union[MfbTransaction, LogicArray, bytes], sync: bool = True, **kwargs : Any) -> None:
        ce = RisingEdge(self.clock)

        # --------------------------------------------------------------------------------
        # Convert input transaction to LogicArray (first has name data, the second meta)
        # --------------------------------------------------------------------------------
        data = None
        meta = None
        be = None

        if isinstance(trans, MfbTransaction):
            if isinstance(trans.data, (bytes, bytearray)):
                data = LogicArray.from_bytes(trans.data, byteorder="little")
                data_byte_len = len(trans.data)
            elif isinstance(trans.data, LogicArray):
                data = trans.data
                data_byte_len = len(trans.data) // 8
                assert data_byte_len % 8 == 0
            else:
                raise TypeError(f"Unsupported type of data in MfbTransaction: {type(trans.data)}")

            if hasattr(self.bus, "meta") and hasattr(trans, "meta"):
                if isinstance(trans.meta, bytes):
                    meta = LogicArray.from_bytes(trans.meta, byteorder="big")
                elif isinstance(trans.meta, LogicArray):
                    meta = trans.meta
                elif isinstance(trans.meta, int):
                    meta = LogicArray.from_unsigned(trans.meta, self._meta_width)
                else:
                    raise TypeError(f"Unsupported type of meta in MfbTransaction: {type(trans.meta)}")
            else:
                meta = LogicArray(0, self._meta_width)

            if hasattr(self.bus, "be") and hasattr(trans, "be"):
                if isinstance(trans.be, int):
                    be = LogicArray.from_unsigned(trans.be, data_byte_len)
                elif isinstance(trans.be, LogicArray):
                    be = trans.be
                else:
                    raise TypeError(f"Unsupported type of be in MfbTransaction: {type(trans.be)}")
            else:
                be = LogicArray(0, 32)

        elif isinstance(trans, (bytes, bytearray)):
            data = LogicArray.from_bytes(trans, byteorder="little")
            if hasattr(self.bus, 'meta'):
                meta = LogicArray(0, self._meta_width)

        elif isinstance(trans, LogicArray):
            data = trans
            if hasattr(self.bus, 'meta'):
                meta = LogicArray(0, self._meta_width)
        else:
            raise TypeError(f"Unsupported type of transaction: {type(trans)}")

        self.log.debug(f"Data: (len {len(data)} bits = {len(data) // 8} bytes)\n{hex(data)}")
        self.log.debug(f"Meta: (len {len(meta)} bits)\n{hex(meta)}")
        self.log.debug(f"BE: {hex(be)}")

        # --------------------------------------------------------------------------------
        # Parse packet data into separate bus words while varying valid and
        # invalid cycles (if valid/invalid generator is not None)
        # --------------------------------------------------------------------------------
        # Bit index in the input data
        inp_data_blk_idx = 0
        pkt_finished = False

        # A next packet cannot be started in the current region when there is already a SOF OR it cannot
        # be started if it fits to the current since this would cause two EOFs to appear
        if  self._sof_int[self._last_rgn_idx] == 1 or (self._eof_int[self._last_rgn_idx] == 1 and (self._rgn_bit_width >= (self._last_blk_idx*self._blk_bit_width + len(data)))):
            self.log.debug(f"Either a SOF: {self._sof_int[self._last_rgn_idx]} or an EOF: {self._eof_int[self._last_rgn_idx]} is in the current region but the packet is too small.")
            self._last_rgn_idx = (self._last_rgn_idx + 1) % self._regions
            self._last_blk_idx = 0

            # If there is a new packet to be started in the new region but it is in the
            # next bus word, a currently prepared word need to be dispatched which is what is happening
            # in this branch
            if self._last_rgn_idx == 0:
                self._wordQ.appendleft((self._data_int, self._meta_int, self._sof_int, self._eof_int, self._sof_pos_int, self._eof_pos_int, self._src_rdy_int, self._be_int))
                self._clr_internal_bus()

        while inp_data_blk_idx*self._blk_bit_width < len(data):
            self.log.debug("==================================================================================================")
            self.log.debug(f"Initiated new word starting in {inp_data_blk_idx*self._blk_bit_width} bit of input data.")
            self.log.debug(f"(RGN, BLK) = ({self._last_rgn_idx}, {self._last_blk_idx})")

            # Iterate over regions in the MFB word
            for rgn_idx in range(self._last_rgn_idx, self._regions):
                # Iterate over blocks in every region
                for blk_idx in range(self._last_blk_idx, self._region_size):
                    self.log.debug("--------------------------------------------------------------------------------------------------")
                    self.log.debug(f"Processing (RGN, BLK) = ({rgn_idx}, {blk_idx}) and bits {inp_data_blk_idx*self._blk_bit_width}/{len(data)} of data")
                    self.log.debug(f"Valid blocks: {self.on}, invalid blocks: {self.off}")

                    self._src_rdy_int = 1

                    if (inp_data_blk_idx == 0):
                        if hasattr(self.bus, 'meta'):
                            self._meta_int[rgn_idx*self._meta_width + self._meta_width-1 : rgn_idx*self._meta_width] = meta
                        self._sof_int[rgn_idx] = 1
                        if self._sof_pos_w_pr > 0:
                            self._sof_pos_int[rgn_idx*self._sof_pos_w_pr + self._sof_pos_w_pr -1 : rgn_idx*self._sof_pos_w_pr] = blk_idx

                    # Truncate as necessary if this is a last block, otherwise keep the size of the MFB block
                    data_rest_len = len(data) - inp_data_blk_idx*self._blk_bit_width
                    data_rest_len = self._blk_bit_width if self._blk_bit_width < data_rest_len else data_rest_len
                    assert data_rest_len >= 0

                    bus_idx_low = rgn_idx*self._rgn_bit_width + blk_idx*self._blk_bit_width
                    bus_idx_high = rgn_idx*self._rgn_bit_width + blk_idx*self._blk_bit_width + data_rest_len -1
                    self.log.debug(f"Bus range to write [{bus_idx_high} : {bus_idx_low}]")
                    self.log.debug(f"Range of input data [{inp_data_blk_idx*self._blk_bit_width + data_rest_len -1} : {inp_data_blk_idx*self._blk_bit_width}]")
                    self._data_int[bus_idx_high : bus_idx_low] \
                        = data[inp_data_blk_idx*self._blk_bit_width + data_rest_len -1 : inp_data_blk_idx*self._blk_bit_width]
                    if hasattr(self.bus, 'be'):
                        self.log.debug(f"BE Bus range to write [{bus_idx_high // 8} : {bus_idx_low // 8}]")
                        self.log.debug(f"Range of input BE [{inp_data_blk_idx*self._blk_byte_width + (data_rest_len // 8) -1} : {inp_data_blk_idx*self._blk_byte_width}]")
                        self._be_int[bus_idx_high // 8 : bus_idx_low // 8] \
                            = be[inp_data_blk_idx*self._blk_byte_width + (data_rest_len // 8) -1 : inp_data_blk_idx*self._blk_byte_width]

                    inp_data_blk_idx += 1

                    if self.on is not True and self.on > 0:
                        self.on -= 1

                    if len(data) <= inp_data_blk_idx*self._blk_bit_width:
                        self._eof_int[rgn_idx] = 1
                        self._eof_pos_int[rgn_idx*self._eof_pos_w_pr + self._eof_pos_w_pr -1 : rgn_idx*self._eof_pos_w_pr] \
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

            # --------------------------------------------------------------------------------
            # Consume invalid blocks
            # --------------------------------------------------------------------------------
            # NOTE: This branch needs a thorough check for over-engineering. Some of its parts
            # can be redundant or can be rewritten.
            if no_vld_blocks:
                inv_finished = False

                while self.off > 0:

                    self.log.debug(f"--------------------------------------------------------------------")
                    self.log.debug(f"Consuming invalid blocks {self.off=}, {self._last_rgn_idx=}, {self._last_blk_idx=}")

                    # 1. If packet finishes in the word, count invalid cycles from the current word's remaining
                    # blocks
                    # 2. If packet does not finish in the word it fills it all up so the invalid blocks are counted from
                    # the next word
                    #
                    # In both cases, the last_rgn_idx and last_blk_idx point right!
                    for rgn_idx in range(self._last_rgn_idx, self._regions):
                        for blk_idx in range(self._last_blk_idx, self._region_size):
                            self.off -= 1

                            if self.off <= 0:
                                inv_finished = True
                                # If packet finished, the next packet can begin in the middle of a region after all
                                # invalid blocks have been dispatched, meaning there can be both whole invalid words but also
                                # partially invalid. Otherwise, we are still in the middle of a packet which
                                # means that only whole words can be send as invalid.
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
                    # Rationale: The problem is always, what to do with partially
                    # valid words. It packet finished in the previous word and there are no further valid blocks, the counting
                    # of invalid blocks begins there already but this word is not written to the wordQ in this branch UNLESS
                    # the packet ended in the last block of that word. Afterwards, every following word is written..
                    # The second situation is when the packet did not finish yet, yet there are no valid blocks and the next word
                    # needs to be rendered invalid which ist then written to the wordQ in this branch.
                    if (not pkt_finished) or (pkt_finished and no_space):
                        self.log.debug(f"Invalid word written to queue...")
                        self._wordQ.appendleft((self._data_int, self._meta_int, self._sof_int, self._eof_int, self._sof_pos_int, self._eof_pos_int, self._src_rdy_int, self._be_int))

                self._next_valids()
                self.log.debug(f"----------------------------------------------------------------------")

        # --------------------------------------------------------------------------------
        # Set parsed bus words from the previous cycle to the physical bus
        # --------------------------------------------------------------------------------
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

            await self._wait_ready()

        # If there are no more packets, put 0 to the output bus
        if not self._sendQ:
            await ce
            self._clr_physical_bus()

        # Check if word queue is empty
        assert not self._wordQ

        self.frame_cnt += 1
        self.log.debug(f"Transaction send finished!")
        self.log.debug("==================================================================================================")
