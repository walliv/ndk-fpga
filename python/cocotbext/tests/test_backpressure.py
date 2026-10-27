# test_backpressure.py: unit test of the backpressure generator
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import random
from itertools import islice

import pytest

from cocotbext.ofm.ver.backpressure import BackpressureConfig, BackpressureGenerator, apply_backpressure
from stubs import StubSignal


def test_levels_unroll_the_runs():
    cfg = BackpressureConfig(1, 7, 0.4)
    random.seed(5)
    runs = list(islice(BackpressureGenerator(cfg), 200))
    random.seed(5)
    levels = list(islice(BackpressureGenerator(cfg).levels(), sum(on + off for on, off in runs)))

    assert levels == [lvl for on, off in runs for lvl in [1] * on + [0] * off]


def test_levels_follow_the_low_probability():
    assert set(islice(BackpressureGenerator(BackpressureConfig(1, 5, 0.0)).levels(), 500)) == {1}
    assert set(islice(BackpressureGenerator(BackpressureConfig(1, 5, 1.0)).levels(), 500)) == {0}


def test_a_given_generator_leaves_the_global_one_alone():
    cfg = BackpressureConfig(1, 7, 0.4)
    random.seed(5)
    expected = list(islice(BackpressureGenerator(cfg), 50))
    random.seed(5)
    state = random.getstate()

    assert list(islice(BackpressureGenerator(cfg, rng=random.Random(5)), 50)) == expected
    assert random.getstate() == state


@pytest.mark.parametrize("low_prob, level", [(0.0, 1), (1.0, 0)])
def test_apply_backpressure_draws_from_the_given_generator(low_prob, level, monkeypatch):
    class Stop(Exception):
        pass

    async def stop(*args):
        raise Stop

    monkeypatch.setattr("cocotbext.ofm.ver.backpressure.ClockCycles", stop)
    rng = random.Random(1)
    state = random.getstate()
    signal = StubSignal(1)
    with pytest.raises(Stop):
        apply_backpressure(signal, None, BackpressureConfig(1, 5, low_prob), rng=rng).send(None)

    assert signal.written == [level]
    assert random.getstate() == state and rng.getstate() != random.Random(1).getstate()
