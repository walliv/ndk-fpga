# Copyright 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import ctypes
import os
from dataclasses import dataclass, fields

import nfb
from cocotbext.ofm.dma.hyperion import H2CHyperionMIRegMap, CtrlRegBits, StatRegBits


def _fdt_u64(dev, node_path, prop):
    data = dev.fdt.get_node(node_path).get_property(prop).data
    acc = 0
    for w in data:
        acc = (acc << 32) | (w & 0xffffffff)
    return acc


@dataclass
class H2CHyperionStats:
    status_reg          : int
    pcie_block          : bool
    hbm_w_block         : bool
    hbm_aw_block        : bool
    pcie_wr_reqs        : int
    pcie_wr_req_bytes   : int
    pcie_rd_reqs        : int
    pcie_rd_req_bytes   : int
    hbm_wr_trs          : int
    hbm_wr_bytes        : int
    pcie_mfb_block      : int
    hbm_w_block_cnt     : int
    hbm_aw_block_cnt    : int
    pcie_drops          : int
    pcie_drop_bytes     : int

    def __str__(self) -> str:
        items = [(f.name, getattr(self, f.name)) for f in fields(self)]

        max_len = max(len(name) for name, _ in items) if items else 0
        res = []

        for name, val in items:
            res.append(f"{name:<{max_len}} : {val}")

        return "\n".join(res)


class H2CDMAHyperionRegAccess(nfb.BaseComp):
    DT_COMPATIBLE = "ziti,sparklev,h2c_dma_hyperion"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)

    def sample_cntrs(self) -> None:
        self._comp.set_bit(H2CHyperionMIRegMap.CONTROL.value, CtrlRegBits.SAMPLE_CNTRS.value, width=8)

    def rst_cntrs(self) -> None:
        self._comp.set_bit(H2CHyperionMIRegMap.CONTROL.value, CtrlRegBits.RST_CNTRS.value, width=8)

    @property
    def status_reg(self) -> int:
        return self._comp.read8(H2CHyperionMIRegMap.STATUS.value)

    @property
    def pcie_block(self) -> bool:
        return self._comp.get_bit(H2CHyperionMIRegMap.STATUS.value, StatRegBits.PCIE_BLOCK.value, width=8)

    @property
    def hbm_w_block(self) -> bool:
        return self._comp.get_bit(H2CHyperionMIRegMap.STATUS.value, StatRegBits.HBM_W_BLOCK.value, width=8)

    @property
    def hbm_aw_block(self) -> bool:
        return self._comp.get_bit(H2CHyperionMIRegMap.STATUS.value, StatRegBits.HBM_AW_BLOCK.value, width=8)

    @property
    def pcie_wr_reqs(self) -> int:
        return self._comp.read64(H2CHyperionMIRegMap.PCIE_WR_REQS_CNTR_L.value)

    @property
    def pcie_wr_req_bytes(self) -> int:
        return self._comp.read64(H2CHyperionMIRegMap.PCIE_WR_REQ_BYTES_CNTR_L.value)

    @property
    def pcie_rd_reqs(self) -> int:
        return self._comp.read64(H2CHyperionMIRegMap.PCIE_RD_REQS_CNTR_L.value)

    @property
    def pcie_rd_req_bytes(self) -> int:
        return self._comp.read64(H2CHyperionMIRegMap.PCIE_RD_REQ_BYTES_CNTR_L.value)

    @property
    def hbm_wr_trs(self) -> int:
        return self._comp.read64(H2CHyperionMIRegMap.HBM_WR_TRS_CNTR_L.value)

    @property
    def hbm_wr_bytes(self) -> int:
        return self._comp.read64(H2CHyperionMIRegMap.HBM_WR_BYTES_CNTR_L.value)

    @property
    def pcie_mfb_block(self) -> int:
        return self._comp.read64(H2CHyperionMIRegMap.PCIE_MFB_BLOCK_CNTR_L.value)

    @property
    def hbm_w_block_cnt(self) -> int:
        return self._comp.read64(H2CHyperionMIRegMap.HBM_W_BLOCK_CNTR_L.value)

    @property
    def hbm_aw_block_cnt(self) -> int:
        return self._comp.read64(H2CHyperionMIRegMap.HBM_AW_BLOCK_CNTR_L.value)

    @property
    def pcie_drops(self) -> int:
        return self._comp.read64(H2CHyperionMIRegMap.PCIE_DROP_CNTR_L.value)

    @property
    def pcie_drop_bytes(self) -> int:
        return self._comp.read64(H2CHyperionMIRegMap.PCIE_DROP_BYTES_CNTR_L.value)

    def get_statistics(self) -> H2CHyperionStats:
        """Returns a snapshot of all hardware statistics counters."""
        self.sample_cntrs()

        stats_kwargs = {}
        for f in fields(H2CHyperionStats):
            stats_kwargs[f.name] = getattr(self, f.name)

        return H2CHyperionStats(**stats_kwargs)


class HBMWriteWindow:
    """Write-only view of one H2C DMA Hyperion HBM channel window (0.5 GB), via a
    direct mmap of the prefetchable BAR2 region. (comp_open cannot map the 16 GB BAR2,
    so this bypasses it.) `index` selects the 0.5 GB window; write() offsets are within it."""
    DT_COMPATIBLE = "ziti,sparklev,h2c_dma_hyperion_buffer"
    CHAN_SIZE = 1 << 29  # 0.5 GB

    def __init__(self, dev, index: int = 0, device_path=None):
        self._dev = dev
        if device_path is None:
            device_path = nfb.libnfb.Nfb.default_dev_path
        self._index = index
        self._hbm_base = index * self.CHAN_SIZE
        self._bar2_base = _fdt_u64(dev, "/drivers/mi/PCI0,BAR2", "mmap_base")
        self._fd = os.open(device_path, os.O_RDWR)
        self._libc = ctypes.CDLL("libc.so.6", use_errno=True)
        self._libc.mmap.restype = ctypes.c_void_p
        self._libc.mmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int,
                                    ctypes.c_int, ctypes.c_int, ctypes.c_long]
        self._libc.munmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t]

    def write(self, offset: int, data: bytes) -> None:
        assert 0 <= offset and offset + len(data) <= self.CHAN_SIZE, "write exceeds 0.5 GB window"
        off = self._bar2_base + self._hbm_base + offset
        page = off & ~0xFFF
        delta = off - page
        maplen = (delta + len(data) + 0xFFF) & ~0xFFF
        p = self._libc.mmap(None, maplen, 0x1 | 0x2, 0x1, self._fd, page)  # PROT_READ|WRITE, MAP_SHARED
        if p in (None, (1 << 64) - 1):
            raise OSError(ctypes.get_errno(), os.strerror(ctypes.get_errno()))
        try:
            ctypes.memmove(p + delta, data, len(data))
        finally:
            self._libc.munmap(ctypes.c_void_p(p), maplen)

    def close(self) -> None:
        if getattr(self, "_fd", None) is not None:
            os.close(self._fd)
            self._fd = None

    def __del__(self):
        try:
            self.close()
        except Exception:
            pass
