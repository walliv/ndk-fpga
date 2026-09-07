#!/usr/bin/env python3
# iuventus_groupby.py: control script for the FPGA-resident GROUP BY user core
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0
"""Drive the GROUP BY user core over ``nfb``.

The core reads 16 B ``{key, value}`` records from the SSDs behind DMA Iuventus, sums the values per
key on chip and writes the dense result table back to a drive. The host never sees a record: this
script programs a run, polls it, and reads back what the core itself counted.

Every rate here comes from the core's own event counter -- ``eps_from_windows()`` turns the windows
``wait_done`` sampled during a run into a median records/s figure. A host sleep is only ever a
settle delay and never a divisor.
"""
import argparse
import fcntl
import json
import os
import statistics
import sys
from datetime import datetime
from enum import IntEnum
from time import monotonic, sleep

import numpy as np
import nfb

from ofm.comp.dma.iuventus.iuventus_reg_access import DMAIuventusRegAccess


# Held open for the process lifetime: closing the file releases the lock.
_device_lock_fh = None

# Deliberately the same file iuventus_rw_test.py takes. Both CLIs drive one DMA and one set of
# counters, so they must contend for the same lock rather than for one lock each.
DEVICE_LOCK_TEMPLATE = "iuventus_rw_test.{tag}.lock"


def acquire_device_lock(device) -> None:
    """Refuse to start if another instance is already driving this device.

    Two of these at once share one DMA and one set of counters, so each overwrites the other's
    stimulus mid-run and both read totals containing the other's traffic. It does not look like a
    tooling fault -- it surfaces as an impossible record count or a run that never finishes -- so
    it is worth failing loudly instead.

    flock is released by the kernel on process exit, including SIGKILL, so a stale lock file can
    never block a later run.
    """
    global _device_lock_fh

    tag = "".join(c if c.isalnum() else "_" for c in str(device))
    path = os.path.join("/tmp", DEVICE_LOCK_TEMPLATE.format(tag=tag))
    try:
        fh = open(path, "a+")
    except OSError as exc:
        raise SystemExit(f"ERROR: cannot open device lock {path}: {exc}")

    try:
        fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        fh.seek(0)
        owner = fh.read().strip() or "unknown"
        fh.close()
        raise SystemExit(
            f"ERROR: another instance is already driving device '{device}' (pid {owner}).\n"
            f"       Lock: {path}\n"
            "       Two instances corrupt each other's measurements -- wait for it to finish, or\n"
            "       stop it with SIGINT (never SIGKILL while fzc is running)."
        )

    fh.seek(0)
    fh.truncate()
    fh.write(str(os.getpid()))
    fh.flush()
    _device_lock_fh = fh


# =================================================================================================
# Register map of the "ziti,iuventus_groupby" node
# =================================================================================================

class GroupByRegMap(IntEnum):
    """Byte offsets into the GROUP BY node. Every register is 32 bits wide."""
    CTRL              = 0x00
    IN_LBA_L          = 0x04
    IN_LBA_H          = 0x08
    IN_COUNT          = 0x0C
    OUT_LBA_L         = 0x10
    OUT_LBA_H         = 0x14
    OUT_QID           = 0x18
    QID_MASK          = 0x1C
    STATUS            = 0x20
    REC_CNT_L         = 0x24
    REC_CNT_H         = 0x28
    OOR_CNT           = 0x2C
    RESULT_SECT       = 0x30
    NUM_GROUPS        = 0x34
    LBA_NUM           = 0x38
    ISSUED_CNT        = 0x3C
    COMPL_CNT         = 0x40
    WR_ISSUED         = 0x44
    WR_COMPL          = 0x48
    ERR_INFO          = 0x4C
    LANE_DRAIN        = 0x50
    STALL_NOQ         = 0x54
    STALL_DMA         = 0x58
    STALL_WB          = 0x5C
    EVCR_INTERVAL     = 0x60
    EVCR_TOTAL_EVENTS = 0x64
    EVCR_TOTAL_CYCLES = 0x68


class GroupByPerQueueRegMap(IntEnum):
    """Offsets within one queue's slice of the per-queue block."""
    SECT_LEFT = 0x0
    ISSUED    = 0x4
    OK        = 0x8
    FAILED    = 0xC


PQ_BASE   = 0x80
PQ_STRIDE = 0x10


def per_queue_reg_addr(reg: GroupByPerQueueRegMap, qid: int) -> int:
    """Absolute offset of `reg` in queue `qid`'s slice of the per-queue block."""
    return PQ_BASE + qid * PQ_STRIDE + int(reg)


CTRL_START, CTRL_FILL, CTRL_ABORT = 1 << 0, 1 << 1, 1 << 2
STATUS_BUSY, STATUS_DONE, STATUS_ERR = 1 << 0, 1 << 1, 1 << 2

STATE_NAMES = ["IDLE", "FILL", "FILL_WAIT", "CLEAR", "RUN", "DRAIN", "WB", "DONE", "ERR"]

# Completion codes the DMA reports back for one command. Anything but SUCCESS ends the run.
ERR_CODE_NAMES = {0: "SUCCESS", 1: "FAILURE", 2: "LBA_OUT_OF_RANGE", 3: "RESERVED"}

# Reads outside the mapped window return this, so it is also the marker for firmware whose window
# predates the extended map.
UNMAPPED_PATTERN = 0xCAFEBABE

REC_BYTES  = 16
SECT_BYTES = 512
RECS_SECT  = SECT_BYTES // REC_BYTES

CLK_PERIOD = 4e-9

# Window EVENT_COUNTER (event_counter.vhd:161-167) is armed with: updates EVCR totals only when
# its progress counter reaches this many cycles, then holds the LAST COMPLETED window, not a run
# total -- so it must stay SHORT, or none ever closes.
EVCR_WINDOW_CYCLES = 1 << 20      # 4.19 ms at 250 MHz


# =================================================================================================
# Reference model
# =================================================================================================

