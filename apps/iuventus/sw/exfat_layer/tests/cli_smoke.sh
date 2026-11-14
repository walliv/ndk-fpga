#!/usr/bin/env bash
# cli_smoke.sh: end-to-end check of the iuv-exfat command line tool against fsck.exfat
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

CLI=$1
TMP=$2
CHECKER=$3

for tool in mkfs.exfat fsck.exfat python3; do
    command -v "$tool" > /dev/null || { echo "SKIP: $tool not found"; exit 77; }
done

rm -rf "${TMP:?}"
mkdir -p "$TMP"
trap 'rm -rf "${TMP:?}"' EXIT

img=$TMP/vol.img
truncate -s 128M "$img"
mkfs.exfat -q -P gpt -c 512K -b 1M "$img" > /dev/null

head -c 1234567 /dev/urandom > "$TMP/a.bin"
head -c 511 /dev/urandom > "$TMP/c.bin"
: > "$TMP/empty.bin"

"$CLI" "$img" mkdir /dir
"$CLI" "$img" put "$TMP/a.bin" /dir/A.bin
"$CLI" "$img" put "$TMP/c.bin" /dir/c.bin
"$CLI" "$img" put "$TMP/empty.bin" /empty
if "$CLI" "$img" put "$TMP/c.bin" /DIR/C.BIN 2> /dev/null; then
    echo "FAIL: put over an existing name (case-insensitive) succeeded"
    exit 1
fi
"$CLI" "$img" ls -R
"$CLI" "$img" extents /DIR/a.BIN
"$CLI" "$img" get /dir/a.bin "$TMP/a.out"
cmp "$TMP/a.bin" "$TMP/a.out"
"$CLI" "$img" get /empty "$TMP/empty.out"
cmp "$TMP/empty.bin" "$TMP/empty.out"
if "$CLI" "$img" get /missing "$TMP/missing.out" 2> /dev/null; then
    echo "FAIL: get of a missing file succeeded"
    exit 1
fi
for bad in 4x 0x100000000 -1; do
    rc=0
    "$CLI" --drives "$bad" "$img" info > /dev/null 2>&1 || rc=$?
    [ "$rc" -eq 2 ] || { echo "FAIL: --drives $bad exited $rc, want 2"; exit 1; }
done
if "$CLI" "$img" run --seed 0x100000000 /seed_out /dir/c.bin 2> /dev/null; then
    echo "FAIL: run took a seed wider than 32 bits"
    exit 1
fi
# The kernel arguments are refused before START, so the job must leave neither its outputs nor a dirty volume.
if "$CLI" "$img" run --fill-bytes 100 /bad_out0 /dir/c.bin -- /bad_out1 /dir/c.bin 2> /dev/null; then
    echo "FAIL: run with a FILL_BYTES the kernel refuses succeeded"
    exit 1
fi
"$CLI" "$img" info | grep -q "dirty no"
if "$CLI" "$img" ls / | grep -q "/bad_out"; then
    echo "FAIL: a job that failed before START left its outputs"
    exit 1
fi

"$CLI" "$img" run --fill-bytes 1048576 --seed 7 --reserve 4096 --extend 524288 \
    /out0 /dir/A.bin /dir/c.bin -- /out1 /empty /dir/c.bin
"$CLI" "$img" get /out0 "$TMP/out0"
"$CLI" "$img" get /out1 "$TMP/out1"
cat > "$TMP/dfill.py" <<'PYEOF'
import struct
import sys


