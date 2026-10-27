# usp.py: Stimulus and meta model of the CQ interface of the UltraScale+ PCIe IP
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

"""Completer Request (CQ) AXI4-Stream interface of the UltraScale+ PCIe IP, see PG213 tables 10 and 18.

``UspLayout`` selects the 256-bit interface or the 512-bit one with or without straddling. ``pack_cq`` turns TLPs into
beats, ``UspCqDriver`` drives them and ``CqTlp.meta`` gives the PCIE_CQ_META an MFB converter has to produce for them.
``run_cq_test`` sends TLPs to a DUT and compares the frames and meta of its CQ MFB output with them.
"""

import random
from dataclasses import dataclass

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge
from cocotb_bus.drivers import BitDriver
from cocotb_bus.scoreboard import Scoreboard

from cocotbext.ofm.mfb.transaction import MfbTransactionWithMeta
from cocotbext.ofm.pcie.PcieHeaders import CQHeader, CQMfbMeta, CQUser, CQUser256
from cocotbext.ofm.utils.header import concat
from cocotbext.ofm.ver.backpressure import BackpressureConfig, BackpressureGenerator

REGION_DW = 8


@dataclass(frozen=True)
class UspLayout:
    """Width of the data bus, width of TUSER and the straddling of one AXI4-Stream interface of the IP."""
    name: str
    data_bits: int
    user_bits: int
    straddle: bool

    @property
    def dws(self):
        return self.data_bits // 32

    @property
    def regions(self):
        return self.dws // REGION_DW


CQ256 = UspLayout("cq256", 256, 88, False)
CQ256_85 = UspLayout("cq256_85", 256, 85, False)
CQ512 = UspLayout("cq512", 512, 183, False)
CQ512_STRADDLE = UspLayout("cq512_straddle", 512, 183, True)


def cq_layout(regions, straddle, user_bits=88):
    """Layout of a CQ interface whose MFB side has ``regions`` regions."""
    if regions == 1:
        return CQ256 if user_bits == 88 else CQ256_85
    return CQ512_STRADDLE if straddle else CQ512


def _dw_bytes(dws):
    return b"".join(dw.to_bytes(4, "little") for dw in dws)


@dataclass
class CqTlp:
    """One TLP of the CQ interface with the sideband values its first beat carries."""
    dwords: list
    first_be: int = 0
    last_be: int = 0
    # Byte enables of the 32 bytes of the region where the TLP starts, the 16 bytes of the descriptor are 0
    be: int = 0
    tph_present: int = 0
    tph_type: int = 0
    tph_st_tag: int = 0

    def frame(self):
        return _dw_bytes(self.dwords)

    def meta(self):
        """PCIE_CQ_META of the region where the TLP starts."""
        meta = CQMfbMeta()
        meta.firstBe, meta.lastBe, meta.be = self.first_be, self.last_be, self.be
        meta.tph_present, meta.tph_type, meta.tph_st_tag = self.tph_present, self.tph_type, self.tph_st_tag
        return meta.serialize()


@dataclass
class CqBeat:
    data: int
    user: int
    keep: int
    last: int
    # The beat continues a TLP of the previous one, so no gap may precede it
    cont_in: bool = False


def random_cq_tlp(rng, max_payload_dw=64, p_read=0.4):
    """A random memory read, or a write of 1 to ``max_payload_dw`` Dwords."""
    hdr = CQHeader()
    hdr.addr = rng.getrandbits(62)
    hdr.req_id = rng.getrandbits(16)
    hdr.tag = rng.getrandbits(8)
    hdr.bar_id = rng.randrange(6)
    hdr.bar_apper = rng.randrange(1, 64)
    if rng.random() < p_read:
        hdr.req_type = 0
        hdr.dword_count = rng.randint(1, 1024) % 1024
        payload = []
    else:
        hdr.req_type = 1
        n = rng.choice((1, 1, 2, 3, 4, 4, 5, 8, 11, 12, rng.randint(1, max_payload_dw)))
        hdr.dword_count = n
        payload = [rng.getrandbits(32) for _ in range(n)]
    hdr_bytes = hdr.serialize().to_bytes(16, "little")
    dwords = [int.from_bytes(hdr_bytes[4 * i:4 * i + 4], "little") for i in range(4)] + payload
    # The bytes of the descriptor are never enabled and the 16 bytes after it are the first payload of the region
    be = rng.getrandbits(min(len(payload) * 4, 16)) << 16 if payload else 0
    return CqTlp(dwords, rng.getrandbits(4), rng.getrandbits(4), be,
                 rng.getrandbits(1), rng.getrandbits(2), rng.getrandbits(8))


