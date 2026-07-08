#!/usr/bin/env bash
set -euo pipefail

# Creates files in the directory where this script is invoked (current working directory)

printf '%s' "test file one" > ./tst1.txt
printf '%s' "test file two" > ./tst2.txt

mkdir -p ./my_dir
printf '%s' "Hidden file in a directory" > ./my_dir/tst1.txt

dd if=/dev/random of=./large_file.txt bs=1M count=1 conv=fsync