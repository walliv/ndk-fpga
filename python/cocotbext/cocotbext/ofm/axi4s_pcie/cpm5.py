# cpm5.py: Driver, monitor and rule checker of the straddled 1024-bit CPM5 AXI4-Stream PCIe interfaces
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

"""Agents for the straddled Versal CPM5 1024-bit CQ, CC and RQ interfaces (PG346 v3.4 Tables 23-28).
A beat holds up to four TLPs, each starting on a 256-bit slot. ``CPM5_RULES`` lists what is checked.
"""

import random
import time
from collections import Counter, deque
from dataclasses import dataclass
from typing import Optional

import cocotb
from cocotb.triggers import ClockCycles, Event, ReadOnly, RisingEdge
from cocotb_bus.monitors import BusMonitor
from cocotb_bus.scoreboard import Scoreboard

from cocotbext.ofm.mfb.drivers import MFBDriver
from cocotbext.ofm.mfb.properties import MFBProperty
from cocotbext.ofm.mfb.transaction import MfbTransaction, MfbTransactionWithMeta
from cocotbext.ofm.mfb.utils import signal_binstr
from cocotbext.ofm.pcie.PcieHeaders import CCHeader, CQHeader, RQHeader

SLOTS = 4
SLOT_DW = 8
BEAT_DW = SLOTS * SLOT_DW
BEAT_BYTES = BEAT_DW * 4
SOP_PTR_W = 2
EOP_PTR_W = 5

CPM5_RULES = (
    "sop_thermometer",      # is_sop must be 0000, 0001, 0011, 0111 or 1111
    "eop_thermometer",      # is_eop likewise: is_eop[n] only with is_eop[n-1]
    "sop_ptr_reserved",     # is_sopN_ptr < N is reserved (TLP N cannot start before slot N)
    "sop_order",            # is_sopN_ptr strictly increasing
    "eop_order",            # is_eopN_ptr strictly increasing
    "sop_while_open",       # a TLP starts before the previous one ended, also in the slot where it ended
    "eop_without_sop",      # a TLP ends that never started
    "first_sop_not_slot0",  # a beat with no TLP to continue must start its first TLP in slot 0
    "tlp_too_short",        # shorter than its descriptor
    "valid_dropped",        # TVALID low while a TLP is open
    "hold_changed",         # TDATA/TUSER moved, or TVALID fell, while TREADY was low
    "discontinue",          # discontinue set where none is expected
    "zero_field",           # a TUSER field the producer must keep at zero is not
    "tlp_open_at_end",      # the stream ended inside a TLP
    "x_in_tlp",             # a TDATA bit inside a TLP's Dwords is not 0/1 (U, X, Z, ...); lanes outside TLPs may be
    "x_in_tuser",           # a TUSER bit the monitor decodes is not 0/1: is_sop/is_eop, used pointers and BEs, zero fields
)

_NB_TO_0 = str.maketrans("UXZWLH-", "0000000")
_NB_TO_MASK = str.maketrans("1UXZWLH-", "01111111")


def resolve_binstr(binstr):
    """(value, mask) of an MSB-first bit string: bits other than 0/1 read as 0 and are set in mask."""
    try:
        return int(binstr, 2), 0
    except ValueError:
        return int(binstr.translate(_NB_TO_0), 2), int(binstr.translate(_NB_TO_MASK), 2)


@dataclass(frozen=True)
class Cpm5UserLayout:
    """Bit offsets of the straddle fields in one interface's TUSER. Per-TLP fields hold four
    copies, TLP 0 lowest. ``desc_dw`` is the descriptor length, the shortest legal TLP."""
    name: str
    width: int
    sop: int
    sop_ptr: int
    eop: int
    eop_ptr: int
    discon: int
    desc_dw: int
    fbe: Optional[int] = None
    lbe: Optional[int] = None
    byte_en: Optional[int] = None
    zero_fields: tuple = ()


# PG346 Table 24, 26 and 28
CQ1024 = Cpm5UserLayout("CQ", 465, sop=160, sop_ptr=164, eop=172, eop_ptr=176, discon=196, desc_dw=4,
                        fbe=128, lbe=144, byte_en=0)
