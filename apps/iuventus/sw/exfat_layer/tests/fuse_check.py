#!/usr/bin/env python3
# fuse_check.py: random file operations on an iuv-fs mount, checked against a shadow copy on the host
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import argparse
import os
import random
import shutil
import subprocess
import sys
import threading

MIB = 1 << 20


def fail(msg):
    raise SystemExit("FAIL: " + msg)


def read_all(path):
    with open(path, "rb") as f:
        return f.read()


class Checker:
    def __init__(self, mnt, shadow, rng):
        self.mnt = mnt
        self.shadow = shadow
        self.rng = rng
        self.files = {}
        self.dirs = {""}

    def m(self, rel):
        return os.path.join(self.mnt, rel)

    def s(self, rel):
        return os.path.join(self.shadow, rel)

    def payload(self, n):
        return self.rng.randbytes(n)

    def size(self):
        # Sizes straddle LBA, block, stage and cluster boundaries.
        return self.rng.choice([0, 1, 511, 512, 4095, 4096, 4097, 65536, 131073, 524288, 524289,
                                4 * MIB - 1, 4 * MIB, 4 * MIB + 7, 9 * MIB + 3, self.rng.randrange(1, 12 * MIB)])

    def new_name(self):
        d = self.rng.choice(sorted(self.dirs))
        while True:
            rel = os.path.join(d, "f%05d.bin" % self.rng.randrange(100000))
            if rel.upper() not in {k.upper() for k in self.files}:
                return rel

    def both(self, rel, mode, fn):
        for root in (self.mnt, self.shadow):
            with open(os.path.join(root, rel), mode) as f:
                fn(f)

    def write_sequential(self):
        rel = self.new_name()
        data = self.payload(self.size())
        with open(self.m(rel), "wb") as f:
            pos = 0
            while pos < len(data):
                n = self.rng.choice([1, 100, 4096, 65536, MIB, 3 * MIB + 5])
                f.write(data[pos:pos + n])
                pos += n
        with open(self.s(rel), "wb") as f:
            f.write(data)
        self.files[rel] = True
        return "seq " + rel

    def write_random(self):
        rel = self.rng.choice(sorted(self.files)) if self.files and self.rng.random() < 0.6 else self.new_name()
        if rel not in self.files:
            open(self.m(rel), "wb").close()
            open(self.s(rel), "wb").close()
            self.files[rel] = True
        ops = []
        size = os.path.getsize(self.s(rel))
        for _ in range(self.rng.randrange(1, 12)):
            off = self.rng.randrange(0, size + 2 * MIB)
            ops.append((off, self.payload(self.rng.choice([1, 777, 4096, 70000, MIB + 13]))))
        for root in (self.mnt, self.shadow):
            with open(os.path.join(root, rel), "r+b") as f:
                for off, data in ops:
                    f.seek(off)
                    f.write(data)
        return "random %s (%d writes)" % (rel, len(ops))

    def append(self):
        if not self.files:
            return self.write_sequential()
        rel = self.rng.choice(sorted(self.files))
        data = self.payload(self.rng.choice([1, 10, 5000, MIB + 1]))
        self.both(rel, "ab", lambda f: f.write(data))
        return "append " + rel

    def truncate(self):
        if not self.files:
            return self.write_sequential()
        rel = self.rng.choice(sorted(self.files))
        n = self.rng.choice([0, 1, 4095, os.path.getsize(self.s(rel)) // 2, os.path.getsize(self.s(rel)) + 3 * MIB + 1])
        for root in (self.mnt, self.shadow):
            os.truncate(os.path.join(root, rel), n)
        return "truncate %s %d" % (rel, n)

    def move(self):
        if not self.files:
            return self.write_sequential()
        rel = self.rng.choice(sorted(self.files))
        if self.rng.random() < 0.2:
            # Only the case of the name changes.
            head, name = os.path.split(rel)
            dst = os.path.join(head, "".join(ch.swapcase() if self.rng.random() < 0.5 else ch for ch in name))
            if dst == rel:
                return "mv skipped"
        else:
            dst = self.new_name()
        if self.rng.random() < 0.5:
            subprocess.run(["mv", "-T", self.m(rel), self.m(dst)], check=True)
        else:
            os.rename(self.m(rel), self.m(dst))
        os.rename(self.s(rel), self.s(dst))
        del self.files[rel]
        self.files[dst] = True
        return "mv %s %s" % (rel, dst)

    def replace(self):
        if len(self.files) < 2:
            return self.write_sequential()
        rel, dst = self.rng.sample(sorted(self.files), 2)
        os.replace(self.m(rel), self.m(dst))
        os.replace(self.s(rel), self.s(dst))
        del self.files[rel]
        return "replace %s %s" % (rel, dst)

    def move_dir(self):
        dirs = sorted(d for d in self.dirs if d)
        if not dirs:
            return self.mkdir()
        rel = self.rng.choice(dirs)
        parents = [d for d in self.dirs if d != rel and not d.startswith(rel + "/")]
        dst = os.path.join(self.rng.choice(sorted(parents)), "m%03d" % self.rng.randrange(1000))
        taken = {p.upper() for p in list(self.files) + list(self.dirs)}
        if dst.upper() in taken:
            return "mv dir skipped"
        os.rename(self.m(rel), self.m(dst))
        os.rename(self.s(rel), self.s(dst))

        def moved(p):
            return dst + p[len(rel):] if p == rel or p.startswith(rel + "/") else p
        self.files = {moved(p): True for p in self.files}
        self.dirs = {moved(d) for d in self.dirs}
        return "mv dir %s %s" % (rel, dst)

    def unlink(self):
        if not self.files:
            return self.write_sequential()
        rel = self.rng.choice(sorted(self.files))
        os.unlink(self.m(rel))
        os.unlink(self.s(rel))
        del self.files[rel]
        return "rm " + rel

    def mkdir(self):
        rel = os.path.join(self.rng.choice(sorted(self.dirs)), "d%03d" % self.rng.randrange(1000))
        if rel.upper() in {d.upper() for d in self.dirs}:
            return "mkdir skipped"
        os.mkdir(self.m(rel))
        os.mkdir(self.s(rel))
        self.dirs.add(rel)
        return "mkdir " + rel

    def rmdir(self):
        empty = [d for d in self.dirs if d and not any(os.path.dirname(p) == d for p in list(self.files) + list(self.dirs))]
        if not empty:
            return self.mkdir()
        rel = self.rng.choice(sorted(empty))
        os.rmdir(self.m(rel))
        os.rmdir(self.s(rel))
        self.dirs.discard(rel)
        return "rmdir " + rel

    def parallel(self):
        jobs = [(self.new_name(), self.payload(self.size())) for _ in range(4)]
        names = {rel for rel, _ in jobs}
        if len(names) < len(jobs):
            return "parallel skipped"

        def writer(rel, data):
            with open(self.m(rel), "wb") as f:
                for pos in range(0, len(data), MIB):
                    f.write(data[pos:pos + MIB])
        threads = [threading.Thread(target=writer, args=j) for j in jobs]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        for rel, data in jobs:
            with open(self.s(rel), "wb") as f:
                f.write(data)
            self.files[rel] = True
        return "parallel %d writers" % len(jobs)

    def verify(self, what):
        listed = set()
        for d in self.dirs:
            for name in os.listdir(self.m(d)):
                if name != ".iuv-job":
                    listed.add(os.path.join(d, name))
        want = set(self.files) | {d for d in self.dirs if d}
        if listed != want:
            fail("after %s: listing differs: extra %s, missing %s" % (what, sorted(listed - want), sorted(want - listed)))
        for rel in self.files:
            a, b = read_all(self.m(rel)), read_all(self.s(rel))
            if os.path.getsize(self.m(rel)) != len(b):
                fail("after %s: stat size of %s is %d, expected %d" % (what, rel, os.path.getsize(self.m(rel)), len(b)))
            if a != b:
                at = next((i for i in range(min(len(a), len(b))) if a[i] != b[i]), min(len(a), len(b)))
                fail("after %s: %s differs at byte %d (sizes %d, %d)" % (what, rel, at, len(a), len(b)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mnt")
    ap.add_argument("shadow")
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("--steps", type=int, default=120)
    a = ap.parse_args()
    seed = a.seed if a.seed is not None else random.SystemRandom().randrange(1 << 32)
    print("fuse_check seed %d (replay with --seed %d)" % (seed, seed), flush=True)
    shutil.rmtree(a.shadow, ignore_errors=True)
    os.makedirs(a.shadow)
    c = Checker(a.mnt, a.shadow, random.Random(seed))
    ops = [c.write_sequential] * 4 + [c.write_random] * 3 + [c.append] * 2 + [c.truncate] * 2 + \
          [c.move] * 2 + [c.replace, c.move_dir, c.unlink, c.mkdir, c.rmdir, c.parallel]
    for step in range(a.steps):
        what = c.rng.choice(ops)()
        c.verify("step %d: %s" % (step, what))
    try:
        os.unlink(c.m(os.path.join(c.rng.choice(sorted(c.dirs)), "missing.bin")))
        fail("unlink of a missing file succeeded")
    except FileNotFoundError:
        pass
    # An unlinked file stays readable through a handle opened before; its name is gone at once and free after close.
    rel = c.write_sequential().split()[1]
    want = read_all(c.s(rel))
    with open(c.m(rel), "rb") as f:
        os.unlink(c.m(rel))
        if os.path.exists(c.m(rel)):
            fail("unlinked open file still listed: " + rel)
        if f.read() != want:
            fail("open handle of an unlinked file reads wrong data: " + rel)
    os.unlink(c.s(rel))
    del c.files[rel]
    with open(c.m(rel), "wb") as f:
        f.write(b"again")
    if read_all(c.m(rel)) != b"again":
        fail("name of an unlinked file not reusable: " + rel)
    os.unlink(c.m(rel))
    c.verify("unlink while open")
    # A file renamed while open for writing keeps its handle, and a target replaced while open stays readable through it.
    moving = c.write_sequential().split()[1]
    target = c.write_sequential().split()[1]
    want = read_all(c.s(target))
    with open(c.m(target), "rb") as ft, open(c.m(moving), "r+b") as fm:
        os.rename(c.m(moving), c.m(target))
        fm.seek(0, os.SEEK_END)
        fm.write(b"tail")
        if ft.read() != want:
            fail("open handle of a replaced file reads wrong data: " + target)
    os.rename(c.s(moving), c.s(target))
    with open(c.s(target), "ab") as f:
        f.write(b"tail")
    del c.files[moving]
    c.verify("rename over an open file")
    # Names differing in a non-ASCII case are one file, also while it is open for writing.
    lower, upper = c.m("été.bin"), c.m("ÉTÉ.BIN")
    with open(lower, "wb") as fl:
        fl.write(b"abc")
        fl.flush()
        with open(upper, "r+b") as fu:
            fu.seek(3)
            fu.write(b"def")
    os.unlink(upper)
    c.verify("one file under two cases")
    # A read handle follows the file: it sees another handle's append and none of the clusters a truncate freed.
    rel, data, tail = c.new_name(), c.payload(8 * MIB), c.payload(3 * MIB)
    c.both(rel, "wb", lambda f: f.write(data))
    c.files[rel] = True
    with open(c.m(rel), "rb", buffering=0) as r:
        if r.read() != data:
            fail("read handle reads wrong data: " + rel)
        c.both(rel, "ab", lambda f: f.write(tail))
        if r.read() != tail:
            fail("read handle misses another handle's append: " + rel)
        for root in (c.mnt, c.shadow):
            os.truncate(os.path.join(root, rel), 0)
        if os.pread(r.fileno(), 16, 4 * MIB) != b"":
            fail("read handle reads past a truncate: " + rel)
    c.verify("read handle across append and truncate")
    # An unlinked file stays usable through a handle opened for writing after it was closed; lseek asks with the handle.
    rel = c.write_sequential().split()[1]
    fd = os.open(c.m(rel), os.O_RDWR)
    try:
        os.unlink(c.m(rel))
        os.ftruncate(fd, 100)
        if os.lseek(fd, 0, os.SEEK_END) != 100:
            fail("ftruncate of an unlinked open file did not take: " + rel)
    finally:
        os.close(fd)
    os.unlink(c.s(rel))
    del c.files[rel]
    c.verify("fstat and ftruncate after unlink")
    print("fuse_check: %d steps, %d files, %d directories OK" % (a.steps, len(c.files), len(c.dirs) - 1))


if __name__ == "__main__":
    main()
