# bar2axi_env.py: Testbench environment for PCIE_BAR2AXI (stimulus, reference model, scoreboard)
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import os
import time
import random
from collections import deque, Counter

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, ClockCycles

from cocotb_bus.scoreboard import Scoreboard
from cocotbext.ofm.mfb.drivers import MFBDriver
from cocotbext.ofm.mfb.monitors import MFBMonitor
from cocotbext.ofm.mfb.properties import MFBProperty, final_check_all
from cocotbext.ofm.mfb.transaction import MfbTransaction, MfbTransactionWithMeta
from cocotbext.ofm.mfb.utils import signal_binstr
from cocotbext.ofm.pcie.PcieHeaders import CQHeader, CCHeader, CQMfbMeta
from cocotbext.ofm.pcie import PcieReqType, pcie_byte_count

from axi_mem_slave import AxiMemSlave, SparseMem, init_byte


# Defaults of the PCIE_BAR2AXI generics the Makefile does not override; they must match the RTL.
AXI_BASE_ADDR = 0x0000_0040_0000_0000
AXI_CACHE = 0b0010

POSTED_TYPES = {0b0001, 0b1100, 0b1101, 0b1110, 0b1111}
READ_CPL_TYPES = {0b0000, 0b0111}


class TbError(Exception):
    pass


def env_int(name, default):
    return int(os.environ.get(name, default))


class TbConfig:
    def __init__(self, dut):
        self.regions = len(dut.CQ_MFB_SOF)
        self.axi_dw = len(dut.M_AXI_WDATA)
        self.wb = self.axi_dw // 8
        self.bar_id = env_int("TB_BAR_ID", 0)
        self.func_id = env_int("TB_FUNC_ID", 1)
        self.aperture = env_int("TB_BAR_APERTURE", 30)
        self.rd_outstanding = env_int("TB_RD_OUTSTANDING", 8)
        self.max_wr = env_int("TB_MAX_WR_BYTES", 1024)
        self.max_rd = env_int("TB_MAX_RD_BYTES", 4096)
        self.axi_base = AXI_BASE_ADDR

    def axi_addr(self, pcie_addr):
        return self.axi_base + (pcie_addr % (1 << self.aperture))

    def __str__(self):
        return (f"MFB_REGIONS={self.regions} AXI_DATA_WIDTH={self.axi_dw} BAR_ID={self.bar_id} "
                f"FUNC_ID={self.func_id} BAR_APERTURE={self.aperture} MAX_WR={self.max_wr} "
                f"MAX_RD={self.max_rd} RD_OUTSTANDING={self.rd_outstanding}")


# =================================================================================================
# Reference memory
# =================================================================================================
class RefMem:
    # Per-byte write history: PCIe lets posted writes pass a waiting read, so a read may return the
    # value of its CQ position or of any later write.
    def __init__(self, salt):
        self.salt = salt
        self.hist = {}

    def write(self, addr, val, seq):
        self.hist.setdefault(addr, []).append((seq, val))

    def check(self, addr, val, seq):
        """'exact' if val is the value the byte had at seq, 'relaxed' if a later write produced it,
        None if neither."""
        h = self.hist.get(addr)
        exp = init_byte(addr, self.salt)
        later = None
        if h:
            for s, v in h:
                if s < seq:
                    exp = v
                elif v == val:
                    later = True
        if val == exp:
            return "exact"
        if later:
            return "relaxed"
        return None

    def expected(self, addr, seq):
        exp = init_byte(addr, self.salt)
        for s, v in self.hist.get(addr, ()):
            if s < seq:
                exp = v
        return exp


