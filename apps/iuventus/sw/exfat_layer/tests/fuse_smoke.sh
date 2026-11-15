#!/usr/bin/env bash
# fuse_smoke.sh: iuv-fs end to end: random file operations, a model job through the control file, a crash and recovery
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail
trap 'echo "fuse_smoke: failed at line $LINENO: $BASH_COMMAND" >&2' ERR

FS=$1
CLI=$2
TMP=$3
HERE=$(cd "$(dirname "$0")" && pwd)

for tool in mkfs.exfat fsck.exfat fusermount3 python3 cmp prlimit pgrep mountpoint; do
    command -v "$tool" > /dev/null || { echo "SKIP: $tool not found"; exit 77; }
done
[ -c /dev/fuse ] && [ -w /dev/fuse ] || { echo "SKIP: /dev/fuse not usable"; exit 77; }

rm -rf "${TMP:?}"
mkdir -p "$TMP/mnt"
mnt=$TMP/mnt
cleanup() {
    fusermount3 -u "$mnt" 2> /dev/null || true
    rm -rf "${TMP:?}"
}
trap cleanup EXIT
# fusermount3 returns before the daemon's last commit, so the next user of the image waits for the daemon to exit.
unmount() {
    # A release still in flight right after the last close makes the unmount EBUSY for a moment.
    for _ in $(seq 20); do fusermount3 -u "$mnt" 2> /dev/null && break; sleep 0.2; done
    ! mountpoint -q "$mnt" || { echo "FAIL: $mnt stays busy"; exit 1; }
    while pgrep -f "^$FS .*$mnt\$" > /dev/null; do sleep 0.1; done
}

img=$TMP/vol.img
truncate -s 2G "$img"
mkfs.exfat -q -P gpt -c 512K -b 1M -L DATAVOL "$img" > /dev/null

check_volume() {
    "$CLI" "${@:2}" "$1" check
    dd if="$1" of="$TMP/part.img" bs=1M skip=1 conv=sparse status=none
    fsck.exfat -n "$TMP/part.img"
    python3 "$HERE/exfat_bitmap_check.py" "$TMP/part.img"
}

seed_arg=()
[ -n "${IUV_SEED:-}" ] && seed_arg=(--seed "$IUV_SEED")
"$FS" --direct-io "$img" "$mnt"
mkdir "$mnt/dio"
python3 "$HERE/fuse_check.py" "$mnt/dio" "$TMP/shadow" --steps 10 "${seed_arg[@]}"
rm -r "$mnt/dio"
unmount
"$FS" "$img" "$mnt"
python3 "$HERE/fuse_check.py" "$mnt" "$TMP/shadow" --steps "${IUV_FUSE_STEPS:-60}" "${seed_arg[@]}"
# Mounting deletes the hidden names of files unlinked while open, so no other file may take one.
touch "$mnt/keep"
for op in touch mkdir "mv $mnt/keep"; do
    if $op "$mnt/.iuv-fs-unlinked-mine" 2> /dev/null; then
        echo "FAIL: $op took a hidden name"
        exit 1
    fi
done
rm "$mnt/keep"

mkdir "$mnt/in" "$mnt/out"
head -c 3000001 /dev/urandom > "$TMP/a.bin"
head -c 777 /dev/urandom > "$TMP/b.bin"
cp "$TMP/a.bin" "$mnt/in/a.bin"
cp "$TMP/b.bin" "$mnt/in/b.bin"
job="--fill-bytes 262144 --seed 5 --reserve 65536 --extend 65536 /out/x.bin /in/a.bin /in/b.bin -- /out/y.bin /in/b.bin"
echo "run $job" > "$mnt/.iuv-job"
grep -q "stream 1 record" "$mnt/.iuv-job"
cp "$mnt/out/x.bin" "$TMP/x.mnt"
cp "$mnt/out/y.bin" "$TMP/y.mnt"
if echo "run /out/x.bin /in/a.bin" > "$mnt/.iuv-job" 2> /dev/null; then
    echo "FAIL: a job over an existing output succeeded"
    exit 1
