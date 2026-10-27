# signals.py: Cocotbext signal utilities
# Copyright (C) 2025-2026 CESNET z. s. p. o.
# Author(s): Ondřej Schwarz <ondrejschwarz@cesnet.cz>
#
# SPDX-License-Identifier: BSD-3-Clause

from cocotb.types import LogicArray
from typing import Optional, Any
from cocotb.triggers import RisingEdge, FallingEdge
from cocotb.clock import Clock


async def await_signal_sync(clk_re: RisingEdge, signal, value: int = 1) -> None:
    """
    Synchronously waits until the value of the passed signal becomes passed value.

    Note:
        If the value of the signal is already set to passed value, function returns immediately.

    Args:
        signal: signal that is to be awaited, must be signal from the cocotb.bus class.
        value: value that is to be awaited.
        clk_re: RisingEdge object.
    """
    while signal.value != value:
        await clk_re


def signal_binstr(handle) -> str:
    """A signal's value as the simulator's MSB-first bit string, which avoids building a Logic or
    LogicArray per read. Takes a plain cocotb handle, not a proxy created for an array_idx."""
    return handle._handle.get_signal_val_binstr()


def signal_int(handle) -> int:
    """A signal's unsigned value read through signal_binstr; raises ValueError on a bit that is not 0 or 1."""
    return int(signal_binstr(handle), 2)


def signal_handshake(src_rdy, dst_rdy) -> bool:
    """True when both handshake signals, read through signal_binstr, are 1: the word on the bus is transferred."""
    return signal_binstr(src_rdy) == "1" and signal_binstr(dst_rdy) == "1"


def binstr_resolvable(binstr: str) -> bool:
    """cocotb's is_resolvable on a bit string: every bit a 0, 1, L or H."""
    return not binstr.strip("01LH")


def binstr_resolved(binstr: str) -> bool:
    """True when a bit string holds only 0s and 1s."""
    return not (set(binstr) - {"0", "1"})


def binstr_bit(binstr: str, idx: int) -> bool:
    """True when bit `idx`, counted from the LSB, of an MSB-first bit string is a 1."""
    return binstr[len(binstr) - 1 - idx] == "1"


def generic_bool(handle) -> bool:
    """Value of a boolean generic, which a simulator hands over as a number or as a name."""
    value = handle.value
    return value.lower() == "true" if isinstance(value, str) else bool(int(value))


def get_signal_value_in_bytes(signal, big_endian: bool = False) -> bytes:
    """
    Get value of a OUT signals in bytes.

    Args:
        signal: cocotb.bus signal that is to be read.
        big_endian: using which endian are the data to be interpreted (little endian by default)

    Returns:
        Signal value in bytes.
    """
    return signal.value.to_bytes(byteorder='big' if big_endian else 'little')


def filter_bytes_by_bitmask(data: bytes, byte_enable: int) -> bytes:
    """
    Filters the input bytes by a given bitmask.

    Parameters:
    data (bytes): The input bytes to filter.
    byte_enable (int): An integer used as a bitmask to determine which bytes to include
                  in the output. Each bit in the mask corresponds to an index in
                  the data; if a bit is set to 1, the corresponding byte is included
                  in the result.

    Returns:
    bytes: A new bytes object consisting of elements from the input based on
           the bitmask. Only bytes at positions where the corresponding bit in
           'enable' is set to 1 are included.

    Example:
    >>> filter_bytes_by_bitmask(b'hello', 0b10101)
    b'hlo'
    """
    return bytes([x for i, x in enumerate(data) if (1 << i) & byte_enable])


def align_request(bus_width: int, addr: int, data_len: int, *, byte_enable: Optional[LogicArray] = None) -> (int, int, int, Optional[LogicArray]):
    """
    Aligns address and byte enable of a continuous request based on the bus width.

    Args:
        bus_width: width of the used bus in bytes.
        addr: unaligned address of the first byte.
        data_len: lenght of the data to be written or number of bytes to be read.
        byte_enable: which bytes of the data are valid, bit i enables byte i.

    Returns:
        tuple of four elements:
        [0] index of first valid byte within bus word,
        [1] index of last valid byte within bus word,
        [2] aligned address of the first word (value is multiple of bus_width),
        [3] aligned byte enable
    """
    start_offset = addr % bus_width
    end_offset = -(addr + data_len) % bus_width

    byte_enable = LogicArray(("0" * end_offset) + str(byte_enable) + ("0" * start_offset)) if byte_enable is not None else None
    addr = addr - start_offset

    return start_offset, end_offset, addr, byte_enable


def align_write_request(bus_width: int, addr: int, data: bytes, *, byte_enable: Optional[LogicArray] = None) -> (int, int, int, int, Optional[LogicArray]):
    """
    Aligns data, address and byte enable of a continuous write request based on the bus width.

    Args:
        bus_width: width of the used bus in bytes.
        addr: unaligned address of the first written byte.
        data: data to be written.
        byte_enable: which bytes of the data are valid.

    Returns:
        tuple of five elements:
        [0] index of first valid byte within bus word,
        [1] index of last valid byte within bus word,
        [2] aligned address of the first word (value is multiple of bus_width),
        [3] aligned data,
        [4] aligned byte enable
    """
    start_offset, end_offset, addr, byte_enable = align_request(bus_width, addr, len(data), byte_enable=byte_enable)

    data = bytes(start_offset) + data + bytes(end_offset)
    return start_offset, end_offset, addr, data, byte_enable


def align_read_request(bus_width: int, addr: int, byte_count: int, *, byte_enable: Optional[LogicArray] = None) -> (int, int, int, int, Optional[LogicArray]):
    """
    Aligns address and byte enable of a continuous read request based on the bus width.

    Args:
        bus_width: width of the used bus in bytes.
        addr: unaligned address of the first read byte.
        byte_count: number of bytes to be read.
        byte_enable: which bytes of the data are valid.

    Returns:
        tuple of five elements:
        [0] index of first valid byte within bus word,
        [1] index of last valid byte within bus word,
        [2] aligned address of the first word (value is multiple of bus_width),
        [3] byte count including the start/end padding,
        [4] aligned byte enable
    """
    start_offset, end_offset, addr, byte_enable = align_request(bus_width, addr, byte_count, byte_enable=byte_enable)

    byte_count += start_offset + end_offset
    return start_offset, end_offset, addr, byte_count, byte_enable


async def wait_number_of_cycles(clk: RisingEdge | FallingEdge | Clock, cycles: int) -> None:
    if isinstance(Clock):
        clk_re = RisingEdge(clk)
    elif isinstance(RisingEdge) or isinstance(FallingEdge):
        clk_re = clk
    else:
        raise TypeError("Invalid type passed to clk arg.")

    for _ in range(cycles):
        await clk_re


async def set_signal_delayed(clk: RisingEdge | FallingEdge | Clock, signal, cycles: int, value: Any) -> None:
    await wait_number_of_cycles(clk, cycles)
    signal.value = value
