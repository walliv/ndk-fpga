# test_throughput_probe.py: unit test of the AXI interface of the throughput probe on a stub slave
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import asyncio

import pytest

from cocotbext.ofm.utils.throughput_probe import ThroughputProbeAxiInterface


class Slave:
    """The parts of a cocotbext-axi slave that the probe interface touches."""
    clock = None
    byte_lanes = 8
    byte_size = 8

    def __init__(self):
        self.written = []
        self.read_requests = []
        self._reset_state = False

    async def _write(self, address, data):
        self.written.append((address, data))

    async def _read(self, address, length):
        self.read_requests.append((address, length))
        return bytes(length)


class WriteSlave:
    clock = None
    byte_lanes = 4
    byte_size = 8

    async def _write(self, address, data):
        pass


class ReadSlave:
    clock = None
    byte_lanes = 4
    byte_size = 8

    async def _read(self, address, length):
        return bytes(length)


def test_write_counts_the_enabled_bytes_and_still_writes():
    slave = Slave()
    probe = ThroughputProbeAxiInterface(slave, "write")

    asyncio.run(slave._write(0x100, b"abc"))
    asyncio.run(slave._write(0x200, b"de"))

    assert probe.item_cnt == 5
    assert slave.written == [(0x100, b"abc"), (0x200, b"de")]


def test_read_counts_the_requested_bytes_and_still_reads():
    slave = Slave()
    probe = ThroughputProbeAxiInterface(slave, "read")

    assert asyncio.run(slave._read(0x40, 8)) == bytes(8)
    asyncio.run(slave._read(0x48, 8))

    assert probe.item_cnt == 16
    assert slave.read_requests == [(0x40, 8), (0x48, 8)]


@pytest.mark.parametrize("slave, direction", [(Slave(), "write"), (Slave(), "read")])
def test_only_the_chosen_direction_is_counted(slave, direction):
    probe = ThroughputProbeAxiInterface(slave, direction)
    asyncio.run(slave._write(0, b"xy"))
    asyncio.run(slave._read(0, 4))

    assert probe.item_cnt == (2 if direction == "write" else 4)


def test_direction_is_inferred_from_the_access_hook():
    writer, reader = WriteSlave(), ReadSlave()
    write_probe, read_probe = ThroughputProbeAxiInterface(writer), ThroughputProbeAxiInterface(reader)

    asyncio.run(writer._write(0, b"xyz"))
    asyncio.run(reader._read(0, 4))

    assert (write_probe.item_cnt, read_probe.item_cnt) == (3, 4)


def test_items_are_the_byte_lanes_of_the_slave():
    probe = ThroughputProbeAxiInterface(Slave(), "write")
    assert (probe.items, probe.item_width) == (8, 8)


def test_in_reset_follows_the_slave_reset_state():
    slave = Slave()
    probe = ThroughputProbeAxiInterface(slave, "write")
    assert not probe.in_reset

    slave._reset_state = True
    assert probe.in_reset


def test_unknown_direction_is_rejected():
    with pytest.raises(ValueError):
        ThroughputProbeAxiInterface(Slave(), "both")