MASK64 = (1 << 64) - 1
SPLITMIX_GAMMA = 0x9E3779B97F4A7C15
SPLITMIX_MIX_1 = 0xBF58476D1CE4E5B9
SPLITMIX_MIX_2 = 0x94D049BB133111EB

# Key modulus the host-side filler applies. Matches the shipping group count, so every generated
# key lands inside the table and OOR_CNT stays at zero for a splitmix run.
SPLITMIX_KEY_MOD = 16384


def decode(raw):
    """Split a raw dump of result sectors into the key and value columns."""
    flat = np.frombuffer(raw, dtype="<u8")
    return flat[0::2], flat[1::2]


def reference(keys, values, num_groups):
    """Exact per-group sum, wrapped to 64 bits exactly as the hardware accumulator does."""
    in_range = keys < num_groups
    sums = np.zeros(num_groups, dtype="<u8")
    np.add.at(sums, keys[in_range].astype(np.intp), values[in_range])
    return sums, int((~in_range).sum())


def fill_pattern(sectors, num_groups):
    """What the core's own fill phase writes: key = index mod GROUPS, value = key + 1."""
    idx = np.arange(sectors * RECS_SECT, dtype="<u8")
    keys = idx % np.uint64(num_groups)
    return keys, keys + np.uint64(1)


def splitmix64(seed, index):
    """One splitmix64 draw, addressed by index instead of by mutating a state.

    This is the normative definition of the record pattern; the host-side filler implements the
    identical function so both sides agree without exchanging data::

        uint64_t splitmix64(uint64_t seed, uint64_t index) {
            uint64_t x = seed + index + 0x9E3779B97F4A7C15ULL;
            uint64_t z = x;
            z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
            z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
            return z ^ (z >> 31);
        }
    """
    x = (int(seed) + int(index) + SPLITMIX_GAMMA) & MASK64
    z = x
    z = ((z ^ (z >> 30)) * SPLITMIX_MIX_1) & MASK64
    z = ((z ^ (z >> 27)) * SPLITMIX_MIX_2) & MASK64
    return z ^ (z >> 31)


def _splitmix64_vec(seed, index):
    """splitmix64() evaluated over a whole uint64 array. Every constant is cast explicitly because
    a bare Python int operand can promote a uint64 array to float and silently lose the low bits."""
    x = (np.uint64(seed) + index.astype("<u8") + np.uint64(SPLITMIX_GAMMA))
    z = x
    z = (z ^ (z >> np.uint64(30))) * np.uint64(SPLITMIX_MIX_1)
    z = (z ^ (z >> np.uint64(27))) * np.uint64(SPLITMIX_MIX_2)
    return z ^ (z >> np.uint64(31))


def splitmix64_records(seed, count, key_mod=SPLITMIX_KEY_MOD):
    """The `count` records a drive filled with `seed` holds.

    Record i is ``key = splitmix64(seed, 2*i) % key_mod``, ``value = splitmix64(seed, 2*i + 1)``.
    """
    idx = np.arange(count, dtype="<u8")
    keys = _splitmix64_vec(seed, np.uint64(2) * idx) % np.uint64(key_mod)
    values = _splitmix64_vec(seed, np.uint64(2) * idx + np.uint64(1))
    return keys, values


def splitmix_expected(seeds, sectors, num_groups, key_mod=SPLITMIX_KEY_MOD):
    """Result table a run over the given per-drive seeds must produce.

    Each enabled queue sweeps `sectors` sectors on its own drive, and the core sums every drive
    into one table, so the reference is the wrapped sum of the per-drive references.
    """
    sums = np.zeros(num_groups, dtype="<u8")
    oor = 0
    for seed in seeds:
        keys, values = splitmix64_records(seed, sectors * RECS_SECT, key_mod)
        drive_sums, drive_oor = reference(keys, values, num_groups)
        sums += drive_sums
        oor += drive_oor
    return sums, oor


# =================================================================================================
# Status decoding
# =================================================================================================

def state_name(status):
    """Name of the state STATUS reports, or the raw index when the map does not cover it."""
    state = (status >> 4) & 0xF
    return STATE_NAMES[state] if state < len(STATE_NAMES) else f"?{state}"


def status_str(status):
    return f"{status:#010x} state={state_name(status)} busy={bool(status & STATUS_BUSY)} " \
           f"done={bool(status & STATUS_DONE)} err={bool(status & STATUS_ERR)}"


def decode_err_info(raw):
    """Split ERR_INFO into the first failing completion's code, direction and queue."""
    code = raw & 0x3
    return {
        "raw": raw,
        "valid": bool(raw & 0x8),
        "code": code,
        "code_name": ERR_CODE_NAMES.get(code, f"?{code}"),
        "type": "rd" if (raw >> 2) & 0x1 else "wr",
        "qid": (raw >> 4) & 0xF,
    }


def err_info_str(raw):
    err = decode_err_info(raw)
    if not err["valid"]:
        return f"{raw:#010x} (no failure recorded)"
    return f"{raw:#010x} code={err['code_name']} type={err['type']} qid={err['qid']}"


# =================================================================================================
# Component access
# =================================================================================================

class GroupByTimeout(RuntimeError):
    """A run did not settle within its budget. `status` is what the core reported after ABORT."""

    def __init__(self, message, status):
        super().__init__(message)
        self.status = status