CC1024 = Cpm5UserLayout("CC", 165, sop=0, sop_ptr=4, eop=12, eop_ptr=16, discon=36, desc_dw=3)
# addr_offset must stay zero in the Dword-aligned mode straddling requires
RQ1024 = Cpm5UserLayout("RQ", 373, sop=48, sop_ptr=52, eop=60, eop_ptr=64, discon=84, desc_dw=4,
                        fbe=0, lbe=16, zero_fields=((32, 16),))


class Cpm5ProtocolError(Exception):
    pass


@dataclass
class Cpm5Tlp:
    """One TLP as it crosses the interface: descriptor and payload bytes, its first/last byte
    enables (CQ, RQ) and, on CQ, ``byte_en`` with bit i enabling byte i of ``data``."""
    data: bytes
    first_be: int = 0
    last_be: int = 0
    byte_en: Optional[int] = None

    def __len__(self):
        return len(self.data)

    @property
    def dwords(self):
        return len(self.data) // 4


# =================================================================================================
# Random TLPs
# =================================================================================================

def random_length_dw(rng, max_dw=1024):
    """Payload length mixing the classes the straddle logic cares about: single Dword, fits one
    slot, spans a few slots, spans many beats."""
    cls = rng.random()
    if cls < 0.30:
        return rng.randint(1, 4)
    if cls < 0.65:
        return rng.randint(5, 60)
    if cls < 0.92 or max_dw <= 256:
        return rng.randint(61, min(256, max_dw))
    return rng.randint(257, max_dw)


def random_be(rng, length_dw):
    """first_be/last_be pair legal for a request of ``length_dw`` Dwords."""
    if length_dw == 1:
        return rng.randint(0, 15), 0
    return rng.randint(1, 15), rng.randint(1, 15)


def payload_byte_en(length_dw, first_be, last_be):
    """Byte enables of a payload as the core derives them from the byte enables (PG346 Table 24)."""
    be = 0
    for dw in range(length_dw):
        if dw == 0:
            mask = first_be
        elif dw == length_dw - 1:
            mask = last_be
        else:
            mask = 0xF
        be |= mask << (4 * dw)
    return be


def random_cq_tlp(rng, p_read=0.35):
    """MemRd (descriptor only) or MemWr, as the core delivers it on CQ."""
    hdr = CQHeader()
    is_read = rng.random() < p_read
    length = rng.randint(1, 1024) if is_read else random_length_dw(rng)
    fbe, lbe = random_be(rng, length)
    hdr.addr = rng.getrandbits(62)
    hdr.dword_count = length
    hdr.req_type = 0 if is_read else 1
    hdr.req_id = rng.getrandbits(16)
    hdr.tag = rng.getrandbits(8)
    hdr.tgt_func = rng.getrandbits(8)
    hdr.bar_id = rng.randint(0, 5)
    hdr.bar_apper = rng.randint(12, 40)
    desc = hdr.serialize().to_bytes(16, "little")
    if is_read:
        return Cpm5Tlp(desc, fbe, lbe, byte_en=0)
    payload = rng.randbytes(length * 4)
    # byte_en has one bit per byte and none for the 16 descriptor bytes
    return Cpm5Tlp(desc + payload, fbe, lbe, byte_en=payload_byte_en(length, fbe, lbe) << 16)


def random_cc_tlp(rng, max_dw=1024):
    """Completion: 3-Dword descriptor and 0 to ``max_dw`` Dwords of payload."""
    hdr = CCHeader()
    length = 0 if rng.random() < 0.1 else random_length_dw(rng, max_dw)
    hdr.lower_address = rng.getrandbits(7)
    hdr.byte_count = (length * 4) & 0x1FFF
    hdr.dword_count = length
    hdr.rid = rng.getrandbits(16)
    hdr.tag = rng.getrandbits(8)
    hdr.cid = rng.getrandbits(16)
    desc = hdr.serialize().to_bytes(12, "little")
    return Cpm5Tlp(desc + rng.randbytes(length * 4))


