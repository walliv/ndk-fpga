# test_mfb_merger_simple.py: pytest runner of the MFB_MERGER_SIMPLE cocotb bench
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0
"""Runs each (combination of ver_settings.py, test) as an ``nvc -r`` shard under pytest-xdist (nvc_suite.py)."""

import json
import os
from pathlib import Path

import nvc_suite

BENCH = Path(__file__).resolve().parent
CONFIGS = nvc_suite.ver_settings_configs(BENCH / "ver_settings.py", nvc_suite.cocotb_tests(BENCH / "cocotb_test.py"))

# JSON generics replacing those of every combination (A/B runs), e.g. '{"ARRIVAL_ORDER_EN": false}'; the frame order
# check still follows the combination's own ARRIVAL_ORDER_EN.
GENERICS_OVERRIDE = json.loads(os.environ.get("MERGER_GENERICS_OVERRIDE", "{}"))
if GENERICS_OVERRIDE:
    for cfg in CONFIGS.values():
        cfg.env["MERGER_ORDER_CHECK"] = "1" if cfg.generics["ARRIVAL_ORDER_EN"] == "true" else "0"
        cfg.generics.update(GENERICS_OVERRIDE)

SUITE = nvc_suite.Suite(BENCH, "mfb_merger_simple", CONFIGS, "MERGER", origin_logged=True,
                        record_fields={"summary": (r"\bsummary: (.*)", lambda s: s[:600])})

test_cocotb = SUITE.test_cocotb()
