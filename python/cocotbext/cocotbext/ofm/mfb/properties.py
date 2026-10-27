# properties.py: MFB protocol conformance assertions for cocotb testbenches
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import cocotb

from cocotb.triggers import ReadOnly, RisingEdge
from cocotb_bus.bus import Bus

from ..utils.signals import binstr_bit, binstr_resolvable, binstr_resolved, signal_binstr
from .monitors import MFBProtocolError
from .protocol import MfbParams
from .utils import region_frame_event


# Every rule the checker knows. Pass a subset as `disable=` to switch individual ones off; the
# names double as the tag in the violation message, so a failure is greppable back to this list.
MFB_RULES = (
    "src_rdy_undefined",
    "dst_rdy_undefined",
    "sof_undefined",
    "eof_undefined",
    "sof_pos_undefined",
    "eof_pos_undefined",
    "src_rdy_dropped",
    "ctrl_changed",
    "data_changed",
    "sof_pos_range",
    "eof_pos_range",
    "sof_while_frame_open",
    "eof_without_sof",
    "straddling",
    "no_straddling",
)


def _field_str(binstr, hi, lo):
    """Bits [hi:lo], counted from the LSB, of an MSB-first bit string."""
    n = len(binstr)
    return binstr[n - 1 - hi:n - lo]


