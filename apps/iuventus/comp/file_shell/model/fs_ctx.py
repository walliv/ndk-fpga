# fs_ctx.py: the file shell's constants, ring entry and read context layouts, as fs_pkg.vhd defines them
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0
"""Constants, bit layouts and small bit helpers shared by the models and benches; fs_pkg.vhd is the
reference."""

from dataclasses import dataclass

MASK32 = (1 << 32) - 1
MASK64 = (1 << 64) - 1

MAX_STREAMS = 8
STREAM_W = 3
FSLOT_W = 6
FSLOTS = 1 << FSLOT_W
INDEX_W = 32
FOFS_W = 48
COFS_W = 64
VBYTES_W = 18
CTX_W = STREAM_W + FSLOT_W + INDEX_W + FOFS_W + COFS_W + VBYTES_W
TAG_W = 6
LBA_W = 48
SECT = 512
BEAT = 64
# One beat of the HBM port.
AXI_BEAT = 32
MAX_LOG2_CHUNK = 8
MAX_LOG2_DRIVES = 2
# The stripe geometry fs_regs.vhd resets to.
STRIPE_RST_DRIVES, STRIPE_RST_CHUNK = 2, 8

# DMA operation status codes.
CODE_OK, CODE_FAIL, CODE_OOR, CODE_LOST = 0, 1, 2, 3

# ERR_INFO sources.
ERR_SRC_NVME, ERR_SRC_FORMAT, ERR_SRC_ABORT, ERR_SRC_HBM = 0, 1, 2, 3

# Ring entry: word k = bits 32k+31..32k.
ENTRY_BYTES = 16
ENT_EXTENT, ENT_FILE = 0, 1
WORD2_LO, TYPE_LO, RSVD_LO, LAST_BIT = 64, 96, 98, 127
LAST = 1 << LAST_BIT

# MI register map (byte offsets within the shell's window).
DECODE_MASK = (1 << 25) - 1
REG_CTRL, REG_STATUS, REG_STREAM_MASK, REG_VERSION, REG_RING_DEPTHS, REG_KERNEL_ID, REG_STRIPE = \
    0x00, 0x04, 0x08, 0x0C, 0x10, 0x14, 0x18
CTRL_START_BIT, CTRL_ABORT_BIT, CTRL_CLEAR_BIT = 0, 1, 2
CTRL_START, CTRL_ABORT, CTRL_CLEAR = 1 << CTRL_START_BIT, 1 << CTRL_ABORT_BIT, 1 << CTRL_CLEAR_BIT
ST_BUSY, ST_DONE, ST_ERR, ST_NEED_SPACE = 1, 2, 4, 8
LAYOUT_VERSION = 1

STREAM_BASE, STREAM_STRIDE = 0x100, 0x40
S_IN_FILES, S_IN_TAIL, S_IN_HEAD, S_OUT_TAIL, S_OUT_HEAD = 0x00, 0x08, 0x0C, 0x10, 0x14
S_OUT_BYTES_LO, S_OUT_BYTES_HI, S_STATUS, S_ERR_INFO, S_IN_BYTES_LO, S_IN_BYTES_HI = \
    0x18, 0x1C, 0x20, 0x24, 0x28, 0x2C
SS_IN_DONE, SS_OUT_DONE, SS_NEED_SPACE, SS_ERR = 1, 2, 4, 8

ARGS_BASE, ARGS_STRIDE = 0x1000, 0x200

IN_RING_LOG2, OUT_RING_LOG2 = 16, 14
RING_MI_BASE = OUT_RING_BASE = 0x80_0000
IN_RING_BASE = 0x100_0000
IN_RING_STRIDE = ENTRY_BYTES << IN_RING_LOG2
OUT_RING_STRIDE = ENTRY_BYTES << OUT_RING_LOG2