def _user_512(rng, byte_en_regions, sops, eops):
    """TUSER of the 512-bit interface, ``sops`` holds (start Dword, TLP) and ``eops`` the last Dword of each ending TLP."""
    user = CQUser()
    user.parity = rng.getrandbits(64)
    for j, (start, tlp) in enumerate(sops):
        setattr(user, f"firstBe{j}", tlp.first_be)
        setattr(user, f"lastBe{j}", tlp.last_be)
        setattr(user, f"sop{j}", 1)
        setattr(user, f"sop_ptr{j}", 2 if start == REGION_DW else 0)
        user.tph_present |= tlp.tph_present << j
        user.tph_type |= tlp.tph_type << (2 * j)
        user.tph_sh_tag |= tlp.tph_st_tag << (8 * j)
    for j, dw in enumerate(eops):
        setattr(user, f"eop{j}", 1)
        setattr(user, f"eop_ptr{j}", dw)
    user.byte_en = byte_en_regions[0] | (byte_en_regions[1] << 32)
    return user.serialize()


def _user_256(rng, tlp, sop, byte_en):
    user = CQUser256()
    user.parity = rng.getrandbits(32)
    if sop:
        user.first_be, user.last_be = tlp.first_be, tlp.last_be
        user.tph_present, user.tph_type, user.tph_st_tag = tlp.tph_present, tlp.tph_type, tlp.tph_st_tag
    user.byte_en, user.sop = byte_en, int(sop)
    return user.serialize()


def _fill(rng, dws):
    return [rng.getrandbits(32) for _ in range(dws)]


def _data(dw_list):
    return concat([(dw, 32) for dw in dw_list])


def _pack_plain(layout, tlps, rng):
    """One TLP per beat sequence, as without straddling."""
    beats = []
    for tlp in tlps:
        n = len(tlp.dwords)
        for k in range(0, n, layout.dws):
            chunk = tlp.dwords[k:k + layout.dws]
            first = k == 0
            last = k + layout.dws >= n
            dws = chunk + _fill(rng, layout.dws - len(chunk))
            keep = (1 << len(chunk)) - 1
            if layout.data_bits == 512:
                be_regions = [tlp.be if first else rng.getrandbits(32), rng.getrandbits(32)]
                user = _user_512(rng, be_regions, [(0, tlp)] if first else [], [len(chunk) - 1] if last else [])
            else:
                user = _user_256(rng, tlp, first, tlp.be if first else rng.getrandbits(32))
            beats.append(CqBeat(_data(dws), user, keep, int(last), cont_in=not first))
    return beats


