# test_scoreboard.py: unit test of the error report
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import logging

import pytest

from cocotbext.ofm.ver.scoreboard import Report, ReportError


def test_report_raises_at_its_error_limit():
    report = Report(logging.getLogger("test_scoreboard"), max_errors=2)
    report("first")
    with pytest.raises(ReportError, match="second"):
        report("second")
    assert report.errors == ["first", "second"]
