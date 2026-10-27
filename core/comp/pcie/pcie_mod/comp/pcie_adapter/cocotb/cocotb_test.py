# cocotb_test.py: PCIE_ADAPTER on the CQ interface of an AMD PCIe IP
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

"""CQ TLPs go in as AXI beats and come out of the adapter as MFB frames with the PCIE_CQ_META of the region where
they start. The layout follows the generics of the DUT.
"""

import cocotb

from cocotbext.ofm.axi4s_pcie.usp import cq_layout, random_cq_tlps, run_cq_test
from cocotbext.ofm.mfb.monitors import MFBMonitor
from cocotbext.ofm.mfb.transaction import MfbTransactionWithMeta
from cocotbext.ofm.utils.signals import generic_bool


def layout_of(dut):
    return cq_layout(int(dut.MFB_REGIONS.value), generic_bool(dut.AXI_STRADDLING))


async def run(dut, make_tlps, p_low):
    monitor = MFBMonitor(dut, "CQ_MFB", dut.CLK, trans_type=MfbTransactionWithMeta)
    await run_cq_test(dut, layout_of(dut), make_tlps, p_low, monitor)


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def cq_random_tlps(dut, tlps=3000):
    """Random reads and writes of 1 to 64 Dwords, random gaps between TLPs and random backpressure."""
    await run(dut, random_cq_tlps(tlps), p_low=0.3)


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def cq_short_tlps(dut, tlps=3000):
    """Descriptors and writes of up to 4 Dwords, so that straddling packs two TLPs into most beats."""
    await run(dut, random_cq_tlps(tlps, max_payload_dw=4, p_read=0.5), p_low=0.2)
