# test_dma_calypte.py: pytest runner for the DMA_CALYPTE cocotb bench
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0
"""Runs each (combination of ver_settings.py, test) as an ``nvc -r`` shard under pytest-xdist (nvc_suite.py).
test_elaboration also elaborates the combinations that do not run by default."""

import os
from pathlib import Path

import nvc_suite

BENCH = Path(__file__).resolve().parent
MODULE = os.environ.get("CALYPTE_TEST_MODULE", "cocotb_test")
CONFIGS = nvc_suite.ver_settings_configs(BENCH / "ver_settings.py", nvc_suite.cocotb_tests(BENCH / f"{MODULE}.py"))
# The Intel combinations only elaborate unless selected by CALYPTE_CONFIG_FILTER: nvc cannot load the encrypted Agilex
# DSP atom nor the SystemVerilog-only altera_syncram.
for cfg in CONFIGS.values():
    cfg.run = "AGILEX" not in cfg.generics["DEVICE"]

SUITE = nvc_suite.Suite(
    BENCH, "dma_calypte_tb_wrapper", CONFIGS, "CALYPTE", module=MODULE, heap="16G",
    bench_error_re=r"\bERROR +cocotb\.DMA_CALYPTE_TB_WRAPPER\b", origin_logged=True,
    record_fields={"sim_ns": (r"\bsim_time=(\d+) ns", int)})

test_elaboration = SUITE.test_elaboration()
test_cocotb = SUITE.test_cocotb()

if __name__ == "__main__":
    SUITE.main()