# =================================================================================================
# Reference model and scoreboard
# =================================================================================================
class Bar2AxiModel:
    """Derives from each monitored CQ TLP the exact AXI write bytes, an AXI read issued only after
    all earlier writes got B, and the completions in request order; AXI slave and CC monitor
    report what the DUT did, any difference raises TbError."""

    def __init__(self, cfg, log, salt):
        self.cfg = cfg
        self.log = log
        self.ref = RefMem(salt)
        self.seq = 0
        self.exp_wr = deque()      # expected AXI write TLPs
        self.exp_rd = deque()      # expected AXI reads
        self.exp_cpl = deque()     # expected completion groups, in request order
        self.cur_rd = None
        self.wr_accepted = 0
        self.wr_b_done = 0
        self.cnt = Counter()       # wr, rd, ur, drop: what the DUT counters must show
        self.cov = Counter()
        self.errors = []

    def _fail(self, msg):
        self.errors.append(msg)
        self.log.error(msg)
        raise TbError(msg)

    # ---------------------------------------------------------------------------------------------
    # CQ input
    # ---------------------------------------------------------------------------------------------
    def on_cq_tlp(self, tr):
        data = tr.data
        hdr = CQHeader.deserialize(int.from_bytes(data[:16], "little"))
        meta = CQMfbMeta.deserialize(tr.meta)
        fbe, lbe = meta.firstBe, meta.lastBe
        payload = data[16:]
        self.seq += 1
        seq = self.seq
        rtype = hdr.req_type
        dw = hdr.dword_count
        pcie_addr = hdr.addr << 2
        bar_ok = hdr.bar_id == self.cfg.bar_id and hdr.tgt_func == self.cfg.func_id

        if rtype == PcieReqType.MWR and bar_ok and 1 <= dw <= self.cfg.max_wr // 4:
            self._accept_write(seq, hdr, fbe, lbe, payload, pcie_addr, dw)
        elif rtype == PcieReqType.MRD and bar_ok and 1 <= dw <= self.cfg.max_rd // 4:
            self._accept_read(seq, hdr, fbe, lbe, pcie_addr, dw)
        elif rtype in POSTED_TYPES:
            self.cnt["drop"] += 1
            self.cov["drop"] += 1
        else:
            self._accept_ur(seq, hdr, fbe, lbe, pcie_addr, dw)

    def _accept_write(self, seq, hdr, fbe, lbe, payload, pcie_addr, dw):
        if len(payload) != 4 * dw:
            self._fail(f"CQ MemWr seq {seq}: payload {len(payload)} B for {dw} DW (stimulus error)")
        axi = self.cfg.axi_addr(pcie_addr)
        wb = self.cfg.wb
        bytes_en = {}
        for j in range(dw):
            be = fbe if j == 0 else (lbe if j == dw - 1 else 0xF)
            for b in range(4):
                if (be >> b) & 1:
                    a = axi + 4 * j + b
                    bytes_en[a] = payload[4 * j + b]
                    self.ref.write(a, payload[4 * j + b], seq)
        start = axi - axi % wb
        end = axi + 4 * dw
        end += (-end) % wb
        self.exp_wr.append(dict(seq=seq, next=start, end=end, bytes=bytes_en))
        self.wr_accepted += 1
        self.cnt["wr"] += 1
        if 4 * dw == self.cfg.max_wr:
            self.cov["max_write"] += 1
        if dw == 1 and fbe == 0:
            self.cov["zero_len_write"] += 1
        if (axi & 0xFFF) + 4 * dw == 4096:
            self.cov["write_to_page_end"] += 1
        if (pcie_addr % (1 << self.cfg.aperture)) + 4 * dw == (1 << self.cfg.aperture):
            self.cov["write_to_bar_end"] += 1

    def _cpl_common(self, hdr):
        return dict(tag=hdr.tag, rid=hdr.req_id, cid=hdr.tgt_func, tc=hdr.tc, attr=hdr.attr, at=hdr.at)

    @staticmethod
    def _la_low(fbe):
        for i in range(4):
            if (fbe >> i) & 1:
                return i
        return 0

    def _accept_read(self, seq, hdr, fbe, lbe, pcie_addr, dw):
        axi = self.cfg.axi_addr(pcie_addr)
        a0 = (pcie_addr >> 2) & 31
        nch = ((a0 + dw - 1) >> 5) + 1
        bc = pcie_byte_count(dw, fbe, lbe)
        la = (pcie_addr & 0x7C) | self._la_low(fbe)
        end_off = la + bc
        chunk0 = axi & ~127
        segs = []
        for s in range(nch):
            lo = a0 if s == 0 else 0
            hi = ((a0 + dw - 1) & 31) + 1 if s == nch - 1 else 32
            segs.append(dict(status=0, dw=hi - lo, bc=bc if s == 0 else end_off - 128 * s,
                             la=la if s == 0 else 0, addr=chunk0 + 128 * s + 4 * lo))
        zero_len = dw == 1 and fbe == 0
        self.exp_cpl.append(dict(kind="rd", seq=seq, segs=segs, idx=0, zero_len=zero_len,
                                 common=self._cpl_common(hdr), dw=dw))
        self.exp_rd.append(dict(seq=seq, start=axi, end=axi + 4 * dw, wr_before=self.wr_accepted,
                                next=None))
        self.cnt["rd"] += 1

    def _accept_ur(self, seq, hdr, fbe, lbe, pcie_addr, dw):
        if hdr.req_type in READ_CPL_TYPES:
            bc = pcie_byte_count(dw, fbe, lbe)
            la = (pcie_addr & 0x7C) | self._la_low(fbe)
        else:
            bc, la = 4, 0
        segs = [dict(status=1, dw=0, bc=bc, la=la, addr=None)]
        self.exp_cpl.append(dict(kind="ur", seq=seq, segs=segs, idx=0, zero_len=False,
                                 common=self._cpl_common(hdr), dw=dw))
        self.cnt["ur"] += 1

    # ---------------------------------------------------------------------------------------------
    # AXI side
    # ---------------------------------------------------------------------------------------------
    def on_axi_write(self, aw, beats):
        if not self.exp_wr:
            self._fail(f"unexpected AXI write burst at {aw['addr']:#x}")
        t = self.exp_wr[0]
        wb = self.cfg.wb
        if aw["addr"] != t["next"]:
            self._fail(f"AXI write burst at {aw['addr']:#x}, expected {t['next']:#x} (MemWr seq {t['seq']})")
        for k, (data, strb) in enumerate(beats):
            word = aw["addr"] + k * wb
            for b in range(wb):
                a = word + b
                exp_en = a in t["bytes"]
                got_en = bool((strb >> b) & 1)
                if exp_en != got_en:
                    self._fail(f"MemWr seq {t['seq']}: WSTRB of byte {a:#x} is {int(got_en)}, expected {int(exp_en)}")
                if got_en and ((data >> (8 * b)) & 0xFF) != t["bytes"][a]:
                    self._fail(f"MemWr seq {t['seq']}: WDATA byte {a:#x} = {(data >> (8 * b)) & 0xFF:#04x}, "
                               f"expected {t['bytes'][a]:#04x}")
        t["next"] += len(beats) * wb
        if t["next"] > t["end"]:
            self._fail(f"MemWr seq {t['seq']}: AXI write runs past the payload end {t['end']:#x}")
        if t["next"] == t["end"]:
            self.exp_wr.popleft()
            return True
        return False

    def on_axi_b(self, ends_tlp, resp):
        if ends_tlp:
            self.wr_b_done += 1

    def on_axi_ar(self, ar):
        wb = self.cfg.wb
        nbytes = (ar["len"] + 1) * wb
        if self.cur_rd is None:
            if not self.exp_rd:
                self._fail(f"unexpected AXI read at {ar['addr']:#x}")
            r = self.exp_rd.popleft()
            if self.wr_b_done < r["wr_before"]:
                self._fail(f"MemRd seq {r['seq']} issued to AXI after {self.wr_b_done} write B responses, "
                           f"but {r['wr_before']} writes preceded it")
            if not (r["start"] & ~127) <= ar["addr"] <= r["start"]:
                self._fail(f"MemRd seq {r['seq']}: first AR at {ar['addr']:#x} for data at {r['start']:#x}")
            r["next"] = ar["addr"] + nbytes
            self.cur_rd = r
        else:
            r = self.cur_rd
            if ar["addr"] != r["next"]:
                self._fail(f"MemRd seq {r['seq']}: AR at {ar['addr']:#x}, expected {r['next']:#x}")
            r["next"] += nbytes
        if r["next"] >= r["end"]:
            if r["next"] > ((r["end"] + 127) & ~127):
                self._fail(f"MemRd seq {r['seq']}: AXI reads beyond the request's last 128 B chunk")
            self.cur_rd = None
        self.cov["ar_bursts"] += 1

    # ---------------------------------------------------------------------------------------------
    # CC output
    # ---------------------------------------------------------------------------------------------
    def on_cc_tlp(self, tr):
        data = tr.data if isinstance(tr, MfbTransaction) else tr
        if len(data) < 12:
            self._fail(f"CC TLP of {len(data)} B is shorter than its descriptor")
        hdr = CCHeader.deserialize(int.from_bytes(data[:12], "little"))
        payload = data[12:]
        if not self.exp_cpl:
            self._fail(f"unexpected completion tag {hdr.tag:#x}")
        g = self.exp_cpl[0]
        seg = g["segs"][g["idx"]]
        c = g["common"]
        what = f"completion {g['idx']}/{len(g['segs'])} of {g['kind']} seq {g['seq']}"
        checks = [("tag", hdr.tag, c["tag"]), ("requester ID", hdr.rid, c["rid"]),
                  ("completer ID", hdr.cid, c["cid"]), ("completer ID enable", hdr.cid_en, 0),
                  ("TC", hdr.tc, c["tc"]), ("attributes", hdr.attr, c["attr"]),
                  ("address type", hdr.at, c["at"]), ("status", hdr.completion_status, seg["status"]),
                  ("DW count", hdr.dword_count, seg["dw"]), ("byte count", hdr.byte_count, seg["bc"]),
                  ("lower address", hdr.lower_address, seg["la"]), ("poisoned", hdr.poisoned, 0),
                  ("locked", hdr.lrc, 0), ("payload bytes", len(payload), 4 * seg["dw"])]
        for name, got, exp in checks:
            if got != exp:
                self._fail(f"{what}: {name} = {got:#x}, expected {exp:#x}")
        if seg["dw"]:
            if seg["dw"] > 32 or (seg["addr"] & 127) + 4 * seg["dw"] > 128:
                self._fail(f"{what}: segment not within one 128 B chunk")
        if g["kind"] == "rd" and not g["zero_len"]:
            for i, v in enumerate(payload):
                res = self.ref.check(seg["addr"] + i, v, g["seq"])
                if res is None:
                    exp = self.ref.expected(seg["addr"] + i, g["seq"])
                    self._fail(f"{what}: data byte {seg['addr'] + i:#x} = {v:#04x}, expected {exp:#04x}")
                if res == "relaxed":
                    self.cov["relaxed_bytes"] += 1
        g["idx"] += 1
        if g["idx"] == len(g["segs"]):
            self.exp_cpl.popleft()
            if g["kind"] == "ur":
                self.cov["ur"] += 1
            else:
                self.cov["reads_done"] += 1
                if len(g["segs"]) >= 32:
                    self.cov["read_32_cpl"] += 1
                if g["zero_len"]:
                    self.cov["zero_len_read"] += 1
                if g["dw"] * 4 == self.cfg.max_rd:
                    self.cov["max_read"] += 1
        self.cov["cpl_tlps"] += 1

    def idle(self):
        return not self.exp_wr and not self.exp_rd and not self.exp_cpl and self.cur_rd is None