class IuventusGroupBy(nfb.BaseComp):
    """The GROUP BY user core.

    Pass an already-open ``nfb.Nfb`` handle as `dev` and share it with every other component
    object: a second ``nfb.open()`` on the same card reads zeros instead of failing.
    """

    DT_COMPATIBLE = "ziti,iuventus_groupby"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.clk_period = CLK_PERIOD
        # Populated by wait_done(); an empty list before any run means "none observed yet",
        # never "the run measured zero".
        self.eps_windows = []

    # --- run parameters ---------------------------------------------------------------------
    @property
    def in_lba(self) -> int:
        return (self._comp.read32(GroupByRegMap.IN_LBA_L.value)
                | (self._comp.read32(GroupByRegMap.IN_LBA_H.value) << 32))

    @in_lba.setter
    def in_lba(self, val: int) -> None:
        self._comp.write32(GroupByRegMap.IN_LBA_L.value, val & 0xFFFFFFFF)
        self._comp.write32(GroupByRegMap.IN_LBA_H.value, (val >> 32) & 0xFFFFFFFF)

    @property
    def in_count(self) -> int:
        return self._comp.read32(GroupByRegMap.IN_COUNT.value)

    @in_count.setter
    def in_count(self, val: int) -> None:
        self._comp.write32(GroupByRegMap.IN_COUNT.value, val)

    @property
    def out_lba(self) -> int:
        return (self._comp.read32(GroupByRegMap.OUT_LBA_L.value)
                | (self._comp.read32(GroupByRegMap.OUT_LBA_H.value) << 32))

    @out_lba.setter
    def out_lba(self, val: int) -> None:
        self._comp.write32(GroupByRegMap.OUT_LBA_L.value, val & 0xFFFFFFFF)
        self._comp.write32(GroupByRegMap.OUT_LBA_H.value, (val >> 32) & 0xFFFFFFFF)

    @property
    def out_qid(self) -> int:
        return self._comp.read32(GroupByRegMap.OUT_QID.value)

    @out_qid.setter
    def out_qid(self, val: int) -> None:
        self._comp.write32(GroupByRegMap.OUT_QID.value, val)

    @property
    def qid_mask(self) -> int:
        return self._comp.read32(GroupByRegMap.QID_MASK.value)

    @qid_mask.setter
    def qid_mask(self, val: int) -> None:
        self._comp.write32(GroupByRegMap.QID_MASK.value, val)

    @property
    def lba_num(self) -> int:
        """Sectors per read command, 0-based: 255 is a 128 KiB command."""
        return self._comp.read32(GroupByRegMap.LBA_NUM.value) & 0xFF

    @lba_num.setter
    def lba_num(self, val: int) -> None:
        assert 0 <= val < 256, "LBA_NUM is 0-based and must fit in 8 bits"
        self._comp.write32(GroupByRegMap.LBA_NUM.value, val)

    # --- status -----------------------------------------------------------------------------
    @property
    def status(self) -> int:
        return self._comp.read32(GroupByRegMap.STATUS.value)

    @property
    def busy(self) -> bool:
        return bool(self.status & STATUS_BUSY)

    @property
    def state(self) -> int:
        return (self.status >> 4) & 0xF

    @property
    def rec_cnt(self) -> int:
        """Records aggregated so far. Reading the low word latches the high one, so the two reads
        below are ordered on purpose and must not be reordered or split across other accesses."""
        low = self._comp.read32(GroupByRegMap.REC_CNT_L.value)
        return low | (self._comp.read32(GroupByRegMap.REC_CNT_H.value) << 32)

    @property
    def oor_cnt(self) -> int:
        return self._comp.read32(GroupByRegMap.OOR_CNT.value)

    @property
    def result_sect(self) -> int:
        return self._comp.read32(GroupByRegMap.RESULT_SECT.value)

    @property
    def num_groups(self) -> int:
        return self._comp.read32(GroupByRegMap.NUM_GROUPS.value)

    @property
    def issued_cnt(self) -> int:
        return self._comp.read32(GroupByRegMap.ISSUED_CNT.value)

    @property
    def compl_cnt(self) -> int:
        return self._comp.read32(GroupByRegMap.COMPL_CNT.value)

    @property
    def wr_issued(self) -> int:
        return self._comp.read32(GroupByRegMap.WR_ISSUED.value)

    @property
    def wr_compl(self) -> int:
        return self._comp.read32(GroupByRegMap.WR_COMPL.value)

    @property
    def err_info(self) -> int:
        return self._comp.read32(GroupByRegMap.ERR_INFO.value)

    @property
    def lane_drain(self) -> int:
        return self._comp.read32(GroupByRegMap.LANE_DRAIN.value) & 0xF

    @property
    def stall_noq(self) -> int:
        """Cycles with work left that no queue was able to take."""
        return self._comp.read32(GroupByRegMap.STALL_NOQ.value)

    @property
    def stall_dma(self) -> int:
        """Cycles the core held the read bus off."""
        return self._comp.read32(GroupByRegMap.STALL_DMA.value)

    @property
    def stall_wb(self) -> int:
        """Cycles the write-back was back-pressured."""
        return self._comp.read32(GroupByRegMap.STALL_WB.value)

    # --- entries-per-second counter ---------------------------------------------------------
    @property
    def evcr_interval_cycles(self) -> int:
        return self._comp.read32(GroupByRegMap.EVCR_INTERVAL.value)

    @evcr_interval_cycles.setter
    def evcr_interval_cycles(self, val: int) -> None:
        self._comp.write32(GroupByRegMap.EVCR_INTERVAL.value, val)

    @property
    def evcr_total_events(self) -> int:
        return self._comp.read32(GroupByRegMap.EVCR_TOTAL_EVENTS.value)

    @property
    def evcr_total_cycles(self) -> int:
        return self._comp.read32(GroupByRegMap.EVCR_TOTAL_CYCLES.value)

    def eps(self) -> float:
        """Rate over the LAST COMPLETED EVCR window, entirely from the core's own counters.

        The event counter is fed by the same condition that advances REC_CNT, so events are
        records rather than bus beats and the two agree by construction. No host clock takes part:
        the elapsed time is the counted cycles times the DMA clock period.

        This is a live snapshot of whatever window the counter currently holds, which may already
        be stale or idle if the run has since finished -- it is not a run-spanning figure. Use the
        windows `wait_done` collects, summarised through `eps_from_windows`, for that.
        """
        total_events = self.evcr_total_events
        total_cycles = self.evcr_total_cycles
        if total_cycles == 0:
            return 0.0
        return total_events / (total_cycles * self.clk_period)

    def window_seconds(self) -> float:
        """Length of the EVCR window the counter currently holds, in seconds.

        Hardware time, not host time -- and NOT the run's duration either: like `eps()`, this
        reads whatever window the counter last completed, which may be stale or idle.
        """
        return self.evcr_total_cycles * self.clk_period

    # --- per-queue progress -----------------------------------------------------------------
    def pq_sect_left(self, qid: int) -> int:
        return self._comp.read32(per_queue_reg_addr(GroupByPerQueueRegMap.SECT_LEFT, qid))

    def pq_issued(self, qid: int) -> int:
        return self._comp.read32(per_queue_reg_addr(GroupByPerQueueRegMap.ISSUED, qid))

    def pq_ok(self, qid: int) -> int:
        return self._comp.read32(per_queue_reg_addr(GroupByPerQueueRegMap.OK, qid))

    def pq_failed(self, qid: int) -> int:
        return self._comp.read32(per_queue_reg_addr(GroupByPerQueueRegMap.FAILED, qid))

    def per_queue(self, qid: int) -> dict:
        """Progress of one queue: sectors left, commands issued, and how they completed."""
        return {
            "qid": qid,
            "sect_left": self.pq_sect_left(qid),
            "issued": self.pq_issued(qid),
            "ok": self.pq_ok(qid),
            "failed": self.pq_failed(qid),
        }

    # --- discovery and sanity ---------------------------------------------------------------
    def detect_num_queues(self) -> int:
        """Queues the core was built with: QID_MASK keeps only the bits it has.

        Clobbers and restores QID_MASK, so call it between runs and never during one.
        """
        saved = self.qid_mask
        self.qid_mask = 0xFFFFFFFF
        widest = self.qid_mask
        self.qid_mask = saved
        return widest.bit_length()

    def check_map(self) -> None:
        """Fail early on firmware whose register window predates the extended map.

        NUM_GROUPS is checked first because it sits inside BOTH the old (0x40 B) and the new
        (0x100 B) device-tree node -- see apps/iuventus/comp/DevTree.tcl -- and this architecture's
        group count is fixed at build time (SPLITMIX_KEY_MOD doubles as that expected value, since
        it already is the shipping group count). A mismatch here means something more basic than a
        stale map is wrong, e.g. the wrong node opened or the card is not answering at all.

        LANE_DRAIN then probes past the old node's 0x40 B window. On old firmware that address is
        OUTSIDE the mapped component, so the read may raise instead of returning the unmapped-read
        sentinel -- both outcomes are treated as "old firmware" rather than letting the exception
        propagate.
        """
        num_groups = self.num_groups
        if num_groups != SPLITMIX_KEY_MOD:
            raise RuntimeError(
                f"NUM_GROUPS reads {num_groups:#x}, not the {SPLITMIX_KEY_MOD} this "
                "architecture is built with -- is 'ziti,iuventus_groupby' really the node that "
                "opened, and is the card responding at all?")

        try:
            drain_raw = self._comp.read32(GroupByRegMap.LANE_DRAIN.value)
        except Exception as exc:
            raise RuntimeError(
                "the GROUP BY node does not answer the full register map (reading LANE_DRAIN "
                f"past the old node's 0x40 B window raised {exc!r}) -- the firmware on the card "
                "predates it. Rebuild and reflash the GROUPBY build with the 0x100 B node before "
                "measuring.")

        if drain_raw > 0xF:
            raise RuntimeError(
                "the GROUP BY node does not answer the full register map -- the firmware on the "
                "card predates it. Rebuild and reflash the GROUPBY build with the 0x100 B node "
                "before measuring.")

    # --- run control ------------------------------------------------------------------------
    def configure(self, in_lba, sectors, out_lba, out_qid=0, qid_mask=None, lba_num=None) -> None:
        """Program one run. `sectors` is per queue: every enabled queue sweeps that many on its
        own drive, so the record total scales with the number of bits set in `qid_mask`."""
        self.in_lba = in_lba
        self.in_count = sectors
        self.out_lba = out_lba
        self.out_qid = out_qid
        if qid_mask is not None:
            self.qid_mask = qid_mask
        if lba_num is not None:
            self.lba_num = lba_num

    def start(self, fill: bool = False) -> None:
        """Pulse START. One pulse is enough from IDLE, DONE or ERR alike: the core re-arms straight
        into its clear phase. FILL is a level sampled with the pulse, so it is written here too."""
        self._comp.write32(GroupByRegMap.CTRL.value,
                           CTRL_START | (CTRL_FILL if fill else 0))

    def abort(self, settle_seconds: float = 1.0, poll: float = 0.01, sleep_fn=sleep) -> int:
        """End a run that is waiting on a completion that will never arrive.

        ABORT is a level, so it is asserted, held until the core leaves the busy states, and
        cleared again. Returns the STATUS the core settled at.
        """
        self._comp.write32(GroupByRegMap.CTRL.value, CTRL_ABORT)
        deadline = monotonic() + settle_seconds
        status = self.status
        while (status & STATUS_BUSY) and monotonic() < deadline:
            sleep_fn(poll)
            status = self.status
        self._comp.write32(GroupByRegMap.CTRL.value, 0)
        return status

    def wait_done(self, timeout: float = 60.0, poll: float = 0.01, sleep_fn=sleep):
        """Poll STATUS until the run reports DONE or ERR.

        Also samples the EVCR window counters on every poll while the run is busy. EVENT_COUNTER
        holds only the LAST COMPLETED window, so a read taken once the run has gone idle describes
        an idle window instead of the run -- sampling here, gated on STATUS_BUSY, is what makes the
        collected pairs describe the run itself. A new (events, cycles) pair is kept whenever it
        differs from the previous read and both values are non-zero.

        A run that overruns its budget is ended with ABORT rather than left in flight, so the
        counters below can still be read to explain it and the card does not need a reload.

        Returns `(status, eps_windows)`; `eps_windows` is also left on `self.eps_windows` for
        callers that only hold the object.
        """
        self.eps_windows = []
        last_pair = None
        deadline = monotonic() + timeout
        status = self.status
        while not (status & (STATUS_DONE | STATUS_ERR)):
            if status & STATUS_BUSY:
                pair = (self.evcr_total_events, self.evcr_total_cycles)
                if pair != last_pair and pair[0] and pair[1]:
                    self.eps_windows.append(pair)
                last_pair = pair
            if monotonic() >= deadline:
                aborted = self.abort(sleep_fn=sleep_fn)
                raise GroupByTimeout(
                    f"run did not finish within {timeout:.1f} s: {status_str(status)}\n"
                    f"       after ABORT: {status_str(aborted)}", aborted)
            sleep_fn(poll)
            status = self.status
        return status, self.eps_windows

    def dump_regs(self, num_queues=None) -> None:
        """Print every register in the map plus the per-queue block, with the packed fields
        decoded. REC_CNT is read through the property so its latching order is preserved."""
        for reg in GroupByRegMap:
            if reg is GroupByRegMap.REC_CNT_H:
                continue
            if reg is GroupByRegMap.REC_CNT_L:
                print(f"{'REC_CNT':<18} {reg.value:#04x}  {self.rec_cnt}")
                continue
            print(f"{reg.name:<18} {reg.value:#04x}  {self._comp.read32(reg.value):#010x}")

        print(f"{'STATUS decoded':<18} {'':<4}  {status_str(self.status)}")
        print(f"{'ERR_INFO decoded':<18} {'':<4}  {err_info_str(self.err_info)}")
        print(f"{'LANE_DRAIN decoded':<18} {'':<4}  {self.lane_drain:#06b}")
        print(f"{'EPS':<18} {'':<4}  {self.eps() / 1e6:.3f} M records/s over the last "
              f"completed EVCR window ({self.window_seconds() * 1e3:.3f} ms of counted "
              f"cycles, not run time)")

        if num_queues is None:
            num_queues = self.detect_num_queues()
        for qid in range(num_queues):
            pq = self.per_queue(qid)
            print(f"queue {qid}: sect_left={pq['sect_left']} issued={pq['issued']} "
                  f"ok={pq['ok']} failed={pq['failed']}")


