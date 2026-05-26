# read_req_driver.py: Driver for read requests to the DMA Iuventus DUT
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

from cocotb.triggers import RisingEdge, ReadOnly
from cocotb_bus.drivers import ValidatedBusDriver
from cocotbext.ofm.mfb.utils import random_tuple_iterator

class ReadReqDriver(ValidatedBusDriver):
    _signals = ["lba_num", "lba_ptr", "vld" ,"rdy"]

    def __init__(self, entity, name, clock, vld_gen=random_tuple_iterator(1, 20, 1, 20), **kwargs):
        super().__init__(entity, name, clock, valid_generator=vld_gen, **kwargs)

        self.clock = clock
        self.bus.lba_num.value = 0
        self.bus.lba_ptr.value = 0
        self.bus.vld.value = 0
        self.frame_cnt = 0

    async def _driver_send(self, transaction, sync=True):
        """Send a transmission over the bus.

        Args:
            transaction: tuple containing the data for one clock cycle of a bus
        """
        lba_num, lba_ptr= transaction
        self.log.info(f"Sending Read request: {lba_num=}, {lba_ptr=}")

        # Avoid spurious object creation by recycling
        clkedge = RisingEdge(self.clock)

        # Drive some defaults since we don't know what state we're in
        # self.bus.vld.value = 0

        await clkedge

        # Insert a gap where valid is low
        if not self.on:
            self.bus.vld.value = 0
            for _ in range(self.off):
                await clkedge

            # Grab the next set of on/off values
            self._next_valids()

        # Consume a valid cycle
        if self.on is not True and self.on:
            self.on -= 1

        self.bus.lba_num.value = lba_num - 1 # NVMe uses 0-based values
        self.bus.lba_ptr.value = lba_ptr
        self.bus.vld.value = 1

        await ReadOnly()
        while not bool(self.bus.rdy.value):
            await clkedge
            await ReadOnly()

        if not self._sendQ:
            await clkedge
            self.bus.lba_num.value = 0
            self.bus.lba_ptr.value = 0
            self.bus.vld.value = 0

        self.log.debug(f"Successfully sent the read request: {lba_num=}, {lba_ptr=}")
        self.frame_cnt += 1

    def reset(self):
        self.bus.lba_num.value = 0
        self.bus.lba_ptr.value = 0
        self.bus.vld.value = 0