@dataclass(frozen=True)
class Ctx:
    stream: int
    fslot: int
    fidx: int
    fofs: int
    cofs: int
    vbytes: int

    def pack(self) -> int:
        v = self.stream
        v = (v << FSLOT_W) | self.fslot
        v = (v << INDEX_W) | self.fidx
        v = (v << FOFS_W) | self.fofs
        v = (v << COFS_W) | self.cofs
        v = (v << VBYTES_W) | self.vbytes
        return v

    @staticmethod
    def unpack(v: int) -> "Ctx":
        vbytes = v & ((1 << VBYTES_W) - 1)
        v >>= VBYTES_W
        cofs = v & ((1 << COFS_W) - 1)
        v >>= COFS_W
        fofs = v & ((1 << FOFS_W) - 1)
        v >>= FOFS_W
        fidx = v & ((1 << INDEX_W) - 1)
        v >>= INDEX_W
        fslot = v & ((1 << FSLOT_W) - 1)
        v >>= FSLOT_W
        return Ctx(stream=v & ((1 << STREAM_W) - 1), fslot=fslot, fidx=fidx, fofs=fofs, cofs=cofs,
                   vbytes=vbytes)


def err_info(src: int, code: int, is_read: int, drive: int, cid: int) -> int:
    """fs_err_info_f."""
    return (code & 3) | ((is_read & 1) << 2) | ((drive & 0xF) << 4) | ((src & 0xF) << 8) | ((cid & 0xFFFF) << 16)


def file_entry(size: int, index: int, last: bool = False, rsvd: int = 0, etype: int = ENT_FILE) -> int:
    return ((size & MASK64) | ((index & MASK32) << WORD2_LO) | (etype << TYPE_LO) | (rsvd << RSVD_LO)
            | (int(last) << LAST_BIT))


def extent_entry(lba: int, count: int, last: bool = False, rsvd: int = 0, etype: int = ENT_EXTENT,
                 hi: int = 0) -> int:
    return ((lba & ((1 << LBA_W) - 1)) | ((hi & 0xFFFF) << LBA_W) | ((count & MASK32) << WORD2_LO)
            | (etype << TYPE_LO) | (rsvd << RSVD_LO) | (int(last) << LAST_BIT))


def decode_entry(ent: int) -> dict:
    """The fields of a ring entry, both views: `lba`/`lba_hi`/`count` of an EXTENT, `size`/`index` of a FILE."""
    return {"type": (ent >> TYPE_LO) & 3, "last": (ent >> LAST_BIT) & 1,
            "rsvd": (ent >> RSVD_LO) & ((1 << (LAST_BIT - RSVD_LO)) - 1),
            "lba": ent & ((1 << LBA_W) - 1), "lba_hi": (ent >> LBA_W) & 0xFFFF,
            "count": (ent >> WORD2_LO) & MASK32, "size": ent & MASK64, "index": (ent >> WORD2_LO) & MASK32}


def rsvd_bit(rng) -> int:
    """A random reserved bit of a ring entry, set."""
    return 1 << rng.randint(RSVD_LO, LAST_BIT - 1)


def lba_hi_bit(rng) -> int:
    """A random bit of an EXTENT's LBA word above the 48 LBA bits, set."""
    return 1 << rng.randint(LBA_W, 63)


def lbas_needed(nbytes: int) -> int:
    """LBAs that hold `nbytes`."""
    return -(-nbytes // SECT)


def sector(data: bytes, i: int) -> bytes:
    """The i-th LBA of `data`."""
    return data[SECT * i:SECT * (i + 1)]


def entry_words(ent: int) -> list:
    """A ring entry as the host writes it over MI: four 32-bit words, lowest first."""
    return [(ent >> (32 * w)) & MASK32 for w in range(ENTRY_BYTES // 4)]


def stripe_drive(lba: int, log2_drives: int, log2_chunk: int) -> int:
    """fs_stripe_drive_f."""
    return (lba >> log2_chunk) % (1 << log2_drives)


def stripe_drive_lba(lba: int, log2_drives: int, log2_chunk: int) -> int:
    """fs_stripe_drive_lba_f."""
    row = (lba >> log2_chunk) >> log2_drives
    return (row << log2_chunk) | (lba % (1 << log2_chunk))


def stripe_map(lba: int, log2_drives: int, log2_chunk: int) -> tuple:
    """(drive, drive LBA) of logical `lba`."""
    return stripe_drive(lba, log2_drives, log2_chunk), stripe_drive_lba(lba, log2_drives, log2_chunk)


def merge_be(old: int, new: int, be: int, nbytes: int = 4) -> int:
    """`old` with the bytes `be` selects replaced by those of `new`."""
    o, n = old.to_bytes(nbytes, "little"), new.to_bytes(nbytes, "little")
    return int.from_bytes(bytes(n[b] if be >> b & 1 else o[b] for b in range(nbytes)), "little")
