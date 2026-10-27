# test_mfb_merger_simple.py: pytest runner of the MFB_MERGER_SIMPLE cocotb bench
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0
"""Runs each (combination of ver_settings.py, test) as an ``nvc -r`` shard under pytest-xdist (nvc_suite.py)."""

from pathlib import Path

import nvc_suite

BENCH = Path(__file__).resolve().parent
CONFIGS = nvc_suite.ver_settings_configs(BENCH / "ver_settings.py", nvc_suite.cocotb_tests(BENCH / "cocotb_test.py"))

SUITE = nvc_suite.Suite(BENCH, "mfb_merger_simple", CONFIGS, "MERGER", origin_logged=True,
                        record_fields={"summary": (r"\bsummary: (.*)", lambda s: s[:600])})

test_cocotb = SUITE.test_cocotb()