def eps_from_windows(windows, clk_period=CLK_PERIOD) -> dict:
    """Turn (events, cycles) window pairs into an entries-per-second summary.

    `windows` holds one pair per EVCR window `IuventusGroupBy.wait_done` saw close while the run
    was busy. Each window's rate is events / (cycles * clk_period). The median is reported rather
    than the mean so one outlier window (e.g. the run's first, which can straddle a fill or DMA
    warm-up) cannot pull the summary off the steady-state rate.
    """
    rates = [events / (cycles * clk_period) for events, cycles in windows]
    return {
        "eps_median": statistics.median(rates) if rates else None,
        "eps_min": min(rates) if rates else None,
        "eps_max": max(rates) if rates else None,
        "windows": len(rates),
    }


def eps_str(value) -> str:
    """`value` in M records/s, or a placeholder for the `None` a too-short run leaves it as."""
    return f"{value / 1e6:.3f}" if value is not None else "n/a"


# ==============================
# DMA state, read through DMAIuventusRegAccess rather than raw offsets
# ==============================

def wait_design_ready(dma: DMAIuventusRegAccess, timeout: float = 15.0, enable: bool = False,
                      sleep_fn=sleep) -> None:
    """Block until the DMA reports READY, i.e. the design is up and accepting traffic.

    fzc is what normally brings the queues up and enables the design. `enable` is for the case
    where the queues are already configured and only the enable is missing.
    """
    if enable and not dma.ready:
        dma.enable()
        return

    deadline = monotonic() + timeout
    while not dma.ready:
        if monotonic() >= deadline:
            raise TimeoutError(
                "the design never reported READY -- is one fzc per drive holding its SSD?")
        sleep_fn(0.1)