def _pack_straddle(layout, tlps, rng):
    """Up to two TLPs per beat, a TLP starts in Dword 0 or in the Dword 8 where the second region starts."""
    beats = []
    i = 0
    cont = None
    while i < len(tlps) or cont:
        dws = [None] * layout.dws
        sops = []
        eops = []
        cont_in = cont is not None
        cursor = 0
        if cont:
            tlp, k = cont
            n = min(layout.dws, len(tlp.dwords) - k)
            dws[:n] = tlp.dwords[k:k + n]
            cursor = n
            cont = None if k + n == len(tlp.dwords) else (tlp, k + n)
            if cont is None:
                eops.append(n - 1)
        while cont is None and i < len(tlps) and len(sops) < 2:
            if cursor == 0:
                start = 0
            elif cursor <= REGION_DW:
                start = REGION_DW
            else:
                break
            tlp = tlps[i]
            i += 1
            n = min(layout.dws - start, len(tlp.dwords))
            dws[start:start + n] = tlp.dwords[:n]
            sops.append((start, tlp))
            if n == len(tlp.dwords):
                eops.append(start + n - 1)
                cursor = start + n
            else:
                cont = (tlp, n)
                cursor = layout.dws
        keep = sum(1 << d for d, v in enumerate(dws) if v is not None)
        dws = [v if v is not None else rng.getrandbits(32) for v in dws]
        be_regions = [rng.getrandbits(32), rng.getrandbits(32)]
        for start, tlp in sops:
            be_regions[start // REGION_DW] = tlp.be
        user = _user_512(rng, be_regions, sops, eops)
        beats.append(CqBeat(_data(dws), user, keep, int(bool(eops)), cont_in=cont_in))
    return beats


def random_cq_tlps(n, **kwargs):
    """``make_tlps`` of ``run_cq_test`` that draws ``n`` TLPs of ``random_cq_tlp(rng, **kwargs)``."""
    return lambda rng: [random_cq_tlp(rng, **kwargs) for _ in range(n)]


def pack_cq(layout, tlps, rng):
    """Beats the IP puts on the CQ interface for ``tlps``."""
    return _pack_straddle(layout, tlps, rng) if layout.straddle else _pack_plain(layout, tlps, rng)


class UspCqDriver:
    """Drives beats on the ``<name>_AXI_*`` signals of a CQ interface, waiting for READY, with gaps only between TLPs."""

    def __init__(self, dut, name, clock, rng, p_idle=0.1):
        self.dut = dut
        self.clock = clock
        self.sig = {s: getattr(dut, f"{name}_AXI_{s}") for s in ("DATA", "USER", "LAST", "KEEP", "VALID", "READY")}
        self.rng = rng
        self.p_idle = p_idle
        self.beats = []
        self.sig["VALID"].value = 0
        self.sig["LAST"].value = 0
        self.sig["DATA"].value = 0
        self.sig["USER"].value = 0
        self.sig["KEEP"].value = 0
        cocotb.start_soon(self._run())

    def append(self, beats):
        self.beats.extend(beats)

    async def _run(self):
        s = self.sig
        while True:
            if not self.beats:
                s["VALID"].value = 0
                await RisingEdge(self.clock)
                continue
            beat = self.beats.pop(0)
            if not beat.cont_in and self.rng.random() < self.p_idle:
                for _ in range(self.rng.randint(1, 4)):
                    s["VALID"].value = 0
                    s["DATA"].value = self.rng.getrandbits(len(s["DATA"]))
                    await RisingEdge(self.clock)
            s["VALID"].value = 1
            s["DATA"].value = beat.data
            s["USER"].value = beat.user
            s["KEEP"].value = beat.keep
            s["LAST"].value = beat.last
            await RisingEdge(self.clock)
            while not s["READY"].value:
                await RisingEdge(self.clock)


async def _start(dut):
    """Start the clock and give a DUT that has the port a short reset."""
    cocotb.start_soon(Clock(dut.CLK, 4, unit="ns").start())
    if hasattr(dut, "RESET"):
        dut.RESET.value = 1
        await ClockCycles(dut.CLK, 4)
        dut.RESET.value = 0
    await ClockCycles(dut.CLK, 4)


def _seeded_rng(dut, layout):
    dut._log.info(f"COCOTB_RANDOM_SEED {cocotb.RANDOM_SEED}, {layout}")
    return random.Random(cocotb.RANDOM_SEED)


def _scoreboard(dut, monitor, ready, p_low):
    """Scoreboard of ``monitor`` and its list of expected items, with random backpressure on ``ready``."""
    expected = []
    scoreboard = Scoreboard(dut)
    scoreboard.add_interface(monitor, expected)
    BitDriver(ready, dut.CLK).start(BackpressureGenerator(BackpressureConfig(1, 5, p_low)))
    return scoreboard, expected


async def _finish(dut, scoreboard, monitor, n, got, sent, busy=lambda: False):
    """Wait until ``monitor`` has seen ``n`` frames and ``busy()`` is over, then fail on a missing frame or a mismatch."""
    for _ in range(n * 400 + 1000):
        await RisingEdge(dut.CLK)
        if monitor.frame_cnt >= n and not busy():
            break
    await ClockCycles(dut.CLK, 10)
    assert monitor.frame_cnt == n, f"{monitor.frame_cnt} {got} of {n} {sent} received"
    raise scoreboard.result


async def run_cq_test(dut, layout, make_tlps, p_low, monitor):
    """Send ``make_tlps(rng)`` to ``CQ_AXI_*`` and compare it with what ``monitor``, a MFBMonitor with meta, sees on ``CQ_MFB_*``."""
    rng = _seeded_rng(dut, layout)
    dut.CQ_MFB_DST_RDY.value = 0
    await _start(dut)
    driver = UspCqDriver(dut, "CQ", dut.CLK, random.Random(rng.getrandbits(64)), p_idle=0.15)
    scoreboard, expected = _scoreboard(dut, monitor, dut.CQ_MFB_DST_RDY, p_low)

    tlps = make_tlps(rng)
    expected.extend(MfbTransactionWithMeta(data=tlp.frame(), meta=tlp.meta()) for tlp in tlps)
    driver.append(pack_cq(layout, tlps, rng))
    await _finish(dut, scoreboard, monitor, len(tlps), "frames", "TLPs", busy=lambda: bool(driver.beats))
