#!/usr/bin/env python3
# test_scratchpad_test.py: Unit tests of scratchpad_test.py against mmap-able files standing in for the BARs
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

"""Both "BARs" point at one file to model the shared window; separate files, a corrupting reader and
an out-of-range size model the failures the tool must report. Run: python3 -m unittest test_scratchpad_test"""

import contextlib
import io
import os
import random
import tempfile
import unittest

import scratchpad_test as sp

SIZE = 1 << 20


def make_dev(root, bdf, path=None, size=SIZE):
    d = os.path.join(root, bdf)
    os.makedirs(d)
    res = os.path.join(d, "resource0")
    if path is None:
        with open(res, "wb") as f:
            f.truncate(size)
    else:
        os.symlink(path, res)
    return res


class ScratchpadToolTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def run_tool(self, *args):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            rc = sp.main(list(args))
        return rc, out.getvalue()

    def shared_pair(self):
        res0 = make_dev(self.root, "0000:c1:00.1")
        make_dev(self.root, "0000:c2:00.1", path=res0)
        return "0000:c1:00.1", "c2:00.1"

    def test_shared_window_passes(self):
        ep0, ep1 = self.shared_pair()
        for access in ("memcpy", "dword", "qword"):
            rc, out = self.run_tool(ep0, ep1, "--root", self.root, "--iterations", "300", "--rounds", "30",
                                    "--seed", "7", "--access", access)
            self.assertEqual(rc, 0, out)
            self.assertIn("PASS", out)
            self.assertIn("0 mismatches", out)

    def test_separate_memories_fail(self):
        make_dev(self.root, "0000:c1:00.1")
        make_dev(self.root, "0000:c2:00.1")
        rc, out = self.run_tool("0000:c1:00.1", "0000:c2:00.1", "--root", self.root, "--iterations", "50",
                                "--rounds", "5", "--seed", "3")
        self.assertEqual(rc, 1, out)
        self.assertIn("FAIL", out)

    def test_single_corrupted_byte_is_found(self):
        ep0, ep1 = self.shared_pair()
        bars = [sp.Bar("EP0", sp.resource_path(self.root, ep0)), sp.Bar("EP1", sp.resource_path(self.root, ep1))]
        real_read = sp.Bar.read

        def bad_read(self_, off, n):
            data = bytearray(real_read(self_, off, n))
            if self_.name == "EP1" and n > 4 and off <= 0x1234 < off + n:
                data[0x1234 - off] ^= 0x10
            return bytes(data)

        st = sp.Stats()
        try:
            sp.Bar.read = bad_read
            ok = sp.cross_check("unit", bars[0], bars[1], 0x1200, bytes(range(256)) * 2, st)
        finally:
            sp.Bar.read = real_read
            for b in bars:
                b.close()
        self.assertFalse(ok)
        self.assertEqual(len(st.fails), 1)
        self.assertIn("first at 0x1234", st.fails[0])

    def test_word_access_splits_unaligned(self):
        ep0, _ = self.shared_pair()
        for access in ("dword", "qword"):
            b = sp.Bar("EP0", sp.resource_path(self.root, ep0), access=access)
            try:
                for off, n in ((1, 1), (3, 10), (6, 3), (4096 - 5, 13), (0, 64), (7, 129)):
                    data = random.Random(off * n).randbytes(n)
                    b.write(off, data)
                    self.assertEqual(b.read(off, n), data)
                    self.assertEqual(bytes(b.view[off:off + n]), data)
            finally:
                b.close()

    def test_boundary_offsets_cover_pages_and_chunks(self):
        offs = sp.boundary_offsets(SIZE, random.Random(1))
        self.assertIn(0, offs)
        self.assertIn(SIZE - 4, offs)
        self.assertTrue(any((o + 4) % sp.PAGE == 0 for o in offs))
        self.assertTrue(any(o % sp.CHUNK == 0 and o % sp.PAGE for o in offs))
        self.assertTrue(all(0 <= o < SIZE for o in offs))

    def test_patterns(self):
        rng = random.Random(0)
        for kind in sp.PATTERNS:
            for off, n in ((0, 1), (3, 17), (4095, 9)):
                self.assertEqual(len(sp.pattern(kind, off, n, rng)), n)
        self.assertEqual(sp.pattern("a5", 0, 3, rng), b"\xa5\xa5\xa5")
        self.assertEqual(sp.pattern("addr", 2, 4, rng), sp.pattern("addr", 0, 8, rng)[2:6])

    def test_errors_exit_2(self):
        rc, out = self.run_tool("0000:99:00.1", "0000:98:00.1", "--root", self.root)
        self.assertEqual(rc, 2, out)
        self.assertIn("cannot open", out)
        ep0, ep1 = self.shared_pair()
        rc, out = self.run_tool(ep0, ep1, "--root", self.root, "--size", str(2 * SIZE))
        self.assertEqual(rc, 2, out)
        rc, out = self.run_tool(ep0, ep1, "--root", self.root, "--tests", "bogus")
        self.assertEqual(rc, 2, out)

    def test_resource_path(self):
        self.assertEqual(sp.resource_path("/r", "c1:00.1"), "/r/0000:c1:00.1/resource0")
        self.assertEqual(sp.resource_path("/r", "0000:c1:00.1"), "/r/0000:c1:00.1/resource0")
        self.assertEqual(sp.resource_path("/r", "/x/res"), "/x/res")


if __name__ == "__main__":
    unittest.main()
