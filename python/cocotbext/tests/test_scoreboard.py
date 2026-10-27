# test_scoreboard.py: unit test of the error report and the stream checkers
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import logging

import pytest

from cocotbext.ofm.ver.scoreboard import MergeChecker, Report, ReportError


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
