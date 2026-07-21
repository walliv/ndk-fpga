# scoreboard.py: minimal deque-based scoreboard for the USER_CORE reference-model tests. Pops
# the reference model's next-expected item and asserts equality against each observed DUT
# transaction, in order. A leftover (never-observed) expected item at test end is exactly the
# short-stream/stall failure mode this testbench exists to catch.
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import logging
from collections import deque


class Scoreboard:
    def __init__(self, name: str):
        self.name = name
        self._expected = deque()
        self.log = logging.getLogger(f"cocotb.scoreboard.{name}")
        self.checked = 0

    def expect(self, item) -> None:
        self._expected.append(item)

    def check(self, actual) -> None:
        if not self._expected:
            raise AssertionError(f"{self.name}: unexpected extra item, got {actual!r} but nothing was expected")

        expected = self._expected.popleft()
        self.checked += 1
        if expected != actual:
            raise AssertionError(f"{self.name}: mismatch at item #{self.checked}\n  expected: {expected!r}\n  actual:   {actual!r}")

        self.log.debug(f"item #{self.checked} OK: {actual!r}")

    def assert_empty(self) -> None:
        assert not self._expected, (
            f"{self.name}: {len(self._expected)} expected item(s) never observed (short stream / "
            f"stall): {list(self._expected)}"
        )
