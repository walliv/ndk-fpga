# test_axi4s_pcie.py: unit test of the CQ beats of the AXI4-Stream PCIe driver
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import pytest

from cocotbext.ofm.axi4s_pcie.drivers import Axi4sPcieDriverMaster
from cocotbext.ofm.pcie.PcieHeaders import CQHeader, CQUser

BUS_WIDTH = 512


def cq_beats(payload_bytes):
    """TUSER and tkeep of the beats of a CQ write with ``payload_bytes`` bytes of payload."""
    hdr = CQHeader()
    hdr.req_type = 1
    hdr.dword_count = (payload_bytes + 3) // 4
    user = CQUser()
    user.sop0 = 1
    data = bytes(i % 256 for i in range(payload_bytes))
    # Packing the beats does not use the bus, so no driver instance is needed
    words = Axi4sPcieDriverMaster._prep_cq_words(None, hdr, data, user, BUS_WIDTH)
    return [(CQUser.deserialize(w["USER"]), w["KEEP"]) for w in words]


@pytest.mark.parametrize("payload_bytes", [4, 48, 52, 100, 240, 1024])
def test_cq_eop_ptr_points_to_the_last_dword_of_the_tlp(payload_bytes):
    *body, (last, last_keep) = cq_beats(payload_bytes)

    assert last.eop0 == 1
    assert last.eop_ptr0 == last_keep.bit_length() - 1
    assert all(user.eop0 == 0 and user.eop_ptr0 == 0 for user, _ in body)
