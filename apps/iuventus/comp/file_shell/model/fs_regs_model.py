# fs_regs_model.py: reference model of FS_REGS, the file shell's MI register map
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

"""Decodes an MI offset the way the register map in fs_pkg.vhd defines it and keeps the RW state;
the status inputs are passed in by the caller as the values present during the access."""

from fs_ctx import (ARGS_BASE, CTRL_ABORT_BIT, CTRL_CLEAR_BIT, CTRL_START_BIT, DECODE_MASK, IN_RING_LOG2,
                    LAYOUT_VERSION, OUT_RING_LOG2, REG_CTRL, REG_KERNEL_ID, REG_RING_DEPTHS, REG_STATUS,
                    REG_STREAM_MASK, REG_STRIPE, REG_VERSION, RING_MI_BASE, S_ERR_INFO, S_IN_BYTES_HI,
                    S_IN_BYTES_LO, S_IN_FILES, S_IN_HEAD, S_IN_TAIL, S_OUT_BYTES_HI, S_OUT_BYTES_LO,
                    S_OUT_HEAD, S_OUT_TAIL, S_STATUS, SS_NEED_SPACE, ST_BUSY, ST_DONE, ST_ERR, ST_NEED_SPACE,
                    STREAM_BASE, STREAM_STRIDE, STRIPE_RST_CHUNK, STRIPE_RST_DRIVES)

RING_DEPTHS = (OUT_RING_LOG2 << 8) | IN_RING_LOG2


def decode(addr, streams):
    """('global', off) | ('stream', s, off) | ('args', off) | ('ring', hbm_addr) | ('none',)."""
    a = addr & DECODE_MASK
    if a < 0x100:
        return ("global", a & 0xFC)
    if a < 0x400:
        s = (a - STREAM_BASE) // STREAM_STRIDE
        return ("stream", s, a & 0x3C) if s < streams else ("none",)
    if ARGS_BASE <= a < ARGS_BASE + 0x1000:
        return ("args", a & 0xFFF)
    if (a >> 23) in (1, 2):
        return ("ring", a - RING_MI_BASE)
    return ("none",)


class Status:
    """Status inputs of the register file, as the bench drives them."""

    def __init__(self, streams):
        self.busy = self.done = self.err = 0
        self.state = 0
        self.in_files = [0] * streams
        self.in_head = [0] * streams
        self.out_head = [0] * streams
        self.in_bytes = [0] * streams
        self.out_bytes = [0] * streams
        self.stream_status = [0] * streams
        self.err_info = [0] * streams


class FsRegsModel:
    def __init__(self, streams, kernel_id=1):
        self.streams = streams
        self.kernel_id = kernel_id
        self.stream_mask = 0
        self.drives = STRIPE_RST_DRIVES
        self.chunk = STRIPE_RST_CHUNK
        self.clear()

    def clear(self):
        self.in_tail = [0] * self.streams
        self.out_tail = [0] * self.streams
        self.in_hi = [0] * self.streams
        self.out_hi = [0] * self.streams

    def write(self, addr, data, st):
        """Applies a register write; returns the CTRL pulses (start, abort, clear) it causes."""
        kind = decode(addr, self.streams)
        pulses = (0, 0, 0)
        if kind[0] == "global":
            off = kind[1]
            if off == REG_CTRL:
                pulses = (data >> CTRL_START_BIT & 1, data >> CTRL_ABORT_BIT & 1, data >> CTRL_CLEAR_BIT & 1)
                if pulses[2]:
                    self.clear()
            elif off == REG_STREAM_MASK and not st.busy:
                self.stream_mask = data & ((1 << self.streams) - 1)
            elif off == REG_STRIPE and not st.busy:
                self.drives = data & 0xF
                self.chunk = data >> 8 & 0xF
        elif kind[0] == "stream":
            _, s, off = kind
            if off == S_IN_TAIL:
                self.in_tail[s] = data
            elif off == S_OUT_TAIL:
                self.out_tail[s] = data
        return pulses

    def read(self, addr, st):
        kind = decode(addr, self.streams)
        if kind[0] == "global":
            off = kind[1]
            if off == REG_STATUS:
                ns = int(any(x & SS_NEED_SPACE for x in st.stream_status))
                return (st.busy * ST_BUSY | st.done * ST_DONE | st.err * ST_ERR | ns * ST_NEED_SPACE
                        | (st.state & 0xFF) << 8)
            return {REG_STREAM_MASK: self.stream_mask, REG_VERSION: LAYOUT_VERSION,
                    REG_RING_DEPTHS: RING_DEPTHS, REG_KERNEL_ID: self.kernel_id,
                    REG_STRIPE: self.drives | self.chunk << 8}.get(off, 0)
        if kind[0] == "stream":
            _, s, off = kind
            if off == S_IN_BYTES_LO:
                self.in_hi[s] = st.in_bytes[s] >> 32
            if off == S_OUT_BYTES_LO:
                self.out_hi[s] = st.out_bytes[s] >> 32
            return {S_IN_FILES: st.in_files[s], S_IN_TAIL: self.in_tail[s], S_IN_HEAD: st.in_head[s],
                    S_OUT_TAIL: self.out_tail[s], S_OUT_HEAD: st.out_head[s],
                    S_OUT_BYTES_LO: st.out_bytes[s] & 0xFFFFFFFF, S_OUT_BYTES_HI: self.out_hi[s],
                    S_STATUS: st.stream_status[s] & 0xF, S_ERR_INFO: st.err_info[s],
                    S_IN_BYTES_LO: st.in_bytes[s] & 0xFFFFFFFF, S_IN_BYTES_HI: self.in_hi[s]}.get(off, 0)
        return 0
