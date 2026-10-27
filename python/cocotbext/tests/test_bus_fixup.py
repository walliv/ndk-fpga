# test_bus_fixup.py: unit test of the bit writes of the cocotb 2 signal proxies
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

from cocotb.types import LogicArray

from cocotbext.ofm.base import bus_fixup


class Vector:
    """A vector whose immediate writes read back only from the next timestep on, as a VHDL signal can."""

    def __init__(self, bits):
        self._path = "dut.VEC"
        self.committed = LogicArray(bits)
        self.written = None

    @property
    def value(self):
        return LogicArray(str(self.committed))

    def set(self, action):
        self.written = LogicArray(str(action.value))

    def next_timestep(self):
        self.committed = self.written


def test_bits_written_in_one_timestep_accumulate(monkeypatch):
    now = [100]
    monkeypatch.setattr(bus_fixup, "get_sim_time", lambda: now[0])
    vec = Vector("UU")

    bus_fixup._write_bit(vec, 0, 1)
    bus_fixup._write_bit(vec, 1, 0)
    assert str(vec.written) == "01"

    vec.next_timestep()
    now[0] = 104
    bus_fixup._write_bit(vec, 1, 1)
    assert str(vec.written) == "11"


def test_a_later_timestep_starts_from_the_vector(monkeypatch):
    now = [8]
    monkeypatch.setattr(bus_fixup, "get_sim_time", lambda: now[0])
    vec = Vector("00")
    bus_fixup._write_bit(vec, 0, 1)
    vec.next_timestep()

    # another writer changed bit 1 since
    vec.committed = LogicArray("11")
    now[0] = 12
    bus_fixup._write_bit(vec, 0, 0)
    assert str(vec.written) == "10"