# =================================================================================================
# Stimulus
# =================================================================================================
class TlpGen:
    """Builds Xilinx-format CQ TLPs (16 B descriptor + payload) with their CQ META."""

    def __init__(self, cfg, rng):
        self.cfg = cfg
        self.rng = rng
        # host address the BAR is mapped at, aligned to its size; bits above the aperture are random
        self.bar_base = rng.getrandbits(64 - cfg.aperture) << cfg.aperture
        self.tag = rng.randrange(256)

    def _next_tag(self):
        self.tag = (self.tag + 1) & 0xFF
        return self.tag

    def frame(self, rtype, offset, dw, fbe, lbe, payload=b"", bar=None, func=None, at=0, tc=None,
              attr=None, tag=None):
        h = CQHeader()
        h.at = at
        h.addr = ((self.bar_base + offset) & ((1 << 64) - 1)) >> 2
        h.dword_count = dw
        h.req_type = rtype
        h.req_id = self.rng.getrandbits(16)
        h.tag = self._next_tag() if tag is None else tag
        h.tgt_func = self.cfg.func_id if func is None else func
        h.bar_id = self.cfg.bar_id if bar is None else bar
        h.bar_apper = self.cfg.aperture
        h.tc = self.rng.randrange(8) if tc is None else tc
        h.attr = self.rng.randrange(8) if attr is None else attr
        m = CQMfbMeta()
        m.firstBe = fbe
        m.lastBe = lbe
        data = h.serialize().to_bytes(16, "little") + bytes(payload)
        return MfbTransactionWithMeta(data=data, meta=m.serialize())

    def bes(self, offset, dw, allow_zero=True):
        """Byte enables PCIe allows for a request of dw DWs at offset."""
        r = self.rng
        if dw == 1:
            fbe = r.randrange(16) if allow_zero else r.randrange(1, 16)
            return fbe, 0
        if dw == 2 and offset % 8 == 0 and r.random() < 0.5:
            return r.randrange(1, 16), r.randrange(1, 16)
        return r.choice([0xF, 0xF, 0xE, 0xC, 0x8]), r.choice([0xF, 0xF, 0x7, 0x3, 0x1])

    def mem_wr(self, offset, dw, fbe=None, lbe=None, **kw):
        if fbe is None:
            fbe, lbe = self.bes(offset, dw)
        payload = self.rng.randbytes(4 * dw)
        return self.frame(PcieReqType.MWR, offset, dw, fbe, lbe, payload, **kw)

    def mem_rd(self, offset, dw, fbe=None, lbe=None, **kw):
        if fbe is None:
            fbe, lbe = self.bes(offset, dw)
        return self.frame(PcieReqType.MRD, offset, dw, fbe, lbe, **kw)

    def unsupported(self):
        """A random request of a type the DUT does not serve, with the payload its type carries."""
        r = self.rng
        off = r.randrange(0, 1 << self.cfg.aperture, 8)
        kind = r.choice(["iord", "iowr", "fetchadd", "swap", "cas", "mrdlk", "msg", "vdm", "ats"])
        if kind == "iord":
            return self.frame(PcieReqType.IORD, off, 1, r.randrange(1, 16), 0)
        if kind == "iowr":
            return self.frame(PcieReqType.IOWR, off, 1, r.randrange(1, 16), 0, r.randbytes(4))
        if kind in ("fetchadd", "swap"):
            dw = r.choice([1, 2])
            t = PcieReqType.MFETCH_AND_ADD if kind == "fetchadd" else PcieReqType.MSWAP
            return self.frame(t, off, dw, 0xF, 0xF if dw > 1 else 0, r.randbytes(4 * dw))
        if kind == "cas":
            dw = r.choice([2, 4, 8])
            return self.frame(PcieReqType.MCOMPARE_SWAP, off, dw, 0xF, 0xF, r.randbytes(4 * dw))
        if kind == "mrdlk":
            dw = r.randrange(1, 17)
            fbe, lbe = self.bes(off, dw, allow_zero=False)
            return self.frame(PcieReqType.LOC_RD, off, dw, fbe, lbe)
        if kind == "msg":
            return self.frame(PcieReqType.ANY_MSG, 0, 0, 0, 0)
        if kind == "vdm":
            dw = r.randrange(1, 5)
            return self.frame(PcieReqType.VENDOR_MSG, 0, dw, 0, 0, r.randbytes(4 * dw))
        return self.frame(PcieReqType.ATS_MSG, 0, 0, 0, 0)


