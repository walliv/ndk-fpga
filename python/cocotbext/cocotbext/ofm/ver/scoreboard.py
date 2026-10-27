# scoreboard.py: error report for the checkers of cocotb benches
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0


class ReportError(AssertionError):
    pass


class Report:
    """Error sink of a bench's checkers: logs and keeps every error and raises ReportError once `max_errors` errors are
    reported (never with 0), so raising from a bench task ends the test as failed."""

    def __init__(self, log, max_errors=0):
        self.log = log
        self.max_errors = max_errors
        self.errors = []

    def __call__(self, msg):
        self.log.error(msg)
        self.errors.append(msg)
        if self.max_errors and len(self.errors) >= self.max_errors:
            raise ReportError(msg)