class MFBProperty:
    """Passive conformance checker for one MFB interface: samples every rising edge and reports
    departures from `comp/mfb_tools/readme.rst`. It never drives a signal, so it can ride alongside
    a driver, a monitor, or neither.
    """

    _signals = ["data", "sof", "eof", "src_rdy", "dst_rdy"]
    _optional_signals = ["sof_pos", "eof_pos", "meta", "be"]

    def __init__(self, entity, name, clock, reset=None, reset_active_level=1, mfb_params=None,
                 straddling=None, disable=(), max_errors=1, label=None, start=True):
        self.bus = Bus(entity, name, self._signals, optional_signals=self._optional_signals)
        self.log = entity._log
        self.name = label or name
        self.clock = clock
        self.reset = reset
        self.reset_active_level = reset_active_level
        self.straddling = straddling
        self.max_errors = max_errors

        unknown = set(disable) - set(MFB_RULES)
        if unknown:
            raise ValueError(f"MFBProperty({self.name}): unknown rule(s) {sorted(unknown)}")
        self._disabled = set(disable)

        # A caller's dict is taken as it is, so a checker can be configured against a geometry the signals do not have.
        if mfb_params is not None:
            geom = MfbParams(mfb_params["regions"], mfb_params["region_size"], mfb_params["block_size"],
                             mfb_params["item_width"])
        else:
            geom = MfbParams.from_bus(self.bus)
        self._regions, self._region_size, self._block_size, self._item_width = \
            geom.regions, geom.region_size, geom.block_size, geom.item_width
        self._sof_pos_w = geom.sof_pos_width
        self._eof_pos_w = geom.eof_pos_width

        self.errors = []
        self.cycles = 0
        self.words = 0
        self.frames = 0
        self.frame_open = False

        self._prev_src_rdy = False
        self._prev_accepted = True
        self._stalled = None
        self._prev_word = "<none>"
        self._thread = None
        if start:
            self.start()

    def disable_rule(self, *rules):
        """Switch rules off after construction, for a test that drives illegal traffic on purpose."""
        unknown = set(rules) - set(MFB_RULES)
        if unknown:
            raise ValueError(f"MFBProperty({self.name}): unknown rule(s) {sorted(unknown)}")
        self._disabled.update(rules)

    def start(self):
        if self._thread is None:
            self._thread = cocotb.start_soon(self._check())

    def stop(self):
        if self._thread is not None:
            self._thread.kill()
            self._thread = None

    def _violation(self, rule, msg):
        if rule in self._disabled:
            return
        text = f"MFB[{self.name}] cycle {self.cycles}: {rule}: {msg}"
        self.errors.append((self.cycles, rule, msg))
        self.log.error(text)
        if self.max_errors and len(self.errors) >= self.max_errors:
            raise MFBProtocolError(text)

    def _in_reset(self):
        if self.reset is None:
            return False
        val = signal_binstr(self.reset)
        # An unresolvable reset means the design has not been brought up yet, so there is nothing
        # to hold the bus to; checking there only reports the testbench's own start-up state.
        if not binstr_resolvable(val):
            return True
        return val == str(self.reset_active_level)

    def final_check(self):
        """Fail if the stream ended mid-frame or any violation was recorded but not raised."""
        if self.frame_open:
            self._violation("eof_without_sof", "stream ended with a frame still open")
        if self.errors:
            raise MFBProtocolError(
                f"MFB[{self.name}]: {len(self.errors)} protocol violation(s), first: {self.errors[0]}")

    async def _check(self):
        clk_re = RisingEdge(self.clock)
        while True:
            await clk_re
            await ReadOnly()
            self.check_cycle()

    def check_cycle(self):
        """One cycle's checks, for a bench that samples many interfaces from one task of its own
        (construct with start=False) instead of one task per checker."""
        self.cycles += 1
        if self._in_reset():
            self.frame_open = False
            self._prev_src_rdy = False
            self._prev_accepted = True
            self._stalled = None
            return
        self._sample()

    def _sample(self):
        src_rdy_v = signal_binstr(self.bus.src_rdy)
        dst_rdy_v = signal_binstr(self.bus.dst_rdy)
        if not binstr_resolvable(src_rdy_v):
            self._violation("src_rdy_undefined", f"SRC_RDY = {src_rdy_v}")
            return
        if not binstr_resolvable(dst_rdy_v):
            self._violation("dst_rdy_undefined", f"DST_RDY = {dst_rdy_v}")
            return

        src_rdy = src_rdy_v == "1"
        dst_rdy = dst_rdy_v == "1"

        # The source may not withdraw an offer: once SRC_RDY rises it stays up until the sink
        # takes the word. Checked against the previous cycle, which is where the offer was made.
        if self._prev_src_rdy and not self._prev_accepted and not src_rdy:
            self._violation("src_rdy_dropped", "SRC_RDY fell while DST_RDY was low")

        self._check_hold(src_rdy, dst_rdy)

        self._prev_src_rdy = src_rdy
        self._prev_accepted = dst_rdy

        # Definedness is checked on the offer, as the UVM mfb_property does: a word carrying an X
        # is a fault whether or not the sink happens to take it.
        if not src_rdy or not self._check_defined():
            return
        if not dst_rdy:
            return
        self.words += 1
        self._check_word()
        self._prev_word = self._word_str()

    def _check_hold(self, src_rdy, dst_rdy):
        """A stalled source holds the word: nothing on the bus may move until DST_RDY arrives."""
        if self._stalled is not None:
            ctrl, data = self._stalled
            now_ctrl = self._ctrl_snapshot()
            if now_ctrl != ctrl:
                self._violation("ctrl_changed",
                                f"SOF/EOF/SOF_POS/EOF_POS moved under backpressure: {ctrl} -> {now_ctrl}")
            now_data = self._data_snapshot()
            if now_data != data:
                self._violation("data_changed", "DATA/META moved under backpressure")
        self._stalled = None
        if src_rdy and not dst_rdy:
            self._stalled = (self._ctrl_snapshot(), self._data_snapshot())

    def _word_str(self):
        """The control word as text, in the same field order the hold snapshot compares."""
        names = ["SOF", "EOF"] + [s.upper() for s in ("sof_pos", "eof_pos") if hasattr(self.bus, s)]
        return " ".join(f"{n}={v}" for n, v in zip(names, self._ctrl_snapshot()))

    def _ctrl_snapshot(self):
        parts = [signal_binstr(self.bus.sof), signal_binstr(self.bus.eof)]
        for sig in ("sof_pos", "eof_pos"):
            if hasattr(self.bus, sig):
                parts.append(signal_binstr(getattr(self.bus, sig)))
        return tuple(parts)

    def _data_snapshot(self):
        if "data_changed" in self._disabled:
            return None
        parts = [signal_binstr(self.bus.data)]
        if hasattr(self.bus, "meta"):
            parts.append(signal_binstr(self.bus.meta))
        return tuple(parts)

    def _check_defined(self):
        """SOF/EOF and the position slices of flagged regions must resolve while SRC_RDY is high."""
        sof = signal_binstr(self.bus.sof)
        eof = signal_binstr(self.bus.eof)
        if not binstr_resolved(sof):
            self._violation("sof_undefined", f"SOF = {sof}")
            return False
        if not binstr_resolved(eof):
            self._violation("eof_undefined", f"EOF = {eof}")
            return False

        sof_pos = signal_binstr(self.bus.sof_pos) if hasattr(self.bus, "sof_pos") else ""
        eof_pos = signal_binstr(self.bus.eof_pos) if hasattr(self.bus, "eof_pos") else ""
        ok = True
        for r in range(self._regions):
            if self._sof_pos_w and binstr_bit(sof, r):
                f = _field_str(sof_pos, (r + 1) * self._sof_pos_w - 1, r * self._sof_pos_w)
                if not binstr_resolved(f):
                    self._violation("sof_pos_undefined", f"region {r} SOF_POS = {f}")
                    ok = False
            if self._eof_pos_w and binstr_bit(eof, r):
                f = _field_str(eof_pos, (r + 1) * self._eof_pos_w - 1, r * self._eof_pos_w)
                if not binstr_resolved(f):
                    self._violation("eof_pos_undefined", f"region {r} EOF_POS = {f}")
                    ok = False
        return ok

    def _check_word(self):
        sof = signal_binstr(self.bus.sof)
        eof = signal_binstr(self.bus.eof)
        sof_pos = signal_binstr(self.bus.sof_pos) if hasattr(self.bus, "sof_pos") else ""
        eof_pos = signal_binstr(self.bus.eof_pos) if hasattr(self.bus, "eof_pos") else ""

        word = (f"SOF={sof} EOF={eof} SOF_POS={sof_pos or '-'} EOF_POS={eof_pos or '-'}"
                f" | prev {self._prev_word}")
        for r in range(self._regions):
            s = binstr_bit(sof, r)
            e = binstr_bit(eof, r)
            self._check_straddling(r, s, eof)
            if not (s or e):
                continue

            s_item = self._sof_item(r, s, sof_pos)
            e_item = self._eof_item(r, e, eof_pos)
            if s_item is None or e_item is None:
                continue

            event = region_frame_event(s, e, s_item, e_item)
            if event in ("whole", "start"):
                if self.frame_open:
                    what = "holds a whole frame" if event == "whole" else "starts a frame"
                    self._violation("sof_while_frame_open", f"region {r} {what} while another is still open ({word})")
                self.frames += event == "whole"
                self.frame_open = event == "start"
            else:
                if not self.frame_open:
                    self._violation("eof_without_sof",
                                    f"region {r} ends a frame that never started ({word})")
                else:
                    self.frames += 1
                self.frame_open = event == "end_start"

    def _sof_item(self, r, s, sof_pos):
        """Item index of the frame start in region `r`, or None when the region has no SOF."""
        if not s:
            return 0
        if self._sof_pos_w == 0:
            return 0
        blk = int(_field_str(sof_pos, (r + 1) * self._sof_pos_w - 1, r * self._sof_pos_w), 2)
        # Only reachable when the geometry came from a `mfb_params` dict that disagrees with the
        # RTL: a log2-derived field cannot hold an out-of-range block index on its own.
        if blk >= self._region_size:
            self._violation("sof_pos_range", f"region {r} SOF_POS = {blk} >= REGION_SIZE {self._region_size}")
            return None
        return blk * self._block_size

    def _eof_item(self, r, e, eof_pos):
        if not e:
            return 0
        if self._eof_pos_w == 0:
            return 0
        item = int(_field_str(eof_pos, (r + 1) * self._eof_pos_w - 1, r * self._eof_pos_w), 2)
        # Same guard as sof_pos_range: it catches a checker configured against the wrong geometry.
        if item >= self._region_size * self._block_size:
            self._violation("eof_pos_range",
                            f"region {r} EOF_POS = {item} >= REGION_SIZE*BLOCK_SIZE "
                            f"{self._region_size * self._block_size}")
            return None
        return item

    def _check_straddling(self, r, s, eof):
        """PCIe-flavoured MFB restricts where a frame may start; plain MFB leaves it free."""
        if self.straddling is None or r == 0 or not s:
            return
        if self.straddling:
            if not binstr_bit(eof, r - 1):
                self._violation("straddling", f"region {r} starts a frame without an EOF in region {r - 1}")
        else:
            self._violation("no_straddling", f"region {r} starts a frame, only region 0 may")


