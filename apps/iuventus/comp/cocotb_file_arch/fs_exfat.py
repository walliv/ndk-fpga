# fs_exfat.py: stage B of the file shell bench, a job against a real exFAT image via iuv-exfat
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0
"""The host library's CLI builds and finalizes the volume; the image is striped onto the bench's
four drive arrays for the job and merged back afterwards, so fsck.exfat and `get` judge the result
independently of the bench's own model."""

import os
import subprocess

import fs_ctx as fc

# The iuv-exfat binary of a sw/exfat_layer build; without it the stage is skipped.
IUV_EXFAT = os.environ.get("IUV_EXFAT", "")
IMAGE_BYTES = 256 << 20
PART_SKIP_MIB = 1


def available():
    return os.access(IUV_EXFAT, os.X_OK)


def run(*args, check=True):
    # The simulator's LD_LIBRARY_PATH carries the Python env's older libstdc++, which the host tool must not load.
    env = {k: v for k, v in os.environ.items() if k != "LD_LIBRARY_PATH"}
    res = subprocess.run(list(map(str, args)), capture_output=True, text=True, env=env)
    if check and res.returncode:
        raise AssertionError(f"{' '.join(map(str, args))} failed ({res.returncode}): {res.stderr.strip()}")
    return res


class ExfatImage:
    def __init__(self, workdir, rng):
        self.dir = workdir
        self.rng = rng
        self.path = os.path.join(workdir, "volume.img")
        with open(self.path, "wb") as f:
            f.truncate(IMAGE_BYTES)
        run("mkfs.exfat", "-q", "-P", "gpt", "-c", "512K", "-b", "1M", self.path)
        self.n = 0

    def cli(self, *args):
        return run(IUV_EXFAT, args[0], self.path, *args[1:]).stdout

    def put(self, data, name):
        host = os.path.join(self.dir, f"host_{self.n}.bin")
        self.n += 1
        with open(host, "wb") as f:
            f.write(data)
        self.cli("put", host, name)

    def fragment(self, files):
        """Fill the heap with small files and remove every other, so later files take FAT chains."""
        for i in range(files):
            self.put(self.rng.randbytes(self.rng.randint(1, 3) * 524288 - self.rng.randint(0, 9000)), f"/fill{i}")
        for i in range(0, files, 2):
            self.cli("rm", f"/fill{i}")

    def extents(self, name):
        lines = self.cli("extents", name).split("\n")
        assert lines[0].startswith("size "), f"extents {name}: {lines[0]!r}"
        size = int(lines[0].split()[1])
        return size, [tuple(map(int, ln.split())) for ln in lines[1:] if ln.strip()]

    def reserve(self, name, nbytes):
        out = self.cli("reserve", name, nbytes)
        return [tuple(map(int, ln.split())) for ln in out.split("\n") if ln.strip()]

    def finalize(self, name, nbytes):
        self.cli("finalize", name, nbytes)

    def get(self, name):
        host = os.path.join(self.dir, f"get_{self.n}.bin")
        self.n += 1
        self.cli("get", name, host)
        with open(host, "rb") as f:
            return f.read()

    # Striping the image onto the drives and back ------------------------------------------------
    def load_extents(self, storage, extents, ld=fc.STRIPE_RST_DRIVES, lc=fc.STRIPE_RST_CHUNK):
        with open(self.path, "rb") as f:
            for lba, cnt in extents:
                f.seek(lba * fc.SECT)
                data = f.read(cnt * fc.SECT)
                for i in range(cnt):
                    storage[fc.stripe_map(lba + i, ld, lc)] = fc.sector(data, i)

    def merge_extents(self, storage, extents, ld=fc.STRIPE_RST_DRIVES, lc=fc.STRIPE_RST_CHUNK):
        """Copy what the drives hold for `extents` back into the image; returns the sectors copied."""
        n = 0
        with open(self.path, "r+b") as f:
            for lba, cnt in extents:
                for i in range(cnt):
                    sect = storage.get(fc.stripe_map(lba + i, ld, lc))
                    if sect is not None:
                        f.seek((lba + i) * fc.SECT)
                        f.write(sect)
                        n += 1
        return n

    def fsck(self):
        part = os.path.join(self.dir, "part.img")
        run("dd", f"if={self.path}", f"of={part}", "bs=1M", f"skip={PART_SKIP_MIB}", "conv=sparse", "status=none")
        res = run("fsck.exfat", "-n", part, check=False)
        os.unlink(part)
        assert res.returncode == 0, f"fsck.exfat -n failed ({res.returncode}): {res.stdout}{res.stderr}"
        return res.stdout.strip()