def sample_dma_health(dma: DMAIuventusRegAccess, num_queues: int) -> dict:
    """Snapshot of the DMA counters that say whether a run was clean.

    A queue that stops answering removes itself from the read round-robin, so an N-queue run
    quietly becomes an (N-1)-queue one while the aggregate completion counters stay plausible.
    The per-queue completions below are what makes that visible.
    """
    dma.sample_cntrs()
    disp = [dma.pq_sqe_disp(q) for q in range(num_queues)]
    succ = [dma.pq_succ_cpls(q) for q in range(num_queues)]
    unsucc = [dma.pq_unsucc_cpls(q) for q in range(num_queues)]
    return {
        "ready": bool(dma.ready),
        "succ_cpls": dma.succ_cpls,
        "unsucc_cpls": dma.unsucc_cpls,
        "err_mask": dma.err_mask,
        "rd_pages_free": dma.rd_pages_free,
        "wr_pages_free": dma.wr_pages_free,
        "pq_sqe_disp": disp,
        "pq_succ_cpls": succ,
        "pq_unsucc_cpls": unsucc,
        # Commands the queue was given and has not answered for. Sampled after a run has reported
        # DONE, a non-zero entry is the signature of a queue that stopped answering.
        "pq_outstanding": [d - (s + u) for d, s, u in zip(disp, succ, unsucc)],
    }


def dma_health_str(health: dict) -> str:
    lines = [f"DMA: succ={health['succ_cpls']} unsucc={health['unsucc_cpls']} "
             f"err_mask={health['err_mask']:#x} rd_pages_free={health['rd_pages_free']} "
             f"wr_pages_free={health['wr_pages_free']}"]
    stuck = [q for q, out in enumerate(health["pq_outstanding"]) if out]
    if stuck:
        detail = ", ".join(f"q{q}={health['pq_outstanding'][q]}" for q in stuck)
        lines.append(f"     *** UNANSWERED COMMANDS: {detail} ***")
    per_queue = ", ".join(f"q{q}={ok}" for q, ok in enumerate(health["pq_succ_cpls"]))
    lines.append(f"     per-queue completions: {per_queue}")
    return "\n".join(lines)


