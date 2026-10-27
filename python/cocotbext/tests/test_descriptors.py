# test_descriptors.py: unit test of the signal resolution of the bus protocols
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

from cocotbext.ofm.base.protocol import BusProtocol, signal

from stubs import StubSignal


class OneSignalProtocol(BusProtocol):
    DATA = signal()


class Entity:
    """A DUT stand-in, e.g. the view of one endpoint, whose RX_DATA is its own."""

    def __init__(self):
        self.RX_DATA = StubSignal(8)


class Unhashable(Entity):
    __hash__ = None


def test_buses_of_one_name_on_two_duts_resolve_their_own_signals():
    first, second = Entity(), Entity()
    descriptor = OneSignalProtocol.__dict__["DATA"]

    assert descriptor.target(OneSignalProtocol(first, "RX")) is first.RX_DATA
    assert descriptor.target(OneSignalProtocol(second, "RX")) is second.RX_DATA


def test_an_unhashable_dut_resolves_too():
    dut = Unhashable()

    assert OneSignalProtocol.__dict__["DATA"].target(OneSignalProtocol(dut, "RX")) is dut.RX_DATA
