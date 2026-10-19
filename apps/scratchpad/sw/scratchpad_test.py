#!/usr/bin/env python3
# scratchpad_test.py: Host test of the scratchpad's shared HBM window through PF1 BAR0 of both PCIe endpoints
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

"""Writes through one endpoint's PF1 BAR0 and reads the same bytes back through the other's.

Both BARs map one HBM window; before every cross read the writer flushes its writes by reading its
own BAR. Exit code: 0 pass, 1 mismatch, 2 usage or I/O error.
"""

import argparse
import mmap
import os
import random
import sys
import time

DEFAULT_ROOT = "/sys/bus/pci/devices"
PAGE = 4096
CHUNK = 128


class BarError(Exception):
    pass


class Bar:
    """One memory BAR mapped through its sysfs resource file."""

    def __init__(self, name, path, size=None, access="memcpy"):
        self.name = name
        self.path = path
        self.access = access
        try:
            self.fd = os.open(path, os.O_RDWR | os.O_SYNC)
        except OSError as exc:
            raise BarError(f"{name}: cannot open {path}: {exc.strerror}") from exc
        real = os.fstat(self.fd).st_size
        self.size = size if size else real
        if real and self.size > real:
            os.close(self.fd)
            raise BarError(f"{name}: {path} has {real} B, asked for {self.size} B")
        if self.size <= 0:
            os.close(self.fd)
            raise BarError(f"{name}: {path} reports no size, pass --size")
        try:
            self.mm = mmap.mmap(self.fd, self.size, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE)
        except OSError as exc:
            os.close(self.fd)
            raise BarError(f"{name}: cannot mmap {path}: {exc.strerror}") from exc
        self.view = memoryview(self.mm)

    def close(self):
        self.view.release()
        self.mm.close()
        os.close(self.fd)

    def _words(self, off, n, width):
        """Split [off, off+n) into an unaligned head, whole ``width``-byte words and a tail."""
        head = min(n, (-off) % width)
        body = (n - head) // width * width
        return head, body, n - head - body

    def write(self, off, data):
        if off < 0 or off + len(data) > self.size:
            raise BarError(f"{self.name}: write {off:#x}+{len(data)} outside the {self.size:#x} B BAR")
        if self.access == "memcpy":
            self.view[off:off + len(data)] = data
            return
        width = 8 if self.access == "qword" else 4
        head, body, tail = self._words(off, len(data), width)
        self.view[off:off + head] = data[:head]
        fmt = "Q" if width == 8 else "I"
        words = self.view[off + head:off + head + body].cast(fmt)
        src = memoryview(data[head:head + body]).cast(fmt)
        for i in range(len(src)):
            words[i] = src[i]
        words.release()
        self.view[off + head + body:off + len(data)] = data[head + body:]

    def read(self, off, n):
        if off < 0 or off + n > self.size:
            raise BarError(f"{self.name}: read {off:#x}+{n} outside the {self.size:#x} B BAR")
        if self.access == "memcpy":
            return bytes(self.view[off:off + n])
        width = 8 if self.access == "qword" else 4
        head, body, tail = self._words(off, n, width)
        out = bytearray(self.view[off:off + head])
        fmt = "Q" if width == 8 else "I"
        words = self.view[off + head:off + head + body].cast(fmt)
        out += b"".join(words[i].to_bytes(width, "little") for i in range(len(words)))
        words.release()
        out += self.view[off + head + body:off + n]
        return bytes(out)

    def flush(self, off):
        """A read of this BAR: completes only after this endpoint's earlier writes reached HBM."""
        self.read(off & ~3, 4)


