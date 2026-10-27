# test_tx_dma_pcie_trans_buffer.py: pytest runner of the TX_DMA_PCIE_TRANS_BUFFER cocotb bench
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0
"""Runs the test module of each combination of ver_settings.py as one ``nvc -r`` shard under pytest-xdist
(nvc_suite.py). The tests of a module share the buffer content and its model, so a module is not split into shards."""

from pathlib import Path

import nvc_suite

BENCH = Path(__file__).resolve().parent
CONFIGS = nvc_suite.ver_settings_configs(BENCH / "ver_settings.py", [None])
# An Intel combination counts only with Altera's simulation models in Questa, so here it only elaborates unless
# TRBUF_CONFIG_FILTER selects it.
for cfg in CONFIGS.values():
    cfg.run = "AGILEX" not in cfg.generics["DEVICE"]

SUITE = nvc_suite.Suite(BENCH, "tx_dma_pcie_trans_buffer_tb_wrapper", CONFIGS, "TRBUF")

test_elaboration = SUITE.test_elaboration()
test_cocotb = SUITE.test_cocotb()
