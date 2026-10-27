# test_random.py: unit test of the random generator helpers
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import random

from cocotbext.ofm.utils.random import named_rngs


def test_named_rngs_follow_the_global_seed_and_draw_once_from_it():
    random.seed(7)
    a = named_rngs("x", "y")
    after = random.random()
    random.seed(7)
    b = named_rngs("x", "y")

    assert [a["x"].random(), a["y"].random()] == [b["x"].random(), b["y"].random()]
    assert a["x"].getstate() != a["y"].getstate()
    random.seed(7)
    random.getrandbits(64)
    assert random.random() == after