def pattern(kind, off, n, rng):
    if kind == "random":
        return rng.randbytes(n)
    if kind == "incr":
        return bytes((off + i) & 0xFF for i in range(n))
    if kind == "addr":
        words = ((off + i) // 4 for i in range(0, n + 4, 4))
        raw = b"".join((w * 0x9E3779B1 & 0xFFFFFFFF).to_bytes(4, "little") for w in words)
        return raw[off % 4:off % 4 + n]
    return bytes([int(kind, 16)]) * n


PATTERNS = ["random", "incr", "addr", "00", "ff", "a5", "5a"]


class Stats:
    def __init__(self):
        self.checks = 0
        self.bytes = 0
        self.fails = []
        self.t0 = time.monotonic()

    def record(self, test, writer, reader, off, data, got):
        self.checks += 1
        self.bytes += len(data)
        if got != data:
            first = next(i for i in range(len(data)) if got[i] != data[i])
            bad = sum(1 for a, b in zip(got, data) if a != b)
            self.fails.append(f"{test}: {writer.name} -> {reader.name} at {off:#x}+{len(data)}: {bad} bytes differ, "
                              f"first at {off + first:#x} wrote {data[first]:#04x} read {got[first]:#04x}")
            return False
        return True


def cross_check(test, writer, reader, off, data, st):
    writer.write(off, data)
    writer.flush(off)
    return st.record(test, writer, reader, off, data, reader.read(off, len(data)))


def boundary_offsets(size, rng, pages=4):
    """Offsets around 4 KB page ends and 128 B chunk edges, plus the window's first and last bytes."""
    offs = [0, size - 4, size - CHUNK, size - PAGE]
    for _ in range(pages):
        page = rng.randrange(1, size // PAGE - 2) * PAGE
        offs += [page - d for d in (1, 2, 4, 8, 64, 124, 128, 132)]
        offs += [page + c * CHUNK + d for c in (0, 1, 31) for d in (-4, -1, 0, 1, 4)]
    return sorted({o for o in offs if 0 <= o < size})


def test_boundaries(bars, rng, st, log):
    size = min(b.size for b in bars)
    lengths = [1, 2, 3, 4, 5, 7, 8, 64, 124, 128, 129, 132, 256, 1024, 4096, 4100, 8192]
    n = 0
    for off in boundary_offsets(size, rng):
        for ln in lengths:
            if off + ln > size:
                continue
            for w in (0, 1):
                data = pattern(rng.choice(PATTERNS), off, ln, rng)
                cross_check("boundary", bars[w], bars[1 - w], off, data, st)
                n += 1
    log(f"boundary: {n} cross checks around 4 KB pages and 128 B chunks")


def test_random(bars, rng, st, log, iterations, max_len):
    size = min(b.size for b in bars)
    for _ in range(iterations):
        ln = rng.choice([rng.randint(1, 16), rng.randint(1, 256), rng.randint(1, max_len)])
        off = rng.randrange(0, size - ln + 1)
        if rng.random() < 0.5:
            off &= ~3
        w = rng.randrange(2)
        cross_check("random", bars[w], bars[1 - w], off, pattern(rng.choice(PATTERNS), off, ln, rng), st)
    log(f"random: {iterations} cross checks, lengths up to {max_len} B")


def test_overwrite(bars, rng, st, log, rounds):
    """Both endpoints write the same block in turn; the later write must win for both readers."""
    size = min(b.size for b in bars)
    for _ in range(rounds):
        ln = rng.randint(1, 2 * PAGE)
        off = rng.randrange(0, size - ln + 1)
        first = rng.randrange(2)
        bars[first].write(off, pattern("random", off, ln, rng))
        bars[first].flush(off)
        data = pattern("random", off, ln, rng)
        bars[1 - first].write(off, data)
        bars[1 - first].flush(off)
        st.record("overwrite", bars[1 - first], bars[first], off, data, bars[first].read(off, ln))
        st.record("overwrite", bars[1 - first], bars[1 - first], off, data, bars[1 - first].read(off, ln))
    log(f"overwrite: {rounds} rounds of write-after-write from both endpoints")


def resource_path(root, bdf):
    if os.sep in bdf:
        return bdf
    if bdf.count(":") == 1:
        bdf = "0000:" + bdf
    return os.path.join(root, bdf, "resource0")


def parse_args(argv):
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("ep0", help="PCI address of endpoint 0's PF1 (e.g. 0000:c1:00.1) or a resource file path")
    p.add_argument("ep1", help="PCI address of endpoint 1's PF1 or a resource file path")
    p.add_argument("--root", default=DEFAULT_ROOT, help="sysfs PCI device directory (default %(default)s)")
    p.add_argument("--size", type=lambda x: int(x, 0), default=0,
                   help="bytes of the BAR to test (default: the whole resource)")
    p.add_argument("--iterations", type=int, default=2000, help="random cross checks (default %(default)s)")
    p.add_argument("--max-len", type=int, default=16384, help="longest random block in bytes (default %(default)s)")
    p.add_argument("--rounds", type=int, default=200, help="overwrite rounds (default %(default)s)")
    p.add_argument("--access", choices=["memcpy", "dword", "qword"], default="memcpy",
                   help="CPU access width to the BAR (default %(default)s)")
    p.add_argument("--seed", type=int, default=None, help="random seed (default: random, printed)")
    p.add_argument("--tests", default="boundary,random,overwrite", help="comma-separated tests to run")
    p.add_argument("-q", "--quiet", action="store_true", help="print only the summary")
    return p.parse_args(argv)


def main(argv=None):
    args = parse_args(argv if argv is not None else sys.argv[1:])
    seed = args.seed if args.seed is not None else random.SystemRandom().getrandbits(32)
    rng = random.Random(seed)
    log = (lambda msg: None) if args.quiet else (lambda msg: print(msg, flush=True))
    tests = [t.strip() for t in args.tests.split(",") if t.strip()]
    unknown = set(tests) - {"boundary", "random", "overwrite"}
    if unknown:
        print(f"error: unknown test(s) {sorted(unknown)}", file=sys.stderr)
        return 2
    bars = []
    try:
        for i, dev in enumerate((args.ep0, args.ep1)):
            bars.append(Bar(f"EP{i}", resource_path(args.root, dev), args.size, args.access))
        if bars[0].size != bars[1].size:
            log(f"note: BAR sizes differ ({bars[0].size:#x}, {bars[1].size:#x}), testing the smaller one")
        log(f"seed {seed}, EP0 {bars[0].path}, EP1 {bars[1].path}, {min(b.size for b in bars):#x} B, "
            f"access {args.access}")
        st = Stats()
        if "boundary" in tests:
            test_boundaries(bars, rng, st, log)
        if "random" in tests:
            test_random(bars, rng, st, log, args.iterations, min(args.max_len, min(b.size for b in bars)))
        if "overwrite" in tests:
            test_overwrite(bars, rng, st, log, args.rounds)
    except BarError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    finally:
        for b in bars:
            b.close()
    el = time.monotonic() - st.t0
    for f in st.fails[:20]:
        print(f"FAIL {f}")
    verdict = "PASS" if not st.fails else "FAIL"
    print(f"{verdict}: {st.checks} checks, {st.bytes} bytes compared, {len(st.fails)} mismatches, "
          f"{el:.1f} s, seed {seed}")
    return 0 if not st.fails else 1


if __name__ == "__main__":
    sys.exit(main())
