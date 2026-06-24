# c2h_hbm_reader_reg_access.py: pynfb control API for the C2H HBM reader
# Copyright 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

from dataclasses import dataclass, fields
import time

import nfb
from cocotbext.ofm.dma.hyperion import C2HReaderMIRegMap, C2HC2HCtrlRegBits, C2HC2HStatRegBits


@dataclass
class C2HReaderStats:
    busy        : bool
    done        : bool
    error       : bool
    range_err   : bool
    req_cnt     : int
    req_bytes   : int

    def __str__(self) -> str:
        items = [(f.name, getattr(self, f.name)) for f in fields(self)]

        max_len = max(len(name) for name, _ in items) if items else 0
        res = []

        for name, val in items:
            res.append(f"{name:<{max_len}} : {val}")

        return "\n".join(res)


class C2HHBMReaderRegAccess(nfb.BaseComp):
    DT_COMPATIBLE = "ziti,sparklev,c2h_hbm_reader"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)

    def start(self) -> None:
        self._comp.write32(C2HReaderMIRegMap.CTRL.value, 1 << C2HCtrlRegBits.START.value)

    def clear_done(self) -> None:
        self._comp.write32(C2HReaderMIRegMap.CTRL.value, 1 << C2HCtrlRegBits.CLEAR_DONE.value)

    @property
    def hbm_addr(self) -> int:
        return self._comp.read64(C2HReaderMIRegMap.ADDR_L.value)

    @hbm_addr.setter
    def hbm_addr(self, value: int) -> None:
        self._comp.write64(C2HReaderMIRegMap.ADDR_L.value, value)

    @property
    def size(self) -> int:
        return self._comp.read64(C2HReaderMIRegMap.SIZE_L.value)

    @size.setter
    def size(self, value: int) -> None:
        self._comp.write64(C2HReaderMIRegMap.SIZE_L.value, value)

    @property
    def busy(self) -> bool:
        return self._comp.get_bit(C2HReaderMIRegMap.STATUS.value, C2HStatRegBits.BUSY.value, width=32)

    @property
    def done(self) -> bool:
        return self._comp.get_bit(C2HReaderMIRegMap.STATUS.value, C2HStatRegBits.DONE.value, width=32)

    @property
    def error(self) -> bool:
        return self._comp.get_bit(C2HReaderMIRegMap.STATUS.value, C2HStatRegBits.ERROR.value, width=32)

    @property
    def range_err(self) -> bool:
        return self._comp.get_bit(C2HReaderMIRegMap.STATUS.value, C2HStatRegBits.RANGE_ERR.value, width=32)

    @property
    def req_cnt(self) -> int:
        return self._comp.read64(C2HReaderMIRegMap.REQ_CNT_L.value)

    @property
    def req_bytes(self) -> int:
        return self._comp.read64(C2HReaderMIRegMap.REQ_BYTES_L.value)

    def get_statistics(self) -> C2HReaderStats:
        """Returns a snapshot of all hardware status and counter fields."""
        stats_kwargs = {}
        for f in fields(C2HReaderStats):
            stats_kwargs[f.name] = getattr(self, f.name)

        return C2HReaderStats(**stats_kwargs)

    def read(self, hbm_addr: int, size: int, timeout: float = 5.0) -> None:
        """Blocking helper: programs and starts a C2H HBM read, waits for completion.

        Raises RuntimeError if the request is out of range, if the hardware
        reports an AXI error, or if the operation does not complete within
        *timeout* seconds.
        """
        self.clear_done()
        self.hbm_addr = hbm_addr
        self.size = size
        self.start()

        # An invalid request is rejected immediately and DONE never sets, so
        # check range_err first before waiting on DONE.
        if self.range_err:
            raise RuntimeError(
                f"C2H read rejected: addr=0x{hbm_addr:x} size={size} out of range"
            )

        self._comp.wait_for_bit(
            C2HReaderMIRegMap.STATUS.value,
            C2HStatRegBits.DONE.value,
            timeout=timeout,
            width=32,
        )

        if self.error:
            raise RuntimeError(
                f"C2H read failed with AXI error: addr=0x{hbm_addr:x} size={size}"
            )