def attach_mfb_properties(entity, clock, reset=None, include=None, exclude=(), **kwargs):
    """Attach an MFBProperty to every MFB interface the entity exposes, keyed by interface name.
    Discovery uses the `<name>_SRC_RDY` ports, so a bus no driver or monitor touches is covered too.
    """
    handles = {a.upper(): a for a in dir(entity)}
    names = []
    for upper, attr in handles.items():
        if not upper.endswith("_SRC_RDY"):
            continue
        base = attr[:-len("_SRC_RDY")]
        # An MFB port group needs the whole core set. Matching on SRC_RDY alone also picks up MVB
        # and other ready/valid buses, whose missing DATA/SOF would only surface as a type error.
        if any(base.upper() + "_" + sig not in handles
               for sig in ("DATA", "SOF", "EOF", "DST_RDY")):
            continue
        names.append(base)

    props = {}
    for base in sorted(names):
        if base in exclude:
            continue
        if include is not None and base not in include:
            continue
        props[base] = MFBProperty(entity, base, clock, reset=reset, **kwargs)
    # Announce what got covered: a silent checker and an absent one look identical in a green log,
    # and a bus lost in a rename would otherwise pass as verified.
    entity._log.info("MFB conformance checks on: %s" % (", ".join(
        f"{n} MFB#({p._regions},{p._region_size},{p._block_size},{p._item_width})"
        for n, p in sorted(props.items())) or "<none found>"))
    return props


def final_check_all(props):
    """Run every checker's end-of-test verdict, reporting all failures rather than the first."""
    failures = []
    for name, prop in props.items():
        try:
            prop.final_check()
        except MFBProtocolError as exc:
            failures.append(str(exc))
    if failures:
        raise MFBProtocolError("; ".join(failures))
