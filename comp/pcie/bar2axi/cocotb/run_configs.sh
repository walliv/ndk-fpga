#!/bin/bash
# run_configs.sh: runs the cocotb suite once per required DUT configuration with a random seed
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0
#
# usage: ./run_configs.sh [repetitions]; results_<cfg>_<n>.xml and log_<cfg>_<n>.txt per run

cd "$(dirname "$0")" || exit 1
REPS=${1:-1}
CONFIGS="2:256:ULTRASCALE 2:512:VERSAL 4:256:VERSAL 4:512:ULTRASCALE"
rc=0
for n in $(seq 1 "$REPS"); do
    for c in $CONFIGS; do
        IFS=: read -r rgn dw dev <<< "$c"
        tag="r${rgn}_d${dw}_${dev,,}_${n}"
        seed=$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')
        make MFB_REGIONS="$rgn" AXI_DATA_WIDTH="$dw" DEVICE="$dev" RANDOM_SEED="$seed" > "log_${tag}.txt" 2>&1
        st=$?
        cp -f results.xml "results_${tag}.xml" 2>/dev/null
        summary=$(grep -o "TESTS=[0-9]* PASS=[0-9]* FAIL=[0-9]*" "log_${tag}.txt" | tail -1)
        echo "${tag} seed=${seed} exit=${st} ${summary}"
        [ "$st" -ne 0 ] && rc=1
    done
done
exit $rc
