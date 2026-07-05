# test_dma_iuventus.py: pytest runner for the DMA Iuventus cocotb suite
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0
#
# Runs each @cocotb.test() in the testbench module as an independent, isolated
# `nvc -r` invocation. Parallelism and per-test process isolation come from
# pytest-xdist (``pytest -n auto``); the isolation is what makes the otherwise
# state-leakage-sensitive qsize=2 wrap-collision test deterministic.
#
# The expensive analyse+elaborate (nvc -a / nvc -e) is run ONCE beforehand
# (``make nvc-elab``); ``nvc -r`` is read-only on nvcwork/, so every test shares
# that one elaboration via a symlink. Invoke through ``make sim-parallel``.

import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

import pytest

COCOTB_DIR = Path(__file__).resolve().parent
TOP = "dma_iuventus"
TEST_MODULE = "cocotb_test"
ELAB_STAMP = COCOTB_DIR / "nvcwork" / f"NVCWORK.{TOP.upper()}.elab"


def _discover_tests():
    """Enumerate @cocotb.test() functions in the testbench module (no hardcoded
    list — stays in sync with cocotb_test.py automatically)."""
    src = (COCOTB_DIR / f"{TEST_MODULE}.py").read_text()
    names = re.findall(r"@cocotb\.test\([^)]*\)\s*\nasync def (\w+)", src)
    assert names, f"no @cocotb.test() functions found in {TEST_MODULE}.py"
    return names


def _cocotb_config(*args):
    return subprocess.check_output(["cocotb-config", *args], text=True).strip()


@pytest.mark.parametrize("testcase", _discover_tests())
def test_cocotb(testcase, tmp_path):
    if not ELAB_STAMP.exists():
        pytest.fail(f"{ELAB_STAMP} not found — run 'make nvc-elab' (or use "
                    f"'make sim-parallel', which elaborates first)")

    env = dict(os.environ)
    env.update(
        COCOTB_TEST_MODULES=TEST_MODULE,
        TOPLEVEL=TOP,
        TOPLEVEL_LANG="vhdl",
        PYGPI_PYTHON_BIN=_cocotb_config("--python-bin"),
        COCOTB_RESOLVE_X="ZEROS",
        LIBPYTHON_LOC=_cocotb_config("--libpython"),
        COCOTB_TESTCASE=testcase,
        # The test module and its local imports live in COCOTB_DIR, not in tmp_path.
        PYTHONPATH=os.pathsep.join([str(COCOTB_DIR), env.get("PYTHONPATH", "")]),
    )
    # nvc must find libpython at load time to bring up the cocotb VHPI bridge.
    libdir = subprocess.check_output(
        [sys.executable, "-c",
         "import sysconfig; print(sysconfig.get_config_var('LIBDIR') or '')"],
        text=True).strip()
    if libdir:
        env["LD_LIBRARY_PATH"] = os.pathsep.join([libdir, env.get("LD_LIBRARY_PATH", "")])

    # Isolated CWD per test; share the read-only elaboration via a symlink so
    # results.xml / rotating.log land here without colliding across workers.
    (tmp_path / "nvcwork").symlink_to(COCOTB_DIR / "nvcwork")

    vhpi = _cocotb_config("--lib-name-path", "vhpi", "nvc")
    cmd = ["nvc", "--work=nvcwork", "-H", "1G", "-M", "16G", "-r"]
    if os.environ.get("DEBUG_ENABLE", "false") == "true":
        cmd += ["-w", f"{TOP}.fst", "--dump-arrays"]
    cmd += [TOP, "--ieee-warnings=off", "--load", vhpi]

    logf = tmp_path / "shard.log"
    with logf.open("w") as fh:
        rc = subprocess.call(cmd, cwd=tmp_path, env=env, stdout=fh, stderr=subprocess.STDOUT)

    tail = logf.read_text()[-3000:]
    results = tmp_path / "results.xml"
    assert results.exists(), (
        f"{testcase}: nvc produced no results.xml (exit {rc}). Log tail:\n{tail}")

    tree = ET.parse(results)
    for tc in tree.getroot().iter("testcase"):
        name = tc.get("name", "")
        if name == testcase or name.endswith("." + testcase):
            if tc.find("skipped") is not None:
                pytest.skip(f"{testcase} reported skipped")
            failed = tc.find("failure") is not None or tc.find("error") is not None
            assert not failed, f"{testcase} FAILED. Log tail:\n{tail}"
            return
    pytest.fail(f"{testcase} not present in results.xml. Log tail:\n{tail}")