fi
grep -q "job failed" "$mnt/.iuv-job"
if echo "run --fill-bytes 64 /out/z.bin /missing.bin" > "$mnt/.iuv-job" 2> /dev/null; then
    echo "FAIL: a job with a missing input succeeded"
    exit 1
fi
[ ! -e "$mnt/out/z.bin" ] || { echo "FAIL: a job that never started left its output"; exit 1; }
unmount
check_volume "$img"

# The same job through the CLI on a copy, without the outputs, is the reference.
cp "$img" "$TMP/ref.img"
"$CLI" "$TMP/ref.img" rm /out/x.bin
"$CLI" "$TMP/ref.img" rm /out/y.bin
# shellcheck disable=SC2086
"$CLI" "$TMP/ref.img" run $job > /dev/null
"$CLI" "$TMP/ref.img" get /out/x.bin "$TMP/x.ref"
"$CLI" "$TMP/ref.img" get /out/y.bin "$TMP/y.ref"
cmp "$TMP/x.mnt" "$TMP/x.ref"
cmp "$TMP/y.mnt" "$TMP/y.ref"

# A daemon killed while files are open for writing leaves a dirty volume that only --recover mounts; recovery drops the
# unsynced new file, keeps the fsynced one at its synced size, and keeps a committed rename and unlink of an open file.
"$FS" "$img" "$mnt"
mv "$mnt/in/a.bin" "$mnt/in/a_renamed.bin"
python3 - "$mnt/in" > "$TMP/writer.log" <<'PY' &
import os, sys, time
held = open(os.path.join(sys.argv[1], "b.bin"), "rb")
os.unlink(os.path.join(sys.argv[1], "b.bin"))
part = open(os.path.join(sys.argv[1], "partial.bin"), "wb")
part.write(bytes(10 << 20))
part.flush()
synced = open(os.path.join(sys.argv[1], "synced.bin"), "wb")
synced.write(b"durable" * 100000)
synced.flush()
os.fsync(synced.fileno())
synced.write(b"lost" * 300000)
synced.flush()
time.sleep(0.5)
print("open", flush=True)
time.sleep(60)
PY
writer=$!
until grep -q open "$TMP/writer.log"; do sleep 0.1; done
pkill -KILL -x -f "$FS $img $mnt"
kill "$writer" 2> /dev/null || true
wait "$writer" 2> /dev/null || true
fusermount3 -u "$mnt" 2> /dev/null || true
if "$FS" "$img" "$mnt" 2> /dev/null; then
    unmount
    echo "FAIL: a dirty volume mounted without --recover"
    exit 1
fi
"$FS" --recover "$img" "$mnt"
cmp "$TMP/a.bin" "$mnt/in/a_renamed.bin"
[ ! -e "$mnt/in/a.bin" ] && [ ! -e "$mnt/in/b.bin" ] || { echo "FAIL: a rename or an unlink was lost"; exit 1; }
unmount
if "$CLI" "$img" ls -R / | grep -q iuv-fs-unlinked; then
    echo "FAIL: the hidden name of a file unlinked while open survived the remount"
    exit 1
fi
"$FS" "$img" "$mnt"
[ ! -e "$mnt/in/partial.bin" ] || { echo "FAIL: the unsynced file survived recovery"; exit 1; }
python3 -c "import sys; d = open(sys.argv[1], 'rb').read(); sys.exit(d != b'durable' * 100000)" "$mnt/in/synced.bin" ||
    { echo "FAIL: the fsynced file lost its synced content or size"; exit 1; }
unmount
# fsync of a directory, or of a file through a read handle, commits at once: a kill right after keeps both changes.
"$FS" "$img" "$mnt"
python3 - "$mnt/in" "$(pgrep -n -x -f "$FS $img $mnt")" <<'PY'
import os, signal, sys
d, pid = sys.argv[1], int(sys.argv[2])
os.rename(os.path.join(d, "a_renamed.bin"), os.path.join(d, "a_synced.bin"))
fd = os.open(d, os.O_RDONLY)
os.fsync(fd)
os.close(fd)
with open(os.path.join(d, "closed.bin"), "wb") as f:
    f.write(b"closed" * 1000)
