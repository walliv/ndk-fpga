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


class OrderedComparer:
    """Compares DUT items with model items in order, as uvm_common::comparer_base_ordered. `compare(model, dut)` returns
    the list of differences, `describe(item)` a text. With `dut_may_lead` a DUT item waits for its model item without a
    limit; otherwise it must find it within `grace_ns`, see tick()."""

    def __init__(self, name, compare, describe, report, dut_may_lead, grace_ns=8):
        self.name = name
        self.compare = compare
        self.describe = describe
        self.report = report
        self.dut_may_lead = dut_may_lead
        self.grace_ns = grace_ns
        self.model = deque()
        self.dut = deque()
        self.compared = 0

    def used(self):
        return bool(self.model) or bool(self.dut)

    def _check(self, model, dut):
        diffs = self.compare(model, dut)
        if diffs:
            self.report(f"{self.name}: transaction {self.compared + 1} does not match: {'; '.join(diffs)}\n"
                        f"  MODEL: {self.describe(model)}\n  DUT:   {self.describe(dut)}")
        self.compared += 1

    def add_model(self, item):
        if self.dut:
            self._check(item, self.dut.popleft()[0])
        else:
            self.model.append(item)

    def add_dut(self, item, now):
        if self.model:
            self._check(self.model.popleft(), item)
        else:
            self.dut.append((item, now))

    def tick(self, now):
        """Report a DUT item that has waited for its model item longer than `grace_ns` at the time `now` in ns."""
        if self.dut and not self.dut_may_lead and now - self.dut[0][1] > self.grace_ns:
            item, t = self.dut.popleft()
            self.report(f"{self.name}: unexpected DUT transaction at {t} ns, no model item: {self.describe(item)}")

    def leftovers(self):
        out = [f"{self.name}: {len(self.model)} expected item(s) never seen, first: {self.describe(self.model[0])}"
               ] if self.model else []
        if self.dut:
            out.append(f"{self.name}: {len(self.dut)} DUT item(s) never expected, first at {self.dut[0][1]} ns: "
                       f"{self.describe(self.dut[0][0])}")
        return out


class UnorderedComparer(OrderedComparer):
    """uvm_common::comparer_base_unordered: an item matches any pending item of the other side."""

    def add_model(self, item):
        for i, (d, _) in enumerate(self.dut):
            if not self.compare(item, d):
                del self.dut[i]
                self.compared += 1
                return
        self.model.append(item)

    def add_dut(self, item, now):
        for i, m in enumerate(self.model):
            if not self.compare(m, item):
                del self.model[i]
                self.compared += 1
                return
        self.dut.append((item, now))

    def tick(self, now):
        if self.dut and not self.dut_may_lead and now - self.dut[0][1] > self.grace_ns:
            item, t = self.dut.popleft()
            closest = min(self.model, key=lambda m: len(self.compare(m, item)), default=None)
            self.report(f"{self.name}: DUT transaction at {t} ns matches no expectation: {self.describe(item)}"
                        + (f"\n  closest expectation: {self.describe(closest)} -- {'; '.join(self.compare(closest, item))}"
                           if closest is not None else " (none pending)"))


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