def expected(inputs, fill, seed):
    out = bytearray()
    for j in range(fill // 8):
        out += struct.pack("<Q", (((j & 0xFFFFFFFF) ^ seed) << 32) | (j & 0xFFFFFFFF))
    total = s = x = 0
    for f, path in enumerate(inputs):
        data = open(path, "rb").read()
        total += len(data)
        for o in range(0, len(data), 8):
            c = int.from_bytes(data[o:o + 8], "little") ^ o ^ (f << 40)
            s = (s + c) & 0xFFFFFFFFFFFFFFFF
            x ^= c
    return bytes(out) + struct.pack("<QQQII", total, s, x, len(inputs), 0x31474944)


mode, target, fill, seed, *inputs = sys.argv[1:]
want = expected(inputs, int(fill), int(seed))
if mode == "check":
    if open(target, "rb").read() != want:
        sys.exit("FAIL: " + target + " differs from the independent DIGEST_FILL computation")
elif mode == "write":
    # target is '<image>:<extents file>'; write the bytes the shell would, padding the last LBA with zeros.
    image, ext_file = target.split(":")
    data = want + bytes(-len(want) % 512)
    with open(image, "r+b") as img:
        pos = 0
        for line in open(ext_file):
            lba, count = map(int, line.split())
            piece = data[pos:pos + count * 512]
            img.seek(lba * 512)
            img.write(piece)
            pos += len(piece)
    if pos != len(data):
        sys.exit("FAIL: reserved extents too small")
PYEOF
python3 -I "$TMP/dfill.py" check "$TMP/out0" 1048576 7 "$TMP/a.bin" "$TMP/c.bin"
python3 -I "$TMP/dfill.py" check "$TMP/out1" 1048576 7 "$TMP/empty.bin" "$TMP/c.bin"
echo "run outputs match the independent computation"

# Simulation bench flow: reserve and finalize run as separate processes, command-first syntax.
fill=327680
"$CLI" reserve "$img" /bench0 $((fill + 32)) > "$TMP/bench0.ext"
"$CLI" reserve "$img" /bench1 $((fill + 32)) > "$TMP/bench1.ext"
"$CLI" info "$img" | grep -q "dirty yes"
"$CLI" ls "$img" / | grep -q "^-U .* /bench0$"
if "$CLI" put "$img" "$TMP/c.bin" /refused 2> /dev/null; then
    echo "FAIL: put on a dirty volume without recover() succeeded"
    exit 1
fi
python3 -I "$TMP/dfill.py" write "$img:$TMP/bench0.ext" $fill 21 "$TMP/a.bin" "$TMP/c.bin"
python3 -I "$TMP/dfill.py" write "$img:$TMP/bench1.ext" $fill 22 "$TMP/c.bin"
if "$CLI" finalize "$img" /dir/A.bin 10 2> /dev/null; then
    echo "FAIL: finalize adopted a finished file"
    exit 1
fi
"$CLI" finalize "$img" /bench0 $((fill + 32))
"$CLI" info "$img" | grep -q "dirty yes"
"$CLI" finalize "$img" /bench1 $((fill + 32))
"$CLI" info "$img" | grep -q "dirty no"
"$CLI" get "$img" /bench0 "$TMP/bench0.out"
"$CLI" get "$img" /bench1 "$TMP/bench1.out"
python3 -I "$TMP/dfill.py" check "$TMP/bench0.out" $fill 21 "$TMP/a.bin" "$TMP/c.bin"
python3 -I "$TMP/dfill.py" check "$TMP/bench1.out" $fill 22 "$TMP/c.bin"
"$CLI" extents "$img" /bench0 > "$TMP/bench0.final"
head -1 "$TMP/bench0.final" | grep -qx "size $((fill + 32))"
awk -v want=$(((fill + 32 + 511) / 512)) 'NR > 1 { n += $2 } END { exit n != want }' "$TMP/bench0.final"
echo "reserve/finalize bench flow verified"

"$CLI" "$img" check
"$CLI" "$img" rm /dir/c.bin
"$CLI" "$img" recover
"$CLI" "$img" info | grep -q "dirty no"

dd if="$img" of="$TMP/part.img" bs=1M skip=1 conv=sparse status=none
fsck.exfat -n "$TMP/part.img"
python3 -I "$CHECKER" "$TMP/part.img"
echo "cli_smoke: PASS"