fd = os.open(os.path.join(d, "closed.bin"), os.O_RDONLY)
os.fsync(fd)
os.close(fd)
os.kill(pid, signal.SIGKILL)
PY
fusermount3 -u "$mnt" 2> /dev/null || true
"$FS" --recover "$img" "$mnt"
cmp "$TMP/a.bin" "$mnt/in/a_synced.bin"
[ ! -e "$mnt/in/a_renamed.bin" ] || { echo "FAIL: rename lost despite fsync of its directory"; exit 1; }
python3 -c "import sys; sys.exit(open(sys.argv[1], 'rb').read() != b'closed' * 1000)" "$mnt/in/closed.bin" ||
    { echo "FAIL: closed file lost despite fsync through a read handle"; exit 1; }
unmount
check_volume "$img"

# A rename that finds no cluster for the new name leaves the open file it would replace under its name.
small=$TMP/small.img
truncate -s 64M "$small"
mkfs.exfat -q -P gpt -c 4K -b 1M "$small" > /dev/null
# One drive with a 4 KiB chunk, so the stripe matches the small clusters.
small_opts=(--drives 1 --chunk-kib 4)
"$FS" "${small_opts[@]}" "$small" "$mnt"
python3 - "$mnt" <<'PY'
import ctypes, errno, os, sys, time
mnt = sys.argv[1]
os.mkdir(os.path.join(mnt, "d"))
# 42 sets of three entries leave no room for a 43rd in the directory's 4 KiB cluster.
for i in range(42):
    with open(os.path.join(mnt, "d", "t%02d" % i), "wb") as f:
        f.write(b"t%02d" % i)
open(os.path.join(mnt, "x"), "wb").close()
# The commit of the closes returns x's reserved cluster, which must not turn up after the fill.
time.sleep(0.5)
free = os.statvfs(mnt).f_bfree * os.statvfs(mnt).f_frsize
fill = os.open(os.path.join(mnt, "fill"), os.O_WRONLY | os.O_CREAT)
libc = ctypes.CDLL(None, use_errno=True)
libc.fallocate.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_long, ctypes.c_long]
if libc.fallocate(fill, 1, 0, free) != 0 or os.statvfs(mnt).f_bfree != 0:
    sys.exit("FAIL: could not fill the volume")
target = os.path.join(mnt, "d", "t00")
with open(target, "rb") as held:
    try:
        os.rename(os.path.join(mnt, "x"), target)
        want, x_left = b"", False
    except OSError as e:
        if e.errno != errno.ENOSPC:
            raise
        want, x_left = b"t00", True
    if held.read() != b"t00":
        sys.exit("FAIL: open target reads wrong data")
os.close(fill)
if open(target, "rb").read() != want or os.path.exists(os.path.join(mnt, "x")) != x_left:
    sys.exit("FAIL: failed rename lost its target")
PY
unmount
check_volume "$small" "${small_opts[@]}"

# After a failed commit an open writer refuses further data instead of losing it at close.
(
    trap '' XFSZ
    exec "$FS" "${small_opts[@]}" "$small" "$mnt"
)
python3 - "$mnt" "$(pgrep -n -x -f "$FS ${small_opts[*]} $small $mnt")" <<'PY'
import errno, os, subprocess, sys, time
mnt, pid = sys.argv[1], sys.argv[2]
w = open(os.path.join(mnt, "w.bin"), "wb", buffering=0)
w.write(b"a")
q = open(os.path.join(mnt, "q.bin"), "wb")
# The partition starts at 1 MiB, so every volume write fails from here on and the commit for q's close with them.
subprocess.run(["prlimit", "--pid", pid, "--fsize=1048576"], check=True)
q.close()
time.sleep(0.5)
for what, op in (("write", lambda: w.write(b"b")), ("fsync", lambda: os.fsync(w.fileno()))):
    try:
        op()
        sys.exit("FAIL: %s after a failed commit succeeded" % what)
    except OSError as e:
        if e.errno != errno.EIO:
            sys.exit("FAIL: %s after a failed commit: %s" % (what, e))
try:
    w.close()
except OSError:
    pass
PY
unmount
echo "fuse_smoke: OK"
