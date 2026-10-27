# test_scoreboard.py: unit test of the error report and the stream checkers
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import logging

import pytest

from cocotbext.ofm.ver.scoreboard import MergeChecker, OrderedComparer, Report, ReportError, UnorderedComparer


def test_report_raises_at_its_error_limit():
    report = Report(logging.getLogger("test_scoreboard"), max_errors=2)
    report("first")
    with pytest.raises(ReportError, match="second"):
        report("second")
    assert report.errors == ["first", "second"]


def test_merge_checker_follows_each_input_in_order():
    report = Report(logging.getLogger("test_scoreboard"))
    merge = MergeChecker(report, ("in0", "in1"), "out")
    merge.add_in(0, "a", 1)
    merge.add_in(1, "b", 2)
    merge.add_in(0, "c", 3)

    assert merge.add_out("b", "t0") == (1, 2)
    assert merge.add_out("c", "t1") is None
    assert merge.add_out("a", "t2") == (0, 1)
    assert len(report.errors) == 1 and "matches 0 input heads" in report.errors[0]
    assert merge.leftovers() == ["out: 1 in0 frame(s) never left on the output"] and merge.out_frames == 3


def _diff(model, dut):
    return [] if model == dut else [f"{model} != {dut}"]


def test_ordered_comparer_pairs_items_in_order_and_times_out_a_lone_dut_item():
    report = Report(logging.getLogger("test_scoreboard"))
    cmp = OrderedComparer("c", _diff, str, report, dut_may_lead=False, grace_ns=8)
    cmp.add_model(1)
    cmp.add_dut(2, 0)
    cmp.add_dut(3, 10)
    cmp.tick(15)
    cmp.tick(19)

    assert cmp.compared == 1 and len(report.errors) == 2
    assert "does not match" in report.errors[0] and "unexpected DUT transaction at 10 ns" in report.errors[1]
    assert not cmp.used()


def test_unordered_comparer_matches_any_pending_item():
    report = Report(logging.getLogger("test_scoreboard"))
    cmp = UnorderedComparer("c", _diff, str, report, dut_may_lead=True)
    for item in (1, 2, 3):
        cmp.add_model(item)
    cmp.add_dut(3, 0)
    cmp.add_dut(1, 0)

    assert cmp.compared == 2 and not report.errors
    assert cmp.leftovers() == ["c: 1 expected item(s) never seen, first: 2"]