def random_rq_tlp(rng, p_read=0.35, max_dw=1024):
    """MemRd (descriptor only) or MemWr request of up to ``max_dw`` payload Dwords."""
    hdr = RQHeader()
    is_read = rng.random() < p_read
    length = rng.randint(1, 1024) if is_read else random_length_dw(rng, max_dw)
    fbe, lbe = random_be(rng, length)
    hdr.addr = rng.getrandbits(62)
    hdr.dword_count = length
    hdr.req_type = 0 if is_read else 1
    hdr.req_id = rng.getrandbits(16)
    hdr.tag = rng.getrandbits(8)
    desc = hdr.serialize().to_bytes(16, "little")
    if is_read:
        return Cpm5Tlp(desc, fbe, lbe)
    return Cpm5Tlp(desc + rng.randbytes(length * 4), fbe, lbe)


# =================================================================================================
# Driver
# =================================================================================================

class _Beat:
    """One 1024-bit beat under construction."""

    def __init__(self, continuing):
        self.data = 0
        self.byte_en = 0
        self.sops = []  # (slot, tlp)
        self.eops = []  # last Dword index of each TLP ending here
        self.cursor = 0
        self.continuing = continuing

    @property
    def empty(self):
        return not self.sops and not self.continuing

    def user(self, layout):
        u = 0
        for i, (slot, tlp) in enumerate(self.sops):
            u |= 1 << (layout.sop + i)
            u |= slot << (layout.sop_ptr + SOP_PTR_W * i)
            if layout.fbe is not None:
                u |= (tlp.first_be & 0xF) << (layout.fbe + 4 * i)
                u |= (tlp.last_be & 0xF) << (layout.lbe + 4 * i)
        for i, dw in enumerate(self.eops):
            u |= 1 << (layout.eop + i)
            u |= dw << (layout.eop_ptr + EOP_PTR_W * i)
        if layout.byte_en is not None:
            u |= self.byte_en << layout.byte_en
        return u


