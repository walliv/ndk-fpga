# scoreboard.py: error report and stream checkers for cocotb benches
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

from collections import deque


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


class MergeChecker:
    """Every frame of a merged output must be the next frame of exactly one input, so each input keeps its order and
    nothing is lost, duplicated or altered. A frame is any comparable item; `describe` turns one into text."""

    def __init__(self, report, names, label, describe=repr):
        self.report = report
        self.names = names
        self.label = label
        self.describe = describe
        # Per input, the frames not yet seen on the output with the tag each was added with.
        self.pending = tuple(deque() for _ in names)
        self.out_frames = 0

    def used(self):
        return any(self.pending)

    def add_in(self, idx, frame, tag=None):
        self.pending[idx].append((frame, tag))

    def add_out(self, frame, when):
        """Match an output frame seen at `when` (text) to the input it came from: returns (input index, tag), or None
        when it matches no single input head."""
        self.out_frames += 1
        hits = [i for i, q in enumerate(self.pending) if q and q[0][0] == frame]
        if len(hits) != 1:
            heads = ", ".join(f"{name} head {self.describe(q[0][0]) if q else '-'}" for name, q in zip(self.names, self.pending))
            self.report(f"{self.label}: output frame {self.out_frames} at {when} ({self.describe(frame)}) matches "
                        f"{len(hits)} input heads ({heads})")
            return None
        return hits[0], self.pending[hits[0]].popleft()[1]

    def leftovers(self):
        return [f"{self.label}: {len(q)} {name} frame(s) never left on the output" for name, q in zip(self.names, self.pending) if q]