class AddrPicker:
    """DW-aligned BAR offsets for requests that respect the 4 KB rule, biased to corner cases."""

    def __init__(self, cfg, rng, hot_base=None, hot_size=None):
        self.cfg = cfg
        self.rng = rng
        self.size = 1 << cfg.aperture
        self.hot_size = hot_size or 65536
        self.hot_base = hot_base if hot_base is not None else rng.randrange(0, self.size - self.hot_size, 4096)
        self.recent = deque(maxlen=64)

    def pick(self, nbytes, mode=None):
        r = self.rng
        if mode is None:
            mode = r.choices(["hot", "any", "page_end", "chunk_edge", "bar_end", "recent"],
                             [40, 10, 10, 15, 5, 20])[0]
        if mode == "recent" and self.recent:
            base, n = r.choice(list(self.recent))
            off = base + r.randrange(0, max(1, n), 4) - r.randrange(0, 256, 4)
        elif mode == "page_end":
            page = r.randrange(0, self.size, 4096)
            off = page + 4096 - nbytes - r.choice([0, 0, 4, 64, 128])
        elif mode == "chunk_edge":
            off = self.hot_base + r.randrange(0, self.hot_size, 128) + r.choice([-8, -4, 0, 4, 120, 124])
        elif mode == "bar_end":
            off = self.size - nbytes - r.choice([0, 0, 4, 128, 256])
        elif mode == "any":
            off = r.randrange(0, self.size, 4)
        else:
            off = self.hot_base + r.randrange(0, self.hot_size, 4)
        off = max(0, min(off, self.size - nbytes)) & ~3
        # stay inside one 4 KB page
        if (off & 0xFFF) + nbytes > 4096:
            off = (off & ~0xFFF) + 4096 - nbytes
        return off

    def note(self, off, nbytes):
        self.recent.append((off, nbytes))


