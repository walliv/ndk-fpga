# axi_mem_slave.py: AXI4 slave memory model with randomised timing and protocol checks
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

from collections import deque

import cocotb
from cocotb.triggers import RisingEdge, ReadOnly

from cocotbext.ofm.mfb.utils import signal_binstr


def init_byte(addr, salt):
    """Content of a byte nobody has written yet: a fixed hash of its address, shared with the
    reference model so reads of untouched memory are checkable too."""
    x = (addr * 0x9E3779B97F4A7C15 + salt) & 0xFFFFFFFFFFFFFFFF
    return (x >> 29) & 0xFF


class SparseMem:
    """Byte-addressed memory in 4 KB pages, created on first touch."""

    def __init__(self, salt):
        self.salt = salt
        self.pages = {}

    def _page(self, addr):
        base = addr & ~0xFFF
        page = self.pages.get(base)
        if page is None:
            page = bytearray(init_byte(base + i, self.salt) for i in range(4096))
            self.pages[base] = page
        return page

    def read(self, addr, n):
        out = bytearray()
        while n:
            page = self._page(addr)
            off = addr & 0xFFF
            k = min(n, 4096 - off)
            out += page[off:off + k]
            addr += k
            n -= k
        return bytes(out)

    def write_word(self, addr, data, strb, nbytes):
        page = self._page(addr)
        off = addr & 0xFFF
        for i in range(nbytes):
            if (strb >> i) & 1:
                page[off + i] = (data >> (8 * i)) & 0xFF


class AxiProtocolError(Exception):
    pass