# Importable run logic: these take an ALREADY-OPEN IuventusGroupBy and DMAIuventusRegAccess plus
# parsed parameters -- no argparse, no nfb.open() -- so main()'s CLI handlers and a testbench
# drive the same code paths.

def run_groupby(comp: IuventusGroupBy, dma: DMAIuventusRegAccess, in_lba: int, sectors: int,
                out_lba: int, out_qid: int = 0, queues: int = 1, fill: bool = False,
                lba_num=None, timeout: float = 60.0, sleep_fn=sleep, verbose: bool = True) -> dict:
    """One aggregation run, returning everything the core counted about it.

    `sectors` is per queue. `queues` selects queues 0..N-1 through QID_MASK; the DMA is checked
    for one queue pair per drive first, because two pairs on one drive make every per-queue figure
    stop attributing to a device.
    """
    assert queues >= 1, "queues must be at least 1"
    comp.check_map()

    available = comp.detect_num_queues()
    assert queues <= available, \
        f"--queues {queues} exceeds the {available} queues this core was built with"
    assert out_qid < available, f"--out-qid {out_qid} exceeds queue {available - 1}"

    dma.check_one_queue_per_ssd(queues)

    qid_mask = (1 << queues) - 1
    comp.configure(in_lba, sectors, out_lba, out_qid=out_qid, qid_mask=qid_mask, lba_num=lba_num)
    # Short interval: EVENT_COUNTER only updates its totals when a window closes, so the run has
    # to close at least one to be measured at all. See EVCR_WINDOW_CYCLES.
    comp.evcr_interval_cycles = EVCR_WINDOW_CYCLES

    comp.start(fill=fill)
    status, eps_windows = comp.wait_done(timeout=timeout, sleep_fn=sleep_fn)
    eps_summary = eps_from_windows(eps_windows, clk_period=comp.clk_period)

    expected = queues * sectors * RECS_SECT
    result = {
        "in_lba": in_lba,
        "out_lba": out_lba,
        "out_qid": out_qid,
        "sectors_per_queue": sectors,
        "num_queues": queues,
        "qid_mask": qid_mask,
        "lba_num": comp.lba_num,
        "fill": fill,
        "status": status,
        "state": state_name(status),
        "err": bool(status & STATUS_ERR),
        "rec_cnt": comp.rec_cnt,
        "rec_cnt_expected": expected,
        "oor_cnt": comp.oor_cnt,
        "num_groups": comp.num_groups,
        "result_sect": comp.result_sect,
        "issued_cnt": comp.issued_cnt,
        "compl_cnt": comp.compl_cnt,
        "wr_issued": comp.wr_issued,
        "wr_compl": comp.wr_compl,
        "err_info": decode_err_info(comp.err_info),
        "lane_drain": comp.lane_drain,
        "stall_noq": comp.stall_noq,
        "stall_dma": comp.stall_dma,
        "stall_wb": comp.stall_wb,
        "evcr_total_events": comp.evcr_total_events,
        "evcr_total_cycles": comp.evcr_total_cycles,
        "eps": eps_summary["eps_median"],
        "eps_min": eps_summary["eps_min"],
        "eps_max": eps_summary["eps_max"],
        "eps_windows": eps_windows,
        "per_queue": [comp.per_queue(q) for q in range(queues)],
        "dma": sample_dma_health(dma, queues),
    }
    if eps_summary["windows"] == 0:
        result["eps_note"] = (
            "no EVCR window closed during the run -- it was shorter than one "
            f"{EVCR_WINDOW_CYCLES * comp.clk_period * 1e3:.2f} ms window, so eps is unmeasured, "
            "not 0.0. Rerun with more --sectors (or a smaller --lba-num) so at least one closes.")

    if verbose:
        print(f"status: {status_str(status)}")
        print(f"records: {result['rec_cnt']} (expected {expected}), "
              f"out of range: {result['oor_cnt']}")
        if result["eps"] is None:
            print(f"eps: unmeasured -- {result['eps_note']}")
        else:
            print(f"eps: {result['eps'] / 1e6:.3f} M records/s (median of "
                  f"{eps_summary['windows']} EVCR window(s), range "
                  f"{result['eps_min'] / 1e6:.3f}-{result['eps_max'] / 1e6:.3f} M records/s)")
        if result["err"]:
            print(f"ERR_INFO: {err_info_str(result['err_info']['raw'])}", file=sys.stderr)
        print(dma_health_str(result["dma"]))

    return result


def run_lba_sweep(comp: IuventusGroupBy, dma: DMAIuventusRegAccess, in_lba: int, sectors: int,
                  out_lba: int, sizes=None, out_qid: int = 0, queues: int = 1, fill: bool = False,
                  timeout: float = 60.0, sleep_fn=sleep, results_file=None,
                  verbose: bool = True) -> list:
    """Repeat the run across read-command sizes, returning one result row per size.

    Only the first point may fill: the input records do not change between sizes, and refilling
    would both waste drive writes and measure the fill instead of the aggregation.
    """
    if sizes is None:
        sizes = [0, 1, 3, 7, 15, 31, 63, 127, 255]

    rows = []
    for index, size in enumerate(sizes):
        row = run_groupby(comp, dma, in_lba, sectors, out_lba, out_qid=out_qid, queues=queues,
                          fill=(fill and index == 0), lba_num=size, timeout=timeout,
                          sleep_fn=sleep_fn, verbose=False)
        rows.append(row)
        if verbose:
            print(f"lba_num={size:3d} ({(size + 1) * SECT_BYTES / 1024:6.1f} KiB, "
                  f"queues={queues}): "
                  f"{eps_str(row['eps']):>8} M records/s, records={row['rec_cnt']}, "
                  f"state={row['state']}", flush=True)
        if row["err"]:
            print(f"run at lba_num={size} failed: {err_info_str(row['err_info']['raw'])}",
                  file=sys.stderr)
            break

    if results_file:
        save_results(rows, results_file)
        if verbose:
            print(f"Saved GROUP BY results to {results_file}")
    return rows


