# test_mfb_drivers.py: unit test of the field conversion of MFBDriver
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import pytest
from cocotb.types import LogicArray

from cocotbext.ofm.mfb.drivers import _field_value, _region_value


def test_meta_bytes_are_little_endian():
    assert _field_value(b"\x01\x02", 16) == 0x0201
    assert _field_value(b"\x01", 12) == 0x001


def test_meta_int_and_logic_array():
    assert _field_value(0x5A, 8) == 0x5A
    assert _field_value(LogicArray("01X1"), 4) == "01X1"
    with pytest.raises(TypeError):
        _field_value("01", 2)


def test_meta_wider_than_its_field_is_refused():
    with pytest.raises(ValueError):
        _field_value(0x100, 8)
    with pytest.raises(ValueError):
        _field_value(LogicArray("0101"), 3)


def test_region_fields_flatten_low_region_first():
    assert _region_value([1, 2], 4, "XXXX") == 0x21
    assert _region_value([None, 2], 4, "XXXX") == "0010XXXX"
    assert _region_value(["01X1", 3], 4, "XXXX") == "001101X1"
