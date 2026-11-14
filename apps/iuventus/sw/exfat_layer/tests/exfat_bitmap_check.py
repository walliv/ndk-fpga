#!/usr/bin/env python3
# exfat_bitmap_check.py: independent exFAT owner walk comparing the allocation bitmap with its owners
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

"""Referee for leaked clusters, which fsck.exfat -n does not report. Input: a partition image."""

import argparse
import struct
import sys

EOC = 0xFFFFFFFF


class Volume:
    def __init__(self, path):
        self.f = open(path, "rb")
        boot = self.read(0, 512)
        if boot[3:11] != b"EXFAT   ":
            raise SystemExit("not an exFAT boot sector")
        self.fat_off = struct.unpack_from("<I", boot, 80)[0] * 512
        self.heap_off = struct.unpack_from("<I", boot, 88)[0] * 512
        self.count = struct.unpack_from("<I", boot, 92)[0]
        self.root = struct.unpack_from("<I", boot, 96)[0]
        self.flags = struct.unpack_from("<H", boot, 106)[0]
        self.cbytes = 512 << boot[109]
        self.fat_cache = {}

    def read(self, off, n):
        self.f.seek(off)
        data = self.f.read(n)
        return data + bytes(n - len(data))

    def fat(self, c):
        page = c // 1024
        if page not in self.fat_cache:
            self.fat_cache[page] = struct.unpack("<1024I", self.read(self.fat_off + page * 4096, 4096))
        return self.fat_cache[page][c % 1024]

    def chain(self, first, nbytes, no_fat, until_eoc=False):
        if first == 0 or (nbytes == 0 and not until_eoc):
            return []
        n = (nbytes + self.cbytes - 1) // self.cbytes
        if no_fat:
            return list(range(first, first + n))
        out, c = [], first
        while True:
            if not 2 <= c < self.count + 2 or len(out) > self.count:
                raise ValueError("broken FAT chain at %d" % c)
            out.append(c)
            nxt = self.fat(c)
            if until_eoc:
                if nxt == EOC:
                    return out
            elif len(out) == n:
                return out
            c = nxt

    def data(self, clusters, nbytes):
        buf = b"".join(self.read(self.heap_off + (c - 2) * self.cbytes, self.cbytes) for c in clusters)
        return buf[:nbytes]


def checksum16(data):
    s = 0
    for i, b in enumerate(data):
        if i in (2, 3):
            continue
        s = (((s & 1) << 15) + (s >> 1) + b) & 0xFFFF
    return s


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("--allow-dirty", action="store_true")
    ap.add_argument("--allow-unfinished", action="store_true")
    args = ap.parse_args()
    v = Volume(args.image)
    owners = {}
    problems = []

    def own(clusters, what):
        for c in clusters:
            if c in owners:
                problems.append("cluster %d owned by %s and %s" % (c, owners[c], what))
            owners[c] = what

    root = v.chain(v.root, 0, False, until_eoc=True)
    own(root, "/")
    bitmap_clusters, bitmap_len = None, 0
    stack = [("/", v.data(root, len(root) * v.cbytes), True)]
    files = dirs = unfinished = 0
    while stack:
        path, data, is_root = stack.pop()
        i = 0
        while i < len(data) // 32:
            e = data[i * 32:(i + 1) * 32]
            t = e[0]
            if t == 0:
                break
            if not t & 0x80:
                i += 1
                continue
            if is_root and t == 0x81:
                first, length = struct.unpack_from("<IQ", e, 20)
                bitmap_clusters, bitmap_len = v.chain(first, length, False), length
                own(bitmap_clusters, "$bitmap")
                i += 1
            elif is_root and t == 0x82:
                first, length = struct.unpack_from("<IQ", e, 20)
                own(v.chain(first, length, False), "$upcase")
                i += 1
            elif t == 0x85:
                sc = e[1]
                es = data[i * 32:(i + 1 + sc) * 32]
                if checksum16(es) != struct.unpack_from("<H", es, 2)[0]:
                    problems.append("%s: entry set checksum at %d" % (path, i))
                attr = struct.unpack_from("<H", es, 4)[0]
                access = struct.unpack_from("<I", es, 16)[0]
                st = es[32:64]
                flags, name_len = st[1], st[3]
                valid = struct.unpack_from("<Q", st, 8)[0]
                first, length = struct.unpack_from("<IQ", st, 20)
                raw_name = b"".join(es[64 + 32 * k + 2:64 + 32 * k + 32] for k in range(sc - 1))
                name = raw_name[:2 * name_len].decode("utf-16-le", "replace")
                full = path.rstrip("/") + "/" + name
                clusters = v.chain(first, length, bool(flags & 2)) if flags & 1 else []
                own(clusters, full)
                if attr & 0x10:
                    dirs += 1
                    stack.append((full, v.data(clusters, length), False))
                else:
                    files += 1
                    if access == 0 and valid == 0:
                        unfinished += 1
                        if not args.allow_unfinished:
                            problems.append("unfinished output left: " + full)
                i += 1 + sc
            else:
                i += 1 + (e[1] if not t & 0x40 else 0)
    if bitmap_clusters is None:
        raise SystemExit("no allocation bitmap")
    bitmap = v.data(bitmap_clusters, bitmap_len)
    leaked = missing = 0
    for c in range(2, v.count + 2):
        bit = (bitmap[(c - 2) >> 3] >> ((c - 2) & 7)) & 1
        if bit and c not in owners:
            leaked += 1
        elif not bit and c in owners:
            missing += 1
    if leaked:
        problems.append("%d leaked clusters" % leaked)
    if missing:
        problems.append("%d owned clusters marked free" % missing)
    if v.flags & 2 and not args.allow_dirty:
        problems.append("VolumeDirty is set")
    print("bitmap-check: dirs %d files %d unfinished %d owned %d leaked %d missing %d dirty %d" %
          (dirs, files, unfinished, len(owners), leaked, missing, (v.flags >> 1) & 1))
    for p in problems:
        print("bitmap-check: " + p)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
