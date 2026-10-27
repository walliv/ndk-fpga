# cocotb_test.py: PCIE_CQ_AXI2MFB on the 256-bit and 512-bit CQ interfaces with and without straddling
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

"""CQ TLPs go in as AXI beats, MFB frames and the sideband outputs of their first region come out. The model of
every TLP is its Dwords and the PCIE_CQ_META of the region where it starts. The layout follows the generics of the DUT.
"""

import cocotb

from cocotbext.ofm.axi4s_pcie.usp import cq_layout, random_cq_tlps, run_cq_test
from cocotbext.ofm.mfb.monitors import MFBMonitor
from cocotbext.ofm.mfb.transaction import MfbTransactionWithMeta
from cocotbext.ofm.pcie.PcieHeaders import CQMfbMeta
from cocotbext.ofm.utils.signals import generic_bool


class SidebandMfbMonitor(MFBMonitor):
    """MFB monitor that adds the CQ sideband outputs of the region where a frame starts to the frame as meta."""

    def __init__(self, *args, dut, **kwargs):
        super().__init__(*args, **kwargs)
        self.dut = dut
        self._metas = []

    def _read_control_signals(self):
        super()._read_control_signals()
        d = self.dut
        for r in range(self._regions):
            if self._sof[r]:
                meta = CQMfbMeta()
                meta.firstBe = int(d.CQ_FBE.value) >> (4 * r) & 0xF
                meta.lastBe = int(d.CQ_LBE.value) >> (4 * r) & 0xF
                meta.tph_present = int(d.CQ_TPH_PRESENT.value) >> r & 1
                meta.tph_type = int(d.CQ_TPH_TYPE.value) >> (2 * r) & 3
                meta.tph_st_tag = int(d.CQ_TPH_ST_TAG.value) >> (8 * r) & 0xFF
                meta.be = int(d.CQ_BE.value) >> (32 * r) & 0xFFFFFFFF
                self._metas.append(meta.serialize())

    def _recv_trans(self):
        self._transaction.meta = self._metas.pop(0)
        super()._recv_trans()


def layout_of(dut):
    return cq_layout(int(dut.MFB_REGIONS.value), generic_bool(dut.STRADDLING), int(dut.AXI_CQUSER_WIDTH.value))


async def run(dut, make_tlps, p_low):
    monitor = SidebandMfbMonitor(dut, "CQ_MFB", dut.CLK, dut=dut, trans_type=MfbTransactionWithMeta)
    await run_cq_test(dut, layout_of(dut), make_tlps, p_low, monitor)


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def random_tlps(dut, tlps=3000):
    """Random reads and writes of 1 to 64 Dwords, random gaps between TLPs and random backpressure."""
    await run(dut, random_cq_tlps(tlps), p_low=0.3)


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def short_tlps(dut, tlps=3000):
    """Descriptors and writes of up to 4 Dwords, so that straddling packs two TLPs into most beats."""
    await run(dut, random_cq_tlps(tlps, max_payload_dw=4, p_read=0.5), p_low=0.2)


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def long_tlps(dut, tlps=300):
    """Writes of up to 256 Dwords, the TLPs span many beats."""
    await run(dut, random_cq_tlps(tlps, max_payload_dw=256, p_read=0.1), p_low=0.5)
