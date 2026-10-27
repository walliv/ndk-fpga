# test_generators.py: unit test of the idle generators
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

from cocotbext.ofm.base.generators import IdleGenerator, ItemRateLimiter, OnOffIdleGenerator
from cocotbext.ofm.base.transaction import IdleTransaction
from cocotbext.ofm.mfb.transaction import MfbTransaction


def test_only_on_off_places_gaps_inside_frames():
    assert OnOffIdleGenerator(iter([(1, 1)])).frame_gaps
    assert not IdleGenerator().frame_gaps
    assert not ItemRateLimiter().frame_gaps


def test_gap_is_due_once_the_burst_is_spent():
    gen = OnOffIdleGenerator(iter([(3, 2), (1, 5), (4, 0)]))
    frame = MfbTransaction(data=b"x")

    assert gen.get(frame) == 0
    gen.put(frame, blocks=2)
    assert gen.get(frame) == 0
    gen.put(frame, blocks=1)
    assert gen.get(frame, first=24, last=99) == 2
    # the next burst starts after the gap
    assert gen.get(frame) == 0
    gen.put(frame, blocks=1)
    assert gen.get(frame) == 5
    assert gen.get(frame) == 0


def test_idle_puts_do_not_spend_the_burst():
    gen = OnOffIdleGenerator(iter([(1, 3), (1, 0)]))
    gen.put(IdleTransaction(), items=64)

    assert gen.get(MfbTransaction(data=b"x")) == 0


def test_items_count_where_the_driver_puts_no_blocks():
    gen = OnOffIdleGenerator(iter([(4, 1), (1, 0)]))
    frame = MfbTransaction(data=b"x")
    gen.put(frame, items=4)

    assert gen.get(frame) == 1
