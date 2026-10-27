# traffic.py: stimulus shapes ported from the UVM sequence libraries used by the Calypte benches
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

from cocotb.triggers import RisingEdge

# Weights of the UVM "eighths" distribution: min, the eight sub-ranges, max.
_EIGHTHS_W = (5, 20, 7, 5, 3, 2, 1, 1, 3, 5)
# The rdy_probability variant has no separate min entry.
_RDY_W = (3, 1, 1, 1, 3, 5, 10, 20, 30)
# `ndk_rand_dist_first, `ndk_rand_dist 1..7, `ndk_rand_dist_last (comp/uvm/ndk_macros.svh).
_NDK_W = (10, 10, 8, 3, 1, 3, 8, 10, 10)


def pick(rng, ranges):
    """SV `dist` with `:/` weights: pick a range by its weight, then a value uniformly inside."""
    total = sum(w for _, _, w in ranges)
    x = rng.random() * total
    for lo, hi, w in ranges:
        if x < w:
            return rng.randint(lo, hi)
        x -= w
    lo, hi, _ = ranges[-1]
    return rng.randint(lo, hi)


def eighths(lo, hi):
    step = (hi - lo) // 8
    parts = [(lo, lo, _EIGHTHS_W[0])]
    parts += [(lo + step * k, lo + step * (k + 1), _EIGHTHS_W[k + 1]) for k in range(8)]
    parts.append((hi, hi, _EIGHTHS_W[9]))
    return parts


def rdy_eighths(lo, hi):
    step = (hi - lo) // 8
    parts = [(lo + step * k, lo + step * (k + 1), _RDY_W[k]) for k in range(8)]
    parts.append((hi, hi, _RDY_W[8]))
    return parts


def ndk_rand_dist(lo, hi, div=8):
    step = (hi - lo) // div
    parts = [(lo, lo + step, _NDK_W[0])]
    parts += [(lo + step * (b - 1), lo + step * b, _NDK_W[b]) for b in range(1, div)]
    parts.append((lo + step * (div - 1), hi, _NDK_W[div]))
    return parts


def pick_ordered_pair(rng, ranges):
    """Two values of one distribution under `a <= b`, by rejection like the SV solver's result."""
    while True:
        a, b = pick(rng, ranges), pick(rng, ranges)
        if a <= b:
            return a, b


def rx_sequence_sizes(rng, smin, smax):
    """Packet sizes of one sequence of uvm_logic_vector_array::sequence_lib (seven kinds)."""
    kind = rng.randrange(7)
    count = rng.randint(10, 200)
    dist = eighths(smin, smax)
    sizes = []
    if kind == 0:
        lo, hi = pick_ordered_pair(rng, dist)
        sizes = [rng.randint(lo, hi) for _ in range(count)]
    elif kind == 1:
        sizes = [pick(rng, dist)] * count
    elif kind == 2:
        mean, sd = pick(rng, dist), rng.randint(1, 32)
        for _ in range(count):
            v = int(round(rng.gauss(mean, sd)))
            sizes.append(v if smin < v < smax else mean)
    elif kind == 3:
        step, size = rng.randint(1, 16), rng.randint(smin, smax)
        while len(sizes) < count and size <= smax and size <= 4096:
            sizes.append(size)
            size += step
    elif kind == 4:
        step, size = rng.randint(1, 16), rng.randint(smin, smax)
        while len(sizes) < count and size >= smin and size >= 64:
            sizes.append(size)
            size -= step
    elif kind == 5:
        sizes = [rng.choice((smin, smax)) for _ in range(count)]
    else:
        lo, hi = pick_ordered_pair(rng, dist)
        mean = (hi - lo) // 2
        for _ in range(count):
            v = int(round(rng.gauss(mean, mean // 3))) if mean // 3 else mean
            v = max(min(v, hi), lo)
            sizes.append(min(v + mean, hi) if v < mean else max(v - mean, lo))
    return sizes


class MfbIdleGen:
    """(valid, idle) block generator for MFBDriver switching between the kinds of
    uvm_logic_vector_array_mfb::sequence_lib_rx. MFBDriver places idle blocks anywhere, not only
    between frames, so the shapes are approximate."""

    def __init__(self, rng, blocks_per_word):
        self.rng = rng
        self.w = blocks_per_word
        self._run = iter(())

    def __iter__(self):
        return self

    def _new_run(self):
        rng, w = self.rng, self.w
        kind = rng.randrange(6)
        words = rng.randint(10, 300) * 8
        if kind in (1, 2):
            gap = 0 if kind == 1 else rng.randint(0, 200)
            yield (words * w, gap)
        elif kind == 3:
            yield (1, rng.randint(30, 500) * w)
        elif kind == 4:
            rmin, rmax = pick_ordered_pair(rng, rdy_eighths(1, 100))
            burst = rng.randint(10, 100)
            on = max(1, rng.randint(rmin, rmax) * burst * w // 8)
            off = rng.randint(100 - rmax, 100 - rmin) * burst * w // 8
            yield (on, off)
        else:
            p = max(1, min(100, pick(rng, rdy_eighths(0, 100))))
            smin, smax = pick_ordered_pair(rng, eighths(0, 200))
            left = words
            while left > 0:
                on = 1
                while on < 64 * w and rng.randrange(100) < p:
                    on += 1
                off = 0
                while off < 64 * w and rng.randrange(100) >= p:
                    off += w
                if rng.randrange(16) == 0:
                    off += rng.randint(smin, smax)
                left -= max(1, (on + off) // w)
                yield (on, off)

    def __next__(self):
        while True:
            try:
                return next(self._run)
            except StopIteration:
                self._run = self._new_run()


class _RandRdyRand:
    """uvm_common::rand_rdy_rand with every bound class active (cfg rdy_probability 0..100)."""

    def __init__(self, rng):
        self.rng = rng
        self.rand_count = 0
        self.one = self.zero = 0
        self.mode_burst = False
        self.ones_count = self.zeros_count = 0

    def _bounds(self):
        rng = self.rng
        k = rng.randrange(6)
        one = (100, rng.randint(90, 100), rng.randint(70, 90), rng.randint(10, 30), 0, rng.randint(0, 100))[k]
        return one, 100 - one

    def next(self):
        rng = self.rng
        if self.rand_count == 0:
            self.rand_count = rng.randint(25, 500)
            self.one, self.zero = self._bounds()
            self.mode_burst = rng.randrange(11) != 0
            self.ones_count = round(self.one * self.rand_count / (self.one + self.zero))
            self.zeros_count = round(self.zero * self.rand_count / (self.one + self.zero))
        else:
            self.rand_count -= 1
        if self.mode_burst:
            if self.ones_count != 0 or self.one == 100:
                self.ones_count -= 1
                return 1
            self.zeros_count -= 1
            return 0
        return 1 if rng.randrange(self.one + self.zero) < self.one else 0


async def drive_dst_rdy(signal, clock, rng, speed):
    """DST_RDY as uvm_mfb::sequence_lib_tx (simple / full speed / stop), or always 1 (speed tests).
    Written at the edge, so a ReadOnly sampler of that edge sees the value of the next transfer."""
    edge = RisingEdge(clock)
    if speed:
        signal.value = 1
        return
    while True:
        kind = rng.randrange(3)
        if kind == 0:
            gen = _RandRdyRand(rng)
            for _ in range(rng.randint(10, 100)):
                signal.value = gen.next()
                await edge
        elif kind == 1:
            signal.value = 1
            for _ in range(rng.randint(10, 100)):
                await edge
        else:
            signal.value = 0
            for _ in range(rng.randint(10, 50)):
                await edge
