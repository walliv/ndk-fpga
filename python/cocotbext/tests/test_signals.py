# test_signals.py: unit test of the byte and byte-enable helpers in utils/signals.py
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import pytest
from cocotb.types import LogicArray

from cocotbext.ofm.utils.signals import (align_read_request, align_request, align_write_request,
                                         binstr_bit, binstr_resolvable, binstr_resolved, generic_bool,
                                         get_signal_value_in_bytes, signal_binstr, signal_int)
from stubs import StubSignal


def test_signal_is_read_as_the_bit_string_of_the_simulator():
    sig = StubSignal(8)
    sig.binstr = "00101101"

    assert signal_binstr(sig) == "00101101"
    assert signal_int(sig) == 0x2D
    sig.binstr = "0010X101"
    with pytest.raises(ValueError):
        signal_int(sig)


def test_bit_string_predicates():
    assert binstr_bit("0110", 1) and binstr_bit("0110", 2) and not binstr_bit("0110", 0)
    assert binstr_resolvable("01LH") and not binstr_resolvable("0X1")
    assert binstr_resolved("0110") and not binstr_resolved("01H0")


@pytest.mark.parametrize("value, expected", [("TRUE", True), ("false", False), (1, True), (0, False)])
def test_generic_bool_takes_a_name_or_a_number(value, expected):
    assert generic_bool(StubSignal(1, value)) is expected


def test_signal_value_is_little_endian_by_default():
    sig = StubSignal(16, LogicArray.from_unsigned(0x0102, 16))
    assert get_signal_value_in_bytes(sig) == b"\x02\x01"
    assert get_signal_value_in_bytes(sig, big_endian=True) == b"\x01\x02"


@pytest.mark.parametrize("bus_width, addr, data_len, byte_enable", [
    (4, 0, 4, 0b1111),
    (4, 1, 2, 0b01),
    (4, 3, 6, 0b101101),
    (8, 5, 3, 0b110),
    (8, 13, 20, 0xA5A5A),
])
def test_aligned_byte_enable_bit_i_enables_byte_i(bus_width, addr, data_len, byte_enable):
    start, end, aligned_addr, aligned_be = align_request(
        bus_width, addr, data_len, byte_enable=LogicArray.from_unsigned(byte_enable, data_len))

    assert start == addr % bus_width and aligned_addr == addr - start
    assert (start + data_len + end) % bus_width == 0
    assert aligned_be.to_unsigned() == byte_enable << start


def test_aligned_request_without_byte_enable():
    assert align_request(4, 6, 3) == (2, 3, 4, None)


def test_write_request_is_padded_to_whole_words():
    start, end, addr, data, be = align_write_request(4, 6, b"\xaa\xbb\xcc", byte_enable=LogicArray.from_unsigned(0b101, 3))

    assert (start, end, addr) == (2, 3, 4)
    assert data == b"\x00\x00\xaa\xbb\xcc\x00\x00\x00"
    assert be.to_unsigned() == 0b10100


def test_read_request_counts_the_padding():
    start, end, addr, byte_count, be = align_read_request(4, 6, 3, byte_enable=LogicArray.from_unsigned(0b011, 3))

    assert (start, end, addr, byte_count) == (2, 3, 4, 8)
    assert be.to_unsigned() == 0b01100
