#!/usr/bin/env bash
set -euo pipefail

# Creates files in the directory where this script is invoked (current working directory)

printf '%s' "NCT rules!" > ./tst1.txt
printf '%s' "Heidelberg is a nice town." > ./tst2.txt

mkdir -p ./my_dir
printf '%s' "Hidden file in a directory" > ./my_dir/tst1.txt

dd if=/dev/random of=./large_file.txt bs=1M count=1 conv=fsync