# fs_ring_fetch_model.py: reference model of FS_RING_FETCH (ring layout, entry order, burst rules)
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

"""The fetcher must deliver entry i = the 16 B at RING_BASE + (i mod 2**LOG2_DEPTH)*16 as the host
published it, in ring order, once each; its bursts obey the FS_HBM_PORT client rules."""

from fs_ctx import AXI_BEAT, ENTRY_BYTES

PAGE = 4096
MAX_BEATS = 16


class RingFetchModel:
    def __init__(self, log2_depth, ring_base):
        self.depth = 1 << log2_depth
        self.base = ring_base
        self.clear()

    def clear(self):
        self.last_first = None
        self.published = []     # entry contents in ring order, as published below TAIL
        self.popped = 0

    def slot_addr(self, i):
        return self.base + (i % self.depth) * ENTRY_BYTES

    def publish(self, content):
        """The host wrote entry len(published) into its slot; returns that slot's byte address."""
        assert len(self.published) - self.popped < self.depth, "host would overwrite an unpopped entry"
        i = len(self.published)
        self.published.append(content)
        return self.slot_addr(i)

    @property
    def tail(self):
        return len(self.published)

    def pop(self):
        """Expected (content, HEAD after the pop)."""
        assert self.popped < self.tail, "entry popped beyond TAIL"
        content = self.published[self.popped]
        self.popped += 1
        return content, self.popped

    def check_burst(self, addr, beats, tail):
        """Errors of one accepted burst, given the TAIL in force when it was accepted."""
        errs = []
        if addr % AXI_BEAT:
            errs.append(f"burst at 0x{addr:x} not 32 B aligned")
        if not 1 <= beats <= MAX_BEATS:
            errs.append(f"burst of {beats} beats")
        if addr // PAGE != (addr + beats * AXI_BEAT - 1) // PAGE:
            errs.append(f"burst 0x{addr:x} x{beats} crosses 4 KiB")
        end = self.base + self.depth * ENTRY_BYTES
        if not (self.base <= addr and addr + beats * AXI_BEAT <= end):
            errs.append(f"burst 0x{addr:x} x{beats} leaves the ring [0x{self.base:x}, 0x{end:x})")
        self.last_first = None
        if errs:
            return errs
        # Requested entries lie in [popped - 1, popped - 1 + depth): the low entry of a beat may
        # precede an odd fetch pointer by one, and the host never runs more than a ring ahead.
        lo = self.popped - 1
        slot0 = (addr - self.base) // ENTRY_BYTES
        first = lo + (slot0 - lo) % self.depth
        self.last_first = first
        last_beat_lo = first + 2 * (beats - 1)
        if last_beat_lo >= tail:
            errs.append(f"burst 0x{addr:x} x{beats} reads a beat wholly at or past TAIL {tail}")
        return errs