def check_result_file(path, sums, num_groups):
    """Compare a raw dump of the result sectors against the reference table.

    Returns a list of failure strings, empty when the table matches.
    """
    with open(path, "rb") as handle:
        got_keys, got_sums = decode(handle.read())

    problems = []
    if len(got_keys) != num_groups:
        problems.append(f"result file holds {len(got_keys)} groups, expected {num_groups}")
    elif not np.array_equal(got_keys, np.arange(num_groups, dtype="<u8")):
        problems.append("result keys are not the dense 0..GROUPS-1 sequence")
    elif not np.array_equal(got_sums, sums):
        wrong = int((got_sums != sums).sum())
        first = int(np.argmax(got_sums != sums))
        problems.append(f"{wrong} groups differ, first at key {first}: "
                        f"{got_sums[first]} vs {sums[first]}")
    return problems


# =================================================================================================
# Results and plots
# =================================================================================================

def run_stamp() -> str:
    """Timestamp suffix shared by every artifact of ONE invocation, so successive sweeps
    accumulate instead of overwriting each other. These are WORKING artifacts: promote the ones
    worth keeping into doc/measurements/ deliberately, do not commit them wholesale."""
    return datetime.now().strftime("%Y-%m-%d_%H%M%S")


def save_results(rows, out_path):
    out_dir = os.path.dirname(out_path)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    with open(out_path, "w") as output_file:
        json.dump(rows, output_file, indent=2)


def load_results(in_path):
    with open(in_path, "r") as input_file:
        rows = json.load(input_file)

    assert isinstance(rows, list), "GROUP BY results file must contain a JSON list"
    required_keys = {"lba_num", "eps", "num_queues", "rec_cnt"}
    for index, item in enumerate(rows):
        assert isinstance(item, dict), f"Result item #{index} must be a JSON object"
        missing = required_keys - set(item.keys())
        assert not missing, f"Result item #{index} is missing keys: {sorted(missing)}"

    return rows


