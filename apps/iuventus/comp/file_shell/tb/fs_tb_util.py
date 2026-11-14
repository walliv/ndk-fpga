# fs_tb_util.py: cocotb helpers shared by the file shell's benches
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0
"""Seeding, clocking, reset release and signal reads every FS_* bench needs."""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, Timer

CLK_NS = 4


def seeded(salt):
    """A generator derived from cocotb's seed: every run drives different traffic, and
    COCOTB_RANDOM_SEED still reproduces one."""
    return random.Random(cocotb.RANDOM_SEED * 2654435761 + salt)


def start_clock(dut):
    cocotb.start_soon(Clock(dut.CLK, CLK_NS, unit="ns").start())


async def settle(dut):
    """One clock edge and 1 ns past it, where the benches drive their stimulus."""
    await RisingEdge(dut.CLK)
    await Timer(1, unit="ns")


async def release_reset(dut, hold_cycles, after_cycles, sigs=("RESET",)):
    """Drops the `sigs` resets 1 ns past the edge ending `hold_cycles` clocks, then waits `after_cycles`."""
    await ClockCycles(dut.CLK, hold_cycles)
    await Timer(1, unit="ns")
    for sig in sigs:
        getattr(dut, sig).value = 0
    await ClockCycles(dut.CLK, after_cycles)


def as_int(handle):
    """The handle's value, 0 while it still holds an unresolved one."""
    try:
        return int(handle.value)
    except ValueError:
        return 0


def rand_mask(rng, probs):
    """A bit vector whose bit i is set with probability probs[i], one draw per bit."""
    return sum(1 << i for i, p in enumerate(probs) if rng.random() < p)


def onehot_index(vec, what):
    """Index of the single set bit of `vec`; fails if several are set."""
    assert vec & (vec - 1) == 0, f"{what}={vec:b} is not one-hot"
    return vec.bit_length() - 1
