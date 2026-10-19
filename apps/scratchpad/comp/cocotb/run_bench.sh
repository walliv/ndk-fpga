#!/bin/bash
# run_bench.sh: one seeded-at-random run of the scratchpad CORE_LOGIC bench, log in $1
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0
cd "$(dirname "$0")"
export PATH=$HOME/miniforge3/envs/ndk-env/bin:$PATH
source ../../../../env.sh >/dev/null 2>&1
LOG=${1:-bench.log}
shift
make test "$@" > "$LOG" 2>&1
echo "BENCH_EXIT=$?" >> "$LOG"
