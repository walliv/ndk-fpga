# test_mfb_fast_drivers.py: unit test of the META conversion of the fast MFBDriver
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import pytest
from cocotb.types import LogicArray

from cocotbext.ofm.mfb.fast_drivers import meta_logic


def test_meta_bytes_are_little_endian():
    assert meta_logic(b"\x01\x02", 16).to_unsigned() == 0x0201
    assert meta_logic(b"\x01", 12) == LogicArray.from_unsigned(0x001, 12)


def test_meta_int_and_logic_array():
    assert meta_logic(0x5A, 8) == LogicArray.from_unsigned(0x5A, 8)
    assert meta_logic(LogicArray("0101"), 4) == LogicArray("0101")
    with pytest.raises(TypeError):
        meta_logic("01", 2)