class Cpm5StraddleDriver:
    """Drives TLPs onto a CPM5 1024-bit interface within ``CPM5_RULES``. ``rng`` decides whether the
    next TLP shares the open beat (``p_share``) and whether it skips free slots (``p_skip``)."""

    _signals = ["DATA", "USER", "VALID", "READY"]
    _optional = ["KEEP", "LAST"]

    def __init__(self, entity, name, clock, layout, rng=None, p_share=0.85, p_skip=0.15):
        self.entity = entity
        self.clock = clock
        self.layout = layout
        self.rng = rng or random.Random()
        self.p_share = p_share
        self.p_skip = p_skip
        self.log = entity._log
        self.bus = {s: getattr(entity, f"{name}_{s}") for s in self._signals}
        for s in self._optional:
            if hasattr(entity, f"{name}_{s}"):
                self.bus[s] = getattr(entity, f"{name}_{s}")
        self._queue = deque()
        self.sent = 0
        self.bus["VALID"].value = 0
        self.bus["DATA"].value = 0
        self.bus["USER"].value = 0
        if "KEEP" in self.bus:
            self.bus["KEEP"].value = (1 << len(self.bus["KEEP"])) - 1
        if "LAST" in self.bus:
            self.bus["LAST"].value = 0
        self._task = cocotb.start_soon(self._drive())

    def append(self, tlp, idle_before=0):
        """Queue a TLP; ``idle_before`` TVALID-low cycles precede it, which closes the open beat."""
        self._queue.append([tlp, idle_before])

    def _beats(self):
        b = _Beat(False)
        cur = None
        while True:
            if cur is None:
                if not self._queue:
                    if not b.empty:
                        yield b
                        b = _Beat(False)
                    yield None
                    continue
                entry = self._queue[0]
                tlp, idle = entry
                if idle:
                    if not b.empty:
                        yield b
                        b = _Beat(False)
                    entry[1] -= 1
                    yield None
                    continue
                if b.empty:
                    slot = 0
                else:
                    first_free = -(-b.cursor // SLOT_DW)
                    if first_free >= SLOTS or self.rng.random() >= self.p_share:
                        yield b
                        b = _Beat(False)
                        slot = 0
                    else:
                        slot = first_free
                        if self.rng.random() < self.p_skip:
                            slot = self.rng.randint(first_free, SLOTS - 1)
                self._queue.popleft()
                cur = [tlp, 0]
                b.sops.append((slot, tlp))
                b.cursor = slot * SLOT_DW

            tlp, off = cur
            n = min(tlp.dwords - off, BEAT_DW - b.cursor)
            chunk = int.from_bytes(tlp.data[off * 4:(off + n) * 4], "little")
            b.data |= chunk << (32 * b.cursor)
            if tlp.byte_en is not None:
                be = (tlp.byte_en >> (4 * off)) & ((1 << (4 * n)) - 1)
                b.byte_en |= be << (4 * b.cursor)
            b.cursor += n
            cur[1] += n
            if cur[1] == tlp.dwords:
                b.eops.append(b.cursor - 1)
                cur = None
                self.sent += 1
            if b.cursor == BEAT_DW:
                yield b
                b = _Beat(cur is not None)

    async def _drive(self):
        clk_re = RisingEdge(self.clock)
        keep = (1 << len(self.bus["DATA"]) // 32) - 1
        await clk_re
        for beat in self._beats():
            if beat is None:
                self.bus["VALID"].value = 0
                await clk_re
                continue
            self.bus["DATA"].value = beat.data
            self.bus["USER"].value = beat.user(self.layout)
            if "KEEP" in self.bus:
                self.bus["KEEP"].value = keep
            self.bus["VALID"].value = 1
            await ReadOnly()
            while signal_binstr(self.bus["READY"]) != "1":
                await clk_re
                await ReadOnly()
            await clk_re


# =================================================================================================
# Monitor and rule checker
# =================================================================================================

class Cpm5StraddleMonitor(BusMonitor):
    """Rebuilds TLPs (``Cpm5Tlp``) from a CPM5 1024-bit interface, checks ``CPM5_RULES`` minus
    ``disable`` and counts corner cases in ``coverage``. ``quiet`` logs violations at INFO."""

    _signals = ["DATA", "USER", "VALID", "READY"]

    def __init__(self, entity, name, clock, layout, disable=(), max_errors=1, quiet=False, **kwargs):
        unknown = set(disable) - set(CPM5_RULES)
        if unknown:
            raise ValueError(f"Cpm5StraddleMonitor: unknown rule(s) {sorted(unknown)}")
        self.layout = layout
        self._disabled = set(disable)
        self.max_errors = max_errors
        self.quiet = quiet
        self.errors = []
        self.coverage = Counter()
        self.beats = 0
        self.tlps = 0
        self._open = None
        self._stalled = None
        self._user_always = (0xF << layout.sop) | (0xF << layout.eop) | (1 << layout.discon)
        for off, width in layout.zero_fields:
            self._user_always |= ((1 << width) - 1) << off
        super().__init__(entity, name, clock, **kwargs)

    def _violation(self, rule, msg):
        if rule in self._disabled:
            return
        text = f"CPM5[{self.layout.name}] beat {self.beats}: {rule}: {msg}"
        self.errors.append(text)
        (self.log.info if self.quiet else self.log.error)(text)
        if self.max_errors and len(self.errors) >= self.max_errors:
            raise Cpm5ProtocolError(text)

    def final_check(self):
        if self._open is not None:
            self._violation("tlp_open_at_end", "the stream ended inside a TLP")
        if self.errors:
            raise Cpm5ProtocolError(f"CPM5[{self.layout.name}]: {len(self.errors)} violation(s), "
                                    f"first: {self.errors[0]}")

    async def _monitor_recv(self):
        clk_re = RisingEdge(self.clock)
        while True:
            await clk_re
            await ReadOnly()
            self._cycle()

    def _cycle(self):
        valid = signal_binstr(self.bus.VALID) == "1"
        ready = signal_binstr(self.bus.READY) == "1"

        if self._stalled is not None:
            if not valid:
                self._violation("hold_changed", "TVALID fell while TREADY was low")
            elif (signal_binstr(self.bus.DATA), signal_binstr(self.bus.USER)) != self._stalled:
                self._violation("hold_changed", "TDATA/TUSER moved while TREADY was low")
        self._stalled = None

        if not valid:
            self.coverage["idle_cycles"] += 1
            if self._open is not None:
                self._violation("valid_dropped", "TVALID low inside a TLP")
            return
        if not ready:
            self._stalled = (signal_binstr(self.bus.DATA), signal_binstr(self.bus.USER))
            self.coverage["stall_cycles"] += 1
            if self._open is not None:
                self.coverage["stall_mid_tlp"] += 1
            return
        data, dmask = resolve_binstr(signal_binstr(self.bus.DATA))
        user, umask = resolve_binstr(signal_binstr(self.bus.USER))
        if dmask or umask:
            self.coverage["beats_with_x"] += 1
        self._beat(data, user, dmask, umask)

    @staticmethod
    def _therm(vec):
        n = bin(vec).count("1")
        return n, vec == (1 << n) - 1

    def _x_in_user(self, umask, mask, what):
        if umask & mask:
            self._violation("x_in_tuser", f"{what}: TUSER bits {umask & mask:#x} are not 0/1")

    def _beat(self, data, user, dmask=0, umask=0):
        """One accepted beat; ``dmask``/``umask`` mark the TDATA/TUSER bits that were not 0/1."""
        lay = self.layout
        self.beats += 1
        if umask:
            self._x_in_user(umask, self._user_always, "is_sop/is_eop/discontinue/zero fields")
        sop_v = (user >> lay.sop) & 0xF
        eop_v = (user >> lay.eop) & 0xF
        nsop, ok = self._therm(sop_v)
        if not ok:
            self._violation("sop_thermometer", f"is_sop = {sop_v:04b}")
        neop, ok = self._therm(eop_v)
        if not ok:
            self._violation("eop_thermometer", f"is_eop = {eop_v:04b}")
        if (user >> lay.discon) & 1:
            self._violation("discontinue", "discontinue is set")
        for off, width in lay.zero_fields:
            if (user >> off) & ((1 << width) - 1):
                self._violation("zero_field", f"TUSER[{off + width - 1}:{off}] is not zero")

        sops = [(user >> (lay.sop_ptr + SOP_PTR_W * i)) & 0x3 for i in range(nsop)]
        eops = [(user >> (lay.eop_ptr + EOP_PTR_W * i)) & 0x1F for i in range(neop)]
        if umask:
            used = (((1 << SOP_PTR_W * nsop) - 1) << lay.sop_ptr) | (((1 << EOP_PTR_W * neop) - 1) << lay.eop_ptr)
            if lay.fbe is not None:
                used |= (((1 << 4 * nsop) - 1) << lay.fbe) | (((1 << 4 * nsop) - 1) << lay.lbe)
            self._x_in_user(umask, used, "pointers/first_be/last_be of the TLPs in the beat")
        for i, s in enumerate(sops):
            if s < i:
                self._violation("sop_ptr_reserved", f"is_sop{i}_ptr = {s:02b}")
        if any(b <= a for a, b in zip(sops, sops[1:])):
            self._violation("sop_order", f"is_sopN_ptr = {sops}")
        if any(b <= a for a, b in zip(eops, eops[1:])):
            self._violation("eop_order", f"is_eopN_ptr = {eops}")
        if self._open is None and sops and sops[0] != 0:
            self._violation("first_sop_not_slot0", f"no TLP to continue, first TLP starts in slot {sops[0]}")

        cov = self.coverage
        cov[f"sops_{nsop}"] += 1
        cov[f"eops_{neop}"] += 1
        for s in sops:
            cov[f"sop_slot_{s}"] += 1
        for e in eops:
            cov[f"eop_dw_{e}"] += 1

        events = sorted([(s * SLOT_DW, 0, i) for i, s in enumerate(sops)]
                        + [(e, 1, i) for i, e in enumerate(eops)])
        seg_from = 0 if self._open is not None else None
        last_eop_slot = None
        for dw, kind, i in events:
            if kind == 0:
                slot = dw // SLOT_DW
                if self._open is not None:
                    self._violation("sop_while_open", f"TLP starts in slot {slot} before the previous ended")
                    self._open = None
                # A SOP sorts before any EOP of its own slot, so a shared slot is reported as sop_while_open
                if last_eop_slot is not None:
                    if slot == last_eop_slot + 1:
                        cov["eop_then_sop_next_slot"] += 1
                    else:
                        cov["slot_gap"] += 1
                fbe = (user >> (lay.fbe + 4 * i)) & 0xF if lay.fbe is not None else 0
                lbe = (user >> (lay.lbe + 4 * i)) & 0xF if lay.lbe is not None else 0
                self._open = {"data": bytearray(), "be": 0, "first_be": fbe, "last_be": lbe,
                              "beat": self.beats, "slot": slot}
                seg_from = dw
            else:
                if self._open is None:
                    self._violation("eop_without_sop", f"TLP ends at Dword {dw} but none is open")
                    continue
                self._take(data, user, seg_from, dw + 1, dmask, umask)
                last_eop_slot = dw // SLOT_DW
                self._close(last_eop_slot)
                seg_from = None
        if self._open is not None:
            self._take(data, user, seg_from, BEAT_DW, dmask, umask)

    def _take(self, data, user, lo, hi, dmask=0, umask=0):
        o = self._open
        n = hi - lo
        if dmask:
            m = (dmask >> (32 * lo)) & ((1 << (32 * n)) - 1)
            if m:
                first = lo + ((m & -m).bit_length() - 1) // 32
                self._violation("x_in_tlp", f"{bin(m).count('1')} TDATA bit(s) not 0/1 in TLP Dwords {lo}..{hi - 1}, "
                                f"first in Dword {first}")
        if umask and self.layout.byte_en is not None:
            self._x_in_user(umask, ((1 << (4 * n)) - 1) << (self.layout.byte_en + 4 * lo),
                            f"byte_en of TLP Dwords {lo}..{hi - 1}")
        o["data"] += ((data >> (32 * lo)) & ((1 << (32 * n)) - 1)).to_bytes(4 * n, "little")
        if self.layout.byte_en is not None:
            be = (user >> (self.layout.byte_en + 4 * lo)) & ((1 << (4 * n)) - 1)
            o["be"] |= be << (4 * (len(o["data"]) // 4 - n))

    def _close(self, eop_slot):
        o, self._open = self._open, None
        lay = self.layout
        dws = len(o["data"]) // 4
        if dws < lay.desc_dw:
            self._violation("tlp_too_short", f"{dws} Dwords, the descriptor alone is {lay.desc_dw}")
        cov = self.coverage
        if o["beat"] == self.beats and o["slot"] == eop_slot:
            cov["eop_sop_same_slot"] += 1
        span = self.beats - o["beat"] + 1
        if span >= 3:
            cov["tlp_3plus_beats"] += 1
        if dws == lay.desc_dw + 1:
            cov["tlp_1dw_payload"] += 1
        self.tlps += 1
        self._recv(Cpm5Tlp(bytes(o["data"]), o["first_be"], o["last_be"],
                           o["be"] if lay.byte_en is not None else None))


# =================================================================================================
# Backpressure and watchdog
# =================================================================================================

async def random_ready(clock, signal, rng, p_phases=(0.0, 0.3, 0.6, 0.9, 1.0), phase_len=(1, 40)):
    """Toggle a ready line: phases of random length, each with its own probability of ready."""
    clk_re = RisingEdge(clock)
    while True:
        p = rng.choice(p_phases)
        for _ in range(rng.randint(*phase_len)):
            await clk_re
            signal.value = int(rng.random() < p)


async def wall_clock_watchdog(clock, limit_s, log, check_every=256):
    """Fail the test once it has run for ``limit_s`` seconds of wall-clock time."""
    t0 = time.monotonic()
    clk_re = RisingEdge(clock)
    while True:
        for _ in range(check_every):
            await clk_re
        if time.monotonic() - t0 > limit_s:
            log.error(f"wall-clock watchdog: test exceeded {limit_s} s")
            raise TimeoutError(f"test exceeded the {limit_s} s wall-clock budget")


def assert_coverage(cov, minima, log):
    """Fail unless every ``minima`` bin was hit at least the given number of times."""
    missing = {k: (cov.get(k, 0), n) for k, n in minima.items() if cov.get(k, 0) < n}
    if missing:
        raise AssertionError(f"coverage holes (hits, needed): {missing}")
    log.info("coverage met: " + ", ".join(f"{k}={cov.get(k, 0)}" for k in minima))


def scoreboard_check(sb):
    """End-of-test verdict of a cocotb_bus Scoreboard. Its ``result`` property is not usable: it
    returns ``test_success()``, which stops the test as passed before any later check runs."""
    pending = {str(mon): len(exp) for mon, exp in sb.expected.items() if not callable(exp) and len(exp)}
    assert not pending, f"transactions still expected: {pending}"
    assert not sb.errors, f"{sb.errors} scoreboard mismatch(es)"


# =================================================================================================
# MFB to CPM5 benches (CC, RQ)
# =================================================================================================

class PcieMfbDriver(MFBDriver):
    """MFBDriver for the PCIe-flavoured MFB PCIE_ADAPTER takes: no SRC_RDY gap inside a frame and,
    once the bus has idled, the next frame starts in region 0. Gaps come only from an empty queue."""

    def __init__(self, entity, name, clock, **kwargs):
        super().__init__(entity, name, clock, vld_gen=None, **kwargs)

    def _clr_physical_bus(self):
        # Called whenever the bus goes idle: the next frame must not resume mid-word
        super()._clr_physical_bus()
        self._last_rgn_idx = 0
        self._last_blk_idx = 0


async def feed_mfb_bursts(driver, clock, transactions, rng, max_burst=40, idles=(0, 0, 1, 2, 5)):
    """Send ``transactions`` in random bursts. Within a burst frames are packed back to back; between
    bursts the queue runs dry, so the bus idles at least one cycle plus a random extra."""
    i = 0
    while i < len(transactions):
        burst = transactions[i:i + rng.randint(1, max_burst)]
        i += len(burst)
        done = Event()
        for j, tr in enumerate(burst):
            driver.append(tr, event=done if j == len(burst) - 1 else None)
        await done.wait()
        await ClockCycles(clock, rng.choice(idles))


async def feed_mfb_region_gaps(dut, mfb_name, clock, transactions, rng, meta_width=0):
    """Hand-built MFB (4,1,8,32) words the MFB driver cannot express: one-region frames on random
    regions with free regions between them (region 0 always taken), held under DST_RDY."""
    bus = {s: getattr(dut, f"{mfb_name}_{s}") for s in ("DATA", "SOF", "EOF", "SOF_POS", "EOF_POS", "SRC_RDY", "DST_RDY")}
    meta = getattr(dut, f"{mfb_name}_META") if meta_width else None
    bus["SOF_POS"].value = 0
    clk_re = RisingEdge(clock)
    i = 0
    while i < len(transactions):
        regions = [0] + [r for r in range(1, SLOTS) if rng.random() < 0.4]
        data = sof = eof = eof_pos = meta_v = 0
        for r in regions[:len(transactions) - i]:
            tr = transactions[i]
            i += 1
            assert len(tr.data) <= SLOT_DW * 4, "region-gap words take one-region frames only"
            data |= int.from_bytes(tr.data, "little") << (32 * SLOT_DW * r)
            sof |= 1 << r
            eof |= 1 << r
            eof_pos |= (len(tr.data) // 4 - 1) << (3 * r)
            if meta is not None:
                meta_v |= tr.meta << (meta_width * r)
        await clk_re
        bus["DATA"].value = data
        bus["SOF"].value = sof
        bus["EOF"].value = eof
        bus["EOF_POS"].value = eof_pos
        if meta is not None:
            meta.value = meta_v
        bus["SRC_RDY"].value = 1
        await ReadOnly()
        while signal_binstr(bus["DST_RDY"]) != "1":
            await clk_re
            await ReadOnly()
        if rng.random() < 0.2:
            await clk_re
            bus["SRC_RDY"].value = 0
            await ClockCycles(clock, rng.randint(0, 3))
    await clk_re
    bus["SRC_RDY"].value = 0


class MfbContractCounter:
    """Counts, on a plain MFB (REGION_SIZE 1) bus, the words that break the CPM5 CC/RQ input contract:
    SRC_RDY low inside a frame, and a word with no frame to continue whose first SOF is not region 0."""

    def __init__(self, entity, name, clock):
        self.bus = {s: getattr(entity, f"{name}_{s}") for s in ("SOF", "EOF", "SRC_RDY", "DST_RDY")}
        self.clock = clock
        self.counts = Counter()
        self._open = False
        cocotb.start_soon(self._run())

    async def _run(self):
        clk_re = RisingEdge(self.clock)
        while True:
            await clk_re
            await ReadOnly()
            src = signal_binstr(self.bus["SRC_RDY"]) == "1"
            if not src:
                if self._open:
                    self.counts["gap_mid_frame"] += 1
                continue
            if signal_binstr(self.bus["DST_RDY"]) != "1":
                continue
            sof = int(signal_binstr(self.bus["SOF"]), 2)
            eof = int(signal_binstr(self.bus["EOF"]), 2)
            if not self._open and sof and not sof & 1:
                self.counts["fresh_sof_not_region0"] += 1
            if bin(sof).count("1") > 1:
                self.counts["multi_sof_words"] += 1
            for r in range(len(self.bus["SOF"])):
                if (eof >> r) & 1:
                    self._open = False
                if (sof >> r) & 1 and not (eof >> r) & 1:
                    self._open = True


async def feed_mfb_gappy(driver, clock, transactions, rng):
    """feed_mfb_bursts with a gap-injecting MFBDriver. Its last partial word stays in the accumulator
    while the queue is dry, so the valid generator is switched off for the final frame to flush it."""
    await feed_mfb_bursts(driver, clock, transactions[:-1], rng)
    driver.set_valid_generator(None)
    done = Event()
    driver.append(transactions[-1], event=done)
    await done.wait()


def gappy_valid_generator(rng, on=(1, 12), off=(0, 8)):
    """(valid, invalid) block counts for MFBDriver: gaps land inside frames and shift SOFs off region 0."""
    while True:
        yield (rng.randint(*on), rng.randint(*off))


async def run_mfb_to_cpm5(dut, clock, mfb_name, axi_name, layout, tlps, rng, meta_of=None, stimulus="bursts"):
    """Drive ``tlps`` through an MFB to CPM5 converter under random TREADY; returns the AXI monitor.
    ``stimulus``: "bursts" (contract-compliant), "region_gaps" (words with free regions),
    "gappy" (any legal MFB: gaps inside frames, SOFs in any region)."""
    if stimulus == "gappy":
        drv = MFBDriver(dut, mfb_name, clock, vld_gen=gappy_valid_generator(random.Random(rng.getrandbits(32))))
    elif stimulus == "bursts":
        drv = PcieMfbDriver(dut, mfb_name, clock)
    else:
        drv = None
    prop = MFBProperty(dut, mfb_name, clock)
    mon = Cpm5StraddleMonitor(dut, axi_name, clock, layout)
    cocotb.start_soon(random_ready(clock, getattr(dut, f"{axi_name}_READY"), random.Random(rng.getrandbits(32))))

    sb = Scoreboard(dut)
    has_be = layout.fbe is not None
    expected = [Cpm5Tlp(t.data, t.first_be, t.last_be) if has_be else Cpm5Tlp(t.data) for t in tlps]
    sb.add_interface(mon, expected)

    trs = [MfbTransactionWithMeta(data=t.data, meta=meta_of(t)) if meta_of else MfbTransaction(data=t.data)
           for t in tlps]
    if stimulus == "region_gaps":
        meta_w = len(getattr(dut, f"{mfb_name}_META")) // SLOTS if meta_of else 0
        cocotb.start_soon(feed_mfb_region_gaps(dut, mfb_name, clock, trs, random.Random(rng.getrandbits(32)), meta_w))
    elif stimulus == "gappy":
        cocotb.start_soon(feed_mfb_gappy(drv, clock, trs, random.Random(rng.getrandbits(32))))
    else:
        cocotb.start_soon(feed_mfb_bursts(drv, clock, trs, random.Random(rng.getrandbits(32))))

    for _ in range(len(tlps) * 200 + 10000):
        await RisingEdge(clock)
        if not expected:
            break
    await ClockCycles(clock, 8)

    mon.final_check()
    prop.final_check()
    scoreboard_check(sb)
    dut._log.info(f"sent {len(tlps)} TLPs, received {mon.tlps} in {mon.beats} beats")
    assert mon.tlps == len(tlps), f"{len(tlps)} TLPs sent, {mon.tlps} received"
    return mon
