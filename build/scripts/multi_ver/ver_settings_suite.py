# ver_settings_suite.py: parallel nvc runs of the ver_settings.py combinations of a cocotb bench
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0
"""The default SUITE_FILE of nvc_suite.mk, run from the bench directory: every combination multi_ver_cocotb.py runs
from the bench's ver_settings.py (one "default" configuration without that file) times every @cocotb.test of
COCOTB_TEST_MODULES, each as an nvc -r shard under pytest-xdist."""

import os
from pathlib import Path

import nvc_suite

BENCH = Path.cwd()
MODULE = os.environ.get("COCOTB_TEST_MODULES") or "cocotb_test"
TESTS = nvc_suite.cocotb_tests(BENCH / f"{MODULE}.py")
SETTINGS = BENCH / "ver_settings.py"
CONFIGS = (nvc_suite.ver_settings_configs(SETTINGS, TESTS) if SETTINGS.exists()
           else {"default": nvc_suite.Config({}, TESTS)})

SUITE = nvc_suite.Suite(BENCH, os.environ["SUITE_TOP"].lower(), CONFIGS, os.environ.get("SUITE_PREFIX", "SUITE"),
                        module=MODULE)

test_cocotb = SUITE.test_cocotb()
