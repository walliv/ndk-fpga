# op_stat_monitor.py: Monitor for operation status signals of the DMA Iuventus DUT
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import logging
from cocotb.triggers import RisingEdge, ReadOnly
from cocotb_bus.monitors import BusMonitor

class OpStatMonitor(BusMonitor):
    _signals = ["type", "code", "vld"]

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.ops_processed = 0

    async def _monitor_recv(self):
        re = RisingEdge(self.clock)

        while True:
            await re
            await ReadOnly()
            if bool(self.bus.vld.value):
                if self.log.isEnabledFor(logging.INFO):
                    self.log.info(f"Received operation status: {self.bus.type.value=}, {self.bus.code.value=}")
                rd = bool(self.bus.type.value)
                self._recv((rd, int(self.bus.code.value)))
                self.ops_processed += 1