# =================================================================================================
# Environment
# =================================================================================================
def rand_gaps(rng, on=(1, 24), off=(0, 4), long_off=0.03):
    while True:
        o = rng.randint(*off)
        if rng.random() < long_off:
            o += rng.randint(8, 40)
        yield (rng.randint(*on), o)


class Bar2AxiEnv:
    def __init__(self, dut, name, wall_limit_s=540.0, axi_cfg=None, cc_rdy=0.7, cq_gaps=True,
                 seed=None):
        self.dut = dut
        self.log = dut._log
        self.cfg = TbConfig(dut)
        self.seed = seed if seed is not None else random.getrandbits(32)
        self.rng = random.Random(self.seed)
        self.salt = self.rng.getrandbits(32)
        self.name = name
        self.t0 = time.monotonic()
        self.wall_limit_s = wall_limit_s
        self.log.info(f"[{name}] {self.cfg}; TB seed {self.seed}")

        self.axi_cfg = dict(p_awready=0.6, p_wready=0.7, p_arready=0.6, p_bvalid=0.6, p_rvalid=0.7,
                            commit_lat=(0, 30), b_lat=(0, 10), r_lat=(2, 60), err_prob=0.0,
                            axi_cache=AXI_CACHE)
        if axi_cfg:
            self.axi_cfg.update(axi_cfg)
        self.cc_rdy = cc_rdy
        self.cc_hold = False
        self.cq_gaps = cq_gaps

        self.model = Bar2AxiModel(self.cfg, self.log, self.salt)
        self.gen = TlpGen(self.cfg, self.rng)
        self.mem = SparseMem(self.salt)
        self.cov = self.model.cov

    async def start(self):
        dut = self.dut
        cocotb.start_soon(Clock(dut.CLK, 4, unit="ns").start())
        dut.RESET.value = 1
        dut.CC_MFB_DST_RDY.value = 0
        vld = rand_gaps(self.rng) if self.cq_gaps else None
        self.cq_drv = MFBDriver(dut, "CQ_MFB", dut.CLK, vld_gen=vld)
        self.cq_mon = MFBMonitor(dut, "CQ_MFB", dut.CLK, trans_type=MfbTransactionWithMeta)
        self.cc_mon = MFBMonitor(dut, "CC_MFB", dut.CLK)
        self.cq_mon.add_callback(self._on_cq_frame)
        # the model owns the expected completions and compares each CC TLP field by field
        self.sb = Scoreboard(dut, fail_immediately=True)
        self.sb.add_interface(self.cc_mon, self.model.exp_cpl, compare_fn=self.model.on_cc_tlp)
        self.axi = AxiMemSlave(dut, dut.CLK, self.mem, random.Random(self.rng.getrandbits(32)),
                               self.axi_cfg, self.log)
        self.axi.on_write_burst = self.model.on_axi_write
        self.axi.on_b = self.model.on_axi_b
        self.axi.on_ar = self.model.on_axi_ar
        self.axi.start()
        await ClockCycles(dut.CLK, 10)
        dut.RESET.value = 0
        await ClockCycles(dut.CLK, 5)
        self.props = {
            "CQ_MFB": MFBProperty(dut, "CQ_MFB", dut.CLK, reset=dut.RESET, straddling=None),
            "CC_MFB": MFBProperty(dut, "CC_MFB", dut.CLK, reset=dut.RESET, straddling=False),
        }
        self.cc_rdy_rng = random.Random(self.rng.getrandbits(32))
        cocotb.start_soon(self._cc_ready())
        cocotb.start_soon(self._samplers())

    async def _cc_ready(self):
        clk_re = RisingEdge(self.dut.CLK)
        sig = self.dut.CC_MFB_DST_RDY
        r = self.cc_rdy_rng
        while True:
            await clk_re
            if self.cc_hold:
                sig.value = 0
            else:
                sig.value = int(self.cc_rdy >= 1.0 or r.random() < self.cc_rdy)

    async def _samplers(self):
        dut = self.dut
        all_sof = "1" * self.cfg.regions
        clk_re = RisingEdge(dut.CLK)
        ro = ReadOnly()
        while True:
            await clk_re
            await ro
            if signal_binstr(dut.CQ_MFB_SRC_RDY) == "1" and signal_binstr(dut.CQ_MFB_DST_RDY) == "1":
                if signal_binstr(dut.CQ_MFB_SOF) == all_sof:
                    self.cov["cq_word_all_sof"] += 1
            if signal_binstr(dut.CC_MFB_SRC_RDY) == "1" and signal_binstr(dut.CC_MFB_DST_RDY) == "0":
                self.cov["cc_stall_cycles"] += 1
            if signal_binstr(dut.CQ_MFB_SRC_RDY) == "1" and signal_binstr(dut.CQ_MFB_DST_RDY) == "0":
                self.cov["cq_stall_cycles"] += 1

    def wall_check(self):
        el = time.monotonic() - self.t0
        if el > self.wall_limit_s:
            raise TbError(f"[{self.name}] wall-clock watchdog: {el:.0f} s > {self.wall_limit_s:.0f} s")

    # DUT internals dumped when the bench stops making progress
    _PROBES = ["ist", "np_out_cnt", "wr_out_cnt", "st_rdy", "in_src_rdy", "in_dst_rdy",
               "wr_i.est", "wr_i.h_rdy", "wr_i.h_fill", "wr_i.bf_cnt", "wr_i.awvalid_r", "wr_i.wvalid_r",
               "rd_i.rst", "rd_i.rq_cnt", "rd_i.head_pend", "rd_i.head_ur", "rd_i.can_alloc",
               "rd_i.cpl_full", "rd_i.alloc_ptr", "rd_i.r_word_cnt", "rd_i.arvalid_r",
               "cc_i.cst", "cc_i.c_ptr", "cc_i.c_seg", "cc_i.w_idx", "cc_i.eof_word"]

    def _progress(self):
        st = self.axi.stats
        return (self.cq_mon.frame_cnt, st["aw"], st["w"], st["b"], st["ar"], st["r"],
                self.model.cov["cpl_tlps"])

    def dump_state(self):
        vals = []
        for path in self._PROBES:
            h = self.dut
            try:
                for part in path.split("."):
                    h = getattr(h, part)
                vals.append(f"{path}={h.value}")
            except Exception as exc:
                vals.append(f"{path}=<{type(exc).__name__}>")
        self.log.error(f"[{self.name}] DUT state: " + ", ".join(vals))
        self.log.error(f"[{self.name}] model: wr pending {len(self.model.exp_wr)}, rd pending "
                       f"{len(self.model.exp_rd)}, cpl pending {len(self.model.exp_cpl)}, accepted writes "
                       f"{self.model.wr_accepted}, B done {self.model.wr_b_done}; AXI {self.axi.stats}")

    def stall_check(self, n_cycles):
        prog = self._progress()
        if prog != getattr(self, "_last_prog", None):
            self._last_prog = prog
            self._stall = 0
            return
        self._stall = getattr(self, "_stall", 0) + n_cycles
        if self._stall > 30000:
            self.dump_state()
            raise TbError(f"[{self.name}] no progress for {self._stall} cycles")

    def _on_cq_frame(self, tr):
        # the driver must put on the wire exactly what was queued, in order
        exp = self.sent_q.popleft() if self.sent_q else None
        if exp is None or exp.data != tr.data or exp.meta != tr.meta:
            raise TbError(f"[{self.name}] CQ frame {self.cq_mon.frame_cnt} differs from the one sent")
        self.model.on_cq_tlp(tr)

    def send(self, tr, note=None):
        if not hasattr(self, "sent_q"):
            self.sent_q = deque()
        self.sent_q.append(tr)
        self.cq_drv.append(tr)
        self.sent = getattr(self, "sent", 0) + 1

    async def wait_queue(self, max_pending=8):
        """Throttle the stimulus so the driver queue stays short (keeps tags and history bounded)."""
        while len(self.cq_drv._sendQ) > max_pending:
            await ClockCycles(self.dut.CLK, 8)
            self.wall_check()
            self.stall_check(8)

    async def drain(self, max_cycles=400000):
        """Wait until everything sent was seen at the CQ input and fully answered."""
        n = 0
        while True:
            await ClockCycles(self.dut.CLK, 16)
            n += 16
            self.wall_check()
            self.stall_check(16)
            if (not self.cq_drv._sendQ and self.cq_mon.frame_cnt == getattr(self, "sent", 0)
                    and self.model.idle() and self.axi.idle()):
                break
            if n > max_cycles:
                raise TbError(f"[{self.name}] drain timeout: sent {getattr(self, 'sent', 0)}, "
                              f"CQ seen {self.cq_mon.frame_cnt}, pending wr {len(self.model.exp_wr)}, "
                              f"rd {len(self.model.exp_rd)}, cpl {len(self.model.exp_cpl)}, "
                              f"AXI idle {self.axi.idle()}")
        await ClockCycles(self.dut.CLK, 20)

    def check_counters(self):
        dut = self.dut
        got = dict(wr=int(dut.CNT_WR.value), rd=int(dut.CNT_RD.value), ur=int(dut.CNT_UR.value),
                   drop=int(dut.CNT_DROP.value), err=int(dut.CNT_ERR.value))
        exp = dict(wr=self.model.cnt["wr"], rd=self.model.cnt["rd"], ur=self.model.cnt["ur"],
                   drop=self.model.cnt["drop"],
                   err=self.axi.stats["err_b"] + self.axi.stats["err_r"])
        if got != exp:
            raise TbError(f"[{self.name}] status counters {got}, expected {exp}")
        return got

    def finish(self, required=()):
        if self.model.errors or self.axi.errors:
            raise TbError(f"[{self.name}] errors: {self.model.errors[:3]} {self.axi.errors[:3]}")
        final_check_all(self.props)
        if self.axi.stats["rready_low"] or self.axi.stats["bready_low"]:
            raise TbError(f"[{self.name}] DUT held RREADY/BREADY low while valid: "
                          f"{self.axi.stats['rready_low']}/{self.axi.stats['bready_low']} cycles")
        cnts = self.check_counters()
        missing = [c for c in required if self.cov[c] == 0]
        el = time.monotonic() - self.t0
        self.log.info(f"[{self.name}] seed {self.seed}: {getattr(self, 'sent', 0)} TLPs, counters {cnts}, "
                      f"AXI {self.axi.stats}, wall {el:.1f} s")
        self.log.info(f"[{self.name}] coverage: {dict(sorted(self.cov.items()))}")
        if missing:
            raise TbError(f"[{self.name}] corner cases never reached: {missing}")
