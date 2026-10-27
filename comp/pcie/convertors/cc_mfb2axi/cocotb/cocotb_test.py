# cocotb_test.py: PCIE_CC_MFB2AXI on the 256-bit and 512-bit CC interfaces with and without straddling
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

"""MFB frames go in and the AXI monitor rebuilds the TLPs from the beats, which it also checks against the rules of the
IP: start and end of a TLP, no gap inside it and the reserved values. The layout follows the generics of the DUT.
"""

import cocotb

from cocotbext.ofm.axi4s_pcie.usp import cc_layout, random_cc_frames, run_cc_test
from cocotbext.ofm.utils.signals import generic_bool


def layout_of(dut):
    return cc_layout(int(dut.MFB_REGIONS.value), generic_bool(dut.STRADDLING))


async def run(dut, make_frames, p_low):
    await run_cc_test(dut, layout_of(dut), make_frames, p_low)


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def random_frames(dut, frames=3000):
    """Completions of 0 to 64 Dwords of payload with random backpressure."""
    await run(dut, random_cc_frames(frames), p_low=0.3)


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def short_frames(dut, frames=3000):
    """Completions of up to 8 Dwords in total, so that a word of the straddled interface often holds two."""
    await run(dut, random_cc_frames(frames, max_payload_dw=2, p_no_payload=0.5), p_low=0.2)


@cocotb.test(timeout_time=5, timeout_unit="ms")
async def long_frames(dut, frames=300):
    """Completions of up to 256 Dwords of payload."""
    await run(dut, random_cc_frames(frames, max_payload_dw=256, p_no_payload=0.1), p_low=0.5)