def build_eps_plot(rows, out_dir=".", stamp=None, png_dpi=400):
    """Plot eps against read-command size, one series per queue count."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    os.makedirs(out_dir, exist_ok=True)
    stamp = stamp or run_stamp()

    series = {}
    for row in rows:
        if row["eps"] is None:
            continue
        label = f"N={int(row['num_queues'])}"
        series.setdefault(label, []).append((int(row["lba_num"]) + 1, float(row["eps"]) / 1e6))
    if not series:
        return []
    for label in series:
        series[label].sort()

    plt.figure(figsize=(8, 6))
    for label in sorted(series):
        x_vals = [x for x, _ in series[label]]
        y_vals = [y for _, y in series[label]]
        plt.plot(x_vals, y_vals, marker="o", linewidth=2, label=label)

    plt.xlabel("Read command size [LBAs]", fontsize=15)
    plt.ylabel("Aggregation rate [M records/s]", fontsize=15)
    plt.xticks([1, 16, 32, 64, 128, 256], fontsize=13)
    plt.yticks(fontsize=13)
    plt.grid(True, linestyle="--", alpha=0.8)
    plt.legend(fontsize=12)
    plt.tight_layout()

    base = os.path.join(out_dir, f"groupby_eps_{stamp}")
    png_path, pdf_path = f"{base}.png", f"{base}.pdf"
    plt.savefig(png_path, dpi=png_dpi)
    plt.savefig(pdf_path)
    plt.close()
    return [png_path, pdf_path]


def print_summary(rows):
    print(f"{'LBAs':>6} {'queues':>7} {'M rec/s':>10} {'records':>12} {'oor':>8} "
          f"{'noq':>10} {'dma':>10} {'wb':>10} state")
    for row in rows:
        print(f"{int(row['lba_num']) + 1:>6} {row['num_queues']:>7} "
              f"{eps_str(row['eps']):>10} {row['rec_cnt']:>12} {row['oor_cnt']:>8} "
              f"{row.get('stall_noq', 0):>10} {row.get('stall_dma', 0):>10} "
              f"{row.get('stall_wb', 0):>10} {row.get('state', '?')}")


def generate_outputs(rows, out_dir="."):
    print_summary(rows)
    for path in build_eps_plot(rows, out_dir=out_dir):
        print(f"Saved plot to {path}")


# =================================================================================================
# CLI
# =================================================================================================

def parse_args():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('-d', '--device', default=nfb.libnfb.Nfb.default_dev_path,
                        metavar='device', help="Index of a NFB device")
    parser.add_argument('-n', '--sectors', type=int, default=64,
                        help="Input sectors to aggregate PER QUEUE (default: 64)")
    parser.add_argument('--in-lba', type=lambda s: int(s, 0), default=0,
                        help="First LBA of the input range on every enabled drive")
    parser.add_argument('--out-lba', type=lambda s: int(s, 0), default=0x100000,
                        help="First LBA the result table is written to")
    parser.add_argument('--out-qid', type=int, default=0,
                        help="Queue the result table is written through (default: 0)")
    parser.add_argument('--queues', type=int, default=1,
                        help="Number of SSD-backed queues (0..N-1) to aggregate across")
    parser.add_argument('--lba-num', type=int, default=None,
                        help="Sectors per read command, 0-based (default: leave the core's own)")
    parser.add_argument('--fill', action='store_true',
                        help="Write the core's own record pattern over the input range first. "
                             "It fills through --out-qid only, so it stages ONE drive.")
    parser.add_argument('--sweep', action='store_true',
                        help="Repeat the run across read-command sizes and plot the rate")
    parser.add_argument('--sweep-sizes', type=lambda s: [int(v, 0) for v in s.split(',')],
                        default=None, help="Comma-separated LBA_NUM values for --sweep")
    parser.add_argument('--seed', action='append', type=lambda s: int(s, 0), default=None,
                        help="Seed of the host-written record pattern on a drive. Repeat once per "
                             "queue, or give one seed shared by every drive.")
    parser.add_argument('--result-file',
                        help="Raw dump of the result sectors, compared against the reference sums")
    parser.add_argument('--results-file', default='groupby_results.json',
                        help="Path to the results JSON (used for saving and loading)")
    parser.add_argument('--from-file', action='store_true',
                        help="Load --results-file and regenerate the plot without touching HW")
    parser.add_argument('--timeout', type=float, default=60.0,
                        help="Seconds one run may take before it is ABORTed (default: 60)")
    parser.add_argument('--enable', action='store_true',
                        help="Enable the design if it is not up. The queues must already be "
                             "configured; fzc normally does both.")
    parser.add_argument('--disable-after', action='store_true',
                        help="Run the DMA drain barrier after a clean run, leaving the design "
                             "stopped and every outstanding command retired")
    parser.add_argument('--debug', action='store_true',
                        help="Dump every register in the map, decoded, and exit")
    return parser.parse_args()


def main():
    args = parse_args()

    if args.from_file:
        rows = load_results(args.results_file)
        generate_outputs(rows, out_dir=os.path.dirname(args.results_file) or ".")
        return 0

    # Before anything opens the device. --from-file returns above and never touches hardware, so
    # it deliberately does not take the lock.
    acquire_device_lock(args.device)

    # One handle shared by both components: a second nfb.open() on the same card reads zeros
    # instead of failing, which turns every counter into a plausible 0.
    dev = nfb.open(args.device)
    comp = IuventusGroupBy(dev=dev, index=0)
    dma = DMAIuventusRegAccess(dev=dev)

    if args.debug:
        comp.dump_regs()
        return 0

    wait_design_ready(dma, enable=args.enable)
    comp.check_map()

    num_groups = comp.num_groups
    print(f"table: {num_groups} groups, result occupies {comp.result_sect} sectors "
          f"at LBA {args.out_lba}, {comp.detect_num_queues()} queues built")

    try:
        if args.sweep:
            rows = run_lba_sweep(comp, dma, args.in_lba, args.sectors, args.out_lba,
                                 sizes=args.sweep_sizes, out_qid=args.out_qid,
                                 queues=args.queues, fill=args.fill, timeout=args.timeout,
                                 results_file=args.results_file)
            generate_outputs(rows, out_dir=os.path.dirname(args.results_file) or ".")
            return 0 if rows and not rows[-1]["err"] else 1

        row = run_groupby(comp, dma, args.in_lba, args.sectors, args.out_lba,
                          out_qid=args.out_qid, queues=args.queues, fill=args.fill,
                          lba_num=args.lba_num, timeout=args.timeout)
    except GroupByTimeout as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        print("       The run was ABORTed, so the core is idle again. A run aborted mid-read "
              "leaves the read path owed one completion: stop fzc with SIGINT before trusting "
              "the next run's totals.", file=sys.stderr)
        return 1

    save_results([row], args.results_file)
    print(f"Saved GROUP BY results to {args.results_file}")

    ok = not row["err"] and row["rec_cnt"] == row["rec_cnt_expected"]
    if row["rec_cnt"] != row["rec_cnt_expected"]:
        print(f"FAIL: the core saw {row['rec_cnt']} records, not {row['rec_cnt_expected']}",
              file=sys.stderr)

    # Which reference applies depends on who wrote the records: --seed means the host-side filler
    # staged them, --fill means the core staged its own pattern on --out-qid's drive alone.
    sums = None
    if args.seed is not None:
        seeds = args.seed if len(args.seed) > 1 else args.seed * args.queues
        if len(seeds) != args.queues:
            print(f"FAIL: {len(seeds)} seeds given for {args.queues} queues", file=sys.stderr)
            return 1
        sums, exp_oor = splitmix_expected(seeds, args.sectors, num_groups)
        print(f"reference over seeds {seeds}: expected out of range: {exp_oor}")
        if row["oor_cnt"] != exp_oor:
            print(f"FAIL: OOR_CNT {row['oor_cnt']}, expected {exp_oor}", file=sys.stderr)
            ok = False
    elif args.fill:
        keys, values = fill_pattern(args.sectors, num_groups)
        sums, exp_oor = reference(keys, values, num_groups)
        nonzero = int((sums != 0).sum())
        print(f"self-test pattern covers {nonzero} of {num_groups} groups; "
              f"expected out of range: {exp_oor}")
        if args.queues != 1:
            print("NOTE: the core's fill stages --out-qid's drive only, so this reference "
                  "describes one queue. Use --seed for a multi-drive run.")
        if row["oor_cnt"] != exp_oor:
            print(f"FAIL: OOR_CNT {row['oor_cnt']}, expected {exp_oor}", file=sys.stderr)
            ok = False

    if args.result_file and sums is not None:
        problems = check_result_file(args.result_file, sums, num_groups)
        for problem in problems:
            print(f"FAIL: {problem}", file=sys.stderr)
        ok = ok and not problems
        if not problems:
            print(f"all {num_groups} group sums match the reference")
    elif sums is not None:
        print(f"dump the {row['result_sect']} result sectors at LBA {args.out_lba} and pass them "
              f"with --result-file to compare the sums themselves")
    else:
        print("no reference: only REC_CNT was checked. Pass --seed (host-written records) or "
              "--fill (the core's own pattern) to check the sums as well.")

    if args.disable_after:
        if row["err"]:
            print("skipping the drain barrier: the run ended in the error state and the barrier "
                  "could not complete", file=sys.stderr)
        else:
            dma.disable()
            print("design stopped, every outstanding command retired")

    print("PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