class AxiMemSlave:
    """AXI4 slave with random ready/valid timing: writes commit after a random delay before B, reads
    sample memory after one. B/R keep per-ID order, may interleave across IDs; handshakes are
    checked against AXI4 and the burst limits. `cfg`: see Bar2AxiEnv."""

    _AW = ["AWID", "AWADDR", "AWLEN", "AWSIZE", "AWBURST", "AWLOCK", "AWCACHE", "AWPROT", "AWQOS"]
    _AR = ["ARID", "ARADDR", "ARLEN", "ARSIZE", "ARBURST", "ARLOCK", "ARCACHE", "ARPROT", "ARQOS"]

    def __init__(self, dut, clk, mem, rng, cfg, log, prefix="M_AXI"):
        self.dut = dut
        self.clk = clk
        self.mem = mem
        self.rng = rng
        self.cfg = dict(cfg)
        self.log = log
        self.s = {}
        for name in self._AW + self._AR + ["AWVALID", "AWREADY", "WDATA", "WSTRB", "WLAST", "WVALID",
                                           "WREADY", "BID", "BRESP", "BVALID", "BREADY", "ARVALID",
                                           "ARREADY", "RID", "RDATA", "RRESP", "RLAST", "RVALID",
                                           "RREADY"]:
            self.s[name] = getattr(dut, f"{prefix}_{name}")
        self.data_w = len(self.s["WDATA"])
        self.wb = self.data_w // 8
        self.size = self.wb.bit_length() - 1

        # callbacks set by the owner
        self.on_write_burst = None   # (aw, beats) -> opaque tag kept with the burst's B
        self.on_b = None             # (tag, resp)
        self.on_ar = None            # (ar)

        self.cycle = 0
        self._aw_q = deque()         # accepted AW waiting for their W burst
        self._w_beats = []           # W beats of the burst being collected
        self._w_bursts = deque()     # complete W bursts not yet paired with an AW
        self._commits = deque()      # (cycle, aw, beats) in AW order
        self._last_commit = 0
        self._b_q = {}               # id -> deque of [ready_cycle, resp, tag]
        self._r_q = {}               # id -> deque of dict(ready, ar, beats, idx, resp)
        self._cur_b = None
        self._cur_r = None

        self._prev = {}
        self.errors = []
        self.stats = dict(aw=0, w=0, b=0, ar=0, r=0, err_b=0, err_r=0, rready_low=0, bready_low=0,
                          max_w_outstanding=0, max_r_outstanding=0)
        self._r_outstanding = 0
        self._w_outstanding = 0
        self._task = None

    # ---------------------------------------------------------------------------------------------
    def start(self):
        for name in ["AWREADY", "WREADY", "ARREADY", "BVALID", "RVALID", "RLAST"]:
            self.s[name].value = 0
        for name in ["BID", "BRESP", "RID", "RDATA", "RRESP"]:
            self.s[name].value = 0
        self._task = cocotb.start_soon(self._run())

    def idle(self):
        return (not self._aw_q and not self._w_beats and not self._w_bursts and not self._commits
                and self._cur_b is None and self._cur_r is None
                and not any(self._b_q.values()) and not any(self._r_q.values()))

    def _err(self, msg):
        text = f"AXI slave cycle {self.cycle}: {msg}"
        self.errors.append(text)
        self.log.error(text)
        if len(self.errors) == 1:
            raise AxiProtocolError(text)

    def _chance(self, key):
        p = self.cfg[key]
        return p >= 1.0 or self.rng.random() < p

    def _lat(self, key):
        lo, hi = self.cfg[key]
        return self.rng.randint(lo, hi)

    @staticmethod
    def _data_x(handle, nbytes):
        """Value with unresolved bits read as 0, plus a mask of the bytes holding any of them."""
        b = signal_binstr(handle)
        try:
            return int(b, 2), 0
        except ValueError:
            pass
        xmask = 0
        for i in range(nbytes):
            byte = b[len(b) - 8 * (i + 1):len(b) - 8 * i]
            if byte.strip("01"):
                xmask |= 1 << i
        return int("".join(c if c in "01" else "0" for c in b), 2), xmask

    @staticmethod
    def _int(handle):
        b = signal_binstr(handle)
        try:
            return int(b, 2)
        except ValueError:
            return None

    # ---------------------------------------------------------------------------------------------
    def _check_burst(self, kind, a):
        if None in a.values():
            self._err(f"{kind} with undefined fields: {a}")
        if a["burst"] != 1:
            self._err(f"{kind} burst type {a['burst']} is not INCR")
        if a["size"] != self.size:
            self._err(f"{kind} AxSIZE {a['size']} is not the full width {self.size}")
        if a["addr"] % self.wb:
            self._err(f"{kind} address {a['addr']:#x} not aligned to the data width")
        if (a["addr"] & 0xFFF) + (a["len"] + 1) * self.wb > 4096:
            self._err(f"{kind} burst {a['addr']:#x}+{(a['len'] + 1) * self.wb} crosses 4 KB")
        if a["lock"] != 0:
            self._err(f"{kind} uses AxLOCK")
        if a["cache"] != self.cfg["axi_cache"]:
            self._err(f"{kind} AxCACHE {a['cache']:#x}, expected {self.cfg['axi_cache']:#x}")
        if a["len"] > 0 and a["size"] < 4 and not (a["cache"] & 0x2):
            self._err(f"{kind} narrow multi-beat burst without the modifiable AxCACHE bit")

    def _hold_check(self, chan, valid, ready, payload):
        prev = self._prev.get(chan)
        if prev is not None and prev[0] and not prev[1]:
            if not valid:
                self._err(f"{chan}VALID dropped before {chan}READY")
            elif payload != prev[2]:
                self._err(f"{chan} payload changed while {chan}VALID waited for {chan}READY")
        self._prev[chan] = (valid, ready, payload)

    def _sample(self):
        s = self.s
        aw_v = signal_binstr(s["AWVALID"]) == "1"
        aw_r = signal_binstr(s["AWREADY"]) == "1"
        aw = None
        if aw_v:
            aw = dict(id=self._int(s["AWID"]), addr=self._int(s["AWADDR"]), len=self._int(s["AWLEN"]),
                      size=self._int(s["AWSIZE"]), burst=self._int(s["AWBURST"]),
                      lock=self._int(s["AWLOCK"]), cache=self._int(s["AWCACHE"]),
                      prot=self._int(s["AWPROT"]), qos=self._int(s["AWQOS"]))
        self._hold_check("AW", aw_v, aw_r, None if aw is None else tuple(sorted(aw.items())))
        self._aw_hs = aw if (aw_v and aw_r) else None

        w_v = signal_binstr(s["WVALID"]) == "1"
        w_r = signal_binstr(s["WREADY"]) == "1"
        w = None
        if w_v:
            data, xmask = self._data_x(s["WDATA"], self.wb)
            strb = self._int(s["WSTRB"])
            if strb is None:
                self._err("WSTRB undefined while WVALID")
            elif xmask & strb:
                self._err(f"WDATA undefined in enabled byte lanes {xmask & strb:#x}")
            w = (data, strb, signal_binstr(s["WLAST"]) == "1")
        self._hold_check("W", w_v, w_r, w)
        self._w_hs = w if (w_v and w_r) else None

        ar_v = signal_binstr(s["ARVALID"]) == "1"
        ar_r = signal_binstr(s["ARREADY"]) == "1"
        ar = None
        if ar_v:
            ar = dict(id=self._int(s["ARID"]), addr=self._int(s["ARADDR"]), len=self._int(s["ARLEN"]),
                      size=self._int(s["ARSIZE"]), burst=self._int(s["ARBURST"]),
                      lock=self._int(s["ARLOCK"]), cache=self._int(s["ARCACHE"]),
                      prot=self._int(s["ARPROT"]), qos=self._int(s["ARQOS"]))
        self._hold_check("AR", ar_v, ar_r, None if ar is None else tuple(sorted(ar.items())))
        self._ar_hs = ar if (ar_v and ar_r) else None

        b_v = signal_binstr(s["BVALID"]) == "1"
        b_r = signal_binstr(s["BREADY"]) == "1"
        if b_v and not b_r:
            self.stats["bready_low"] += 1
        self._b_hs = b_v and b_r

        r_v = signal_binstr(s["RVALID"]) == "1"
        r_r = signal_binstr(s["RREADY"]) == "1"
        if r_v and not r_r:
            self.stats["rready_low"] += 1
        self._r_hs = r_v and r_r

    # ---------------------------------------------------------------------------------------------
    def _pair_writes(self):
        while self._aw_q and self._w_bursts:
            aw = self._aw_q.popleft()
            beats = self._w_bursts.popleft()
            if len(beats) != aw["len"] + 1:
                self._err(f"write burst {aw['addr']:#x}: {len(beats)} W beats with WLAST, AWLEN+1 = {aw['len'] + 1}")
            tag = self.on_write_burst(aw, beats) if self.on_write_burst else None
            when = max(self._last_commit, self.cycle + self._lat("commit_lat"))
            self._last_commit = when
            self._commits.append((when, aw, beats, tag))

    def _process_handshakes(self):
        if self._aw_hs is not None:
            aw = self._aw_hs
            self.stats["aw"] += 1
            self._check_burst("AW", aw)
            self._aw_q.append(aw)
            self._w_outstanding += 1
            self.stats["max_w_outstanding"] = max(self.stats["max_w_outstanding"], self._w_outstanding)
        if self._w_hs is not None:
            self.stats["w"] += 1
            data, strb, last = self._w_hs
            self._w_beats.append((data, strb))
            if last:
                self._w_bursts.append(self._w_beats)
                self._w_beats = []
            elif len(self._w_beats) > 256:
                self._err("W burst longer than 256 beats without WLAST")
        self._pair_writes()

        if self._ar_hs is not None:
            ar = self._ar_hs
            self.stats["ar"] += 1
            self._check_burst("AR", ar)
            if self.on_ar:
                self.on_ar(ar)
            q = self._r_q.setdefault(ar["id"], deque())
            resp = 2 if (self.cfg["err_prob"] and self.rng.random() < self.cfg["err_prob"]) else 0
            q.append(dict(ready=self.cycle + self._lat("r_lat"), ar=ar, data=None, idx=0, resp=resp))
            self._r_outstanding += 1
            self.stats["max_r_outstanding"] = max(self.stats["max_r_outstanding"], self._r_outstanding)

        if self._b_hs and self._cur_b is not None:
            bid, entry = self._cur_b
            self._b_q[bid].popleft()
            self._cur_b = None
            self.stats["b"] += 1
            self._w_outstanding -= 1
            if self.on_b:
                self.on_b(entry[2], entry[1])

        if self._r_hs and self._cur_r is not None:
            rid, entry = self._cur_r
            self._cur_r = None
            self.stats["r"] += 1
            if entry["resp"]:
                self.stats["err_r"] += 1
            entry["idx"] += 1
            if entry["idx"] == entry["ar"]["len"] + 1:
                self._r_q[rid].popleft()
                self._r_outstanding -= 1

    def _advance(self):
        while self._commits and self._commits[0][0] <= self.cycle:
            _, aw, beats, tag = self._commits.popleft()
            for k, (data, strb) in enumerate(beats):
                self.mem.write_word(aw["addr"] + k * self.wb, data, strb, self.wb)
            resp = 2 if (self.cfg["err_prob"] and self.rng.random() < self.cfg["err_prob"]) else 0
            if resp:
                self.stats["err_b"] += 1
            self._b_q.setdefault(aw["id"], deque()).append([self.cycle + self._lat("b_lat"), resp, tag])

    def _drive(self):
        s = self.s
        s["AWREADY"].value = int(self._chance("p_awready"))
        s["WREADY"].value = int(self._chance("p_wready"))
        s["ARREADY"].value = int(self._chance("p_arready"))

        if self._cur_b is None:
            ready = [bid for bid, q in self._b_q.items() if q and q[0][0] <= self.cycle]
            if ready and self._chance("p_bvalid"):
                bid = self.rng.choice(ready)
                self._cur_b = (bid, self._b_q[bid][0])
        if self._cur_b is not None:
            bid, entry = self._cur_b
            s["BVALID"].value = 1
            s["BID"].value = bid
            s["BRESP"].value = entry[1]
        else:
            s["BVALID"].value = 0

        if self._cur_r is None:
            ready = [rid for rid, q in self._r_q.items() if q and q[0]["ready"] <= self.cycle]
            if ready and self._chance("p_rvalid"):
                rid = self.rng.choice(ready)
                self._cur_r = (rid, self._r_q[rid][0])
        if self._cur_r is not None:
            rid, entry = self._cur_r
            ar = entry["ar"]
            if entry["data"] is None:
                # memory is sampled when the read executes, i.e. at its first data beat
                entry["data"] = self.mem.read(ar["addr"], (ar["len"] + 1) * self.wb)
            k = entry["idx"]
            s["RVALID"].value = 1
            s["RID"].value = rid
            s["RDATA"].value = int.from_bytes(entry["data"][k * self.wb:(k + 1) * self.wb], "little")
            s["RRESP"].value = entry["resp"]
            s["RLAST"].value = int(k == ar["len"])
        else:
            s["RVALID"].value = 0
            s["RLAST"].value = 0

    async def _run(self):
        clk_re = RisingEdge(self.clk)
        ro = ReadOnly()
        self._aw_hs = self._w_hs = self._ar_hs = None
        self._b_hs = self._r_hs = False
        while True:
            await clk_re
            self.cycle += 1
            self._process_handshakes()
            self._advance()
            self._drive()
            await ro
            self._sample()
