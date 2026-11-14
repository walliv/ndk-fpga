# fs_kernel_digest_fill_model.py: reference model of kernel 1 (DIGEST_FILL) of the file shell
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

"""Two independent references: `file_digest` works on whole files, `BeatDigest` on the beats the
shell delivers. A bench feeding beats checks the RTL against `file_digest`, and `BeatDigest`
against it too, so a beat-splitting error in the bench cannot hide behind the model."""

import struct

from fs_ctx import BEAT, MASK32, MASK64

MAGIC = 0x31474944
RECORD_BYTES = 32


def word_c(word, offset, fidx):
    return (word ^ offset ^ ((fidx << 40) & MASK64)) & MASK64


def file_digest(files):
    """files: list of (fidx, bytes). Returns (in_bytes, sum, xor, file count)."""
    total = s = x = 0
    for fidx, data in files:
        total += len(data)
        padded = data + bytes((-len(data)) % 8)
        for o in range(0, len(padded), 8):
            c = word_c(int.from_bytes(padded[o:o + 8], "little"), o, fidx)
            s = (s + c) & MASK64
            x ^= c
    return total & MASK64, s, x, len(files)


class BeatDigest:
    """Accumulates beats exactly as the kernel's interface defines them."""

    def __init__(self):
        self.total = self.sum = self.xor = 0

    def beat(self, data, nbytes, fidx, fofs):
        assert 1 <= nbytes <= BEAT and fofs % BEAT == 0
        data = bytes(data[:nbytes]) + bytes(BEAT - nbytes)
        for k in range(0, BEAT, 8):
            if k >= nbytes:
                break
            c = word_c(int.from_bytes(data[k:k + 8], "little"), fofs + k, fidx)
            self.sum = (self.sum + c) & MASK64
            self.xor ^= c
        self.total = (self.total + nbytes) & MASK64


def file_beats(fidx, data):
    """The beats a shell delivers for one file: (data, nbytes, fidx, fofs), in file order."""
    out = []
    for fofs in range(0, len(data), BEAT):
        chunk = data[fofs:fofs + BEAT]
        out.append((chunk + bytes(BEAT - len(chunk)), len(chunk), fidx, fofs))
    return out


def pattern_bytes(fill_bytes, seed):
    """FILL_BYTES (a multiple of 64) of pattern: word j = ((j ^ seed) << 32) | j, j mod 2**32."""
    assert fill_bytes % BEAT == 0
    out = bytearray()
    for j in range(fill_bytes // 8):
        jl = j & MASK32
        out += struct.pack("<II", jl, (jl ^ seed) & MASK32)
    return bytes(out)


def record_bytes(in_bytes, s, x, files):
    return struct.pack("<QQQII", in_bytes & MASK64, s & MASK64, x & MASK64, files & MASK32, MAGIC)


def arg_err(fill_bytes):
    """Invalid job arguments: the kernel raises ARG_ERR and its output content is unspecified."""
    return fill_bytes % BEAT != 0


def output_beats(fill_bytes, seed, digest):
    """Expected output beats: [(data 64 B, nbytes, last)]; the record is the only partial beat."""
    pat = pattern_bytes(fill_bytes, seed)
    beats = [(pat[i:i + BEAT], BEAT, False) for i in range(0, len(pat), BEAT)]
    rec = record_bytes(*digest)
    beats.append((rec + bytes(BEAT - RECORD_BYTES), RECORD_BYTES, True))
    return beats
