# test_nvc_suite.py: checks of the parallel nvc suite runner in build/scripts/multi_ver/nvc_suite.py
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import importlib
import os
import runpy

import pytest

from flow_utils import MULTI_VER, REPO
FAILS = (AssertionError, pytest.fail.Exception)


@pytest.fixture
def ns(monkeypatch):
    monkeypatch.syspath_prepend(str(MULTI_VER))
    return importlib.import_module("nvc_suite")


def make_suite(ns, tmp_path, configs, **kwargs):
    return ns.Suite(tmp_path, "top", configs, "UT", **kwargs)


def ids(suite):
    return [p.id for p in suite.params()]


def test_generic_args(ns):
    assert ns.nvc_generic_args({"A": True, "B": False, "C": 8, "D": "BRAM", "E": "\\\"ULTRASCALE\\\""}) == [
        "-g", "A=true", "-g", "B=false", "-g", "C=8", "-g", "D=BRAM", "-g", "E=ULTRASCALE"]


def test_params(ns, tmp_path, monkeypatch):
    suite = make_suite(ns, tmp_path, {
        "a": ns.Config({}, ["t1", "t2"]),
        "b": ns.Config({}, ["t1"], run=False),
        "m": ns.Config({}, [None], module="mod2"),
    })
    assert ids(suite) == ["a-t1", "a-t2", "m-mod2"]
    monkeypatch.setenv("UT_CONFIG_FILTER", "b")
    assert ids(suite) == ["b-t1"]
    monkeypatch.setenv("UT_CONFIG_FILTER", "a")
    monkeypatch.setenv("UT_TEST_FILTER", "t2")
    monkeypatch.setattr(ns, "SUITE_REPEAT", 2)
    assert ids(suite) == ["a-t2-r0", "a-t2-r1"]


def write_results(path, *cases):
    body = "".join(f'<testcase name="cocotb_test.{name}">{inner}</testcase>' for name, inner in cases)
    path.write_text(f'<testsuites><testsuite name="all">{body}</testsuite></testsuites>')
    return path


PASS = ""
FAIL = '<failure message="x"/>'
SKIP = "<skipped/>"


@pytest.mark.parametrize("testcase,cases,ok", [
    ("t1", [("t1", PASS)], True),
    ("t1", [("t0", FAIL), ("t1", PASS)], True),
    ("t1", [("t1", FAIL)], False),
    ("t1", [("t1", SKIP)], False),
    ("t1", [("t0", PASS)], False),
    (None, [("t0", SKIP), ("t1", PASS)], True),
    (None, [("t0", SKIP), ("t1", SKIP)], False),
    (None, [("t0", PASS), ("t1", FAIL)], False),
])
def test_check_results(ns, tmp_path, testcase, cases, ok):
    suite = make_suite(ns, tmp_path, {})
    results = write_results(tmp_path / "results.xml", *cases)
    if ok:
        suite.check_results("c/t", testcase, results, 0, "")
    else:
        with pytest.raises(FAILS):
            suite.check_results("c/t", testcase, results, 0, "")


def test_check_results_missing(ns, tmp_path):
    with pytest.raises(AssertionError, match="no results.xml"):
        make_suite(ns, tmp_path, {}).check_results("c/t", "t1", tmp_path / "results.xml", 1, "")


def test_check_log(ns, tmp_path):
    suite = make_suite(ns, tmp_path, {}, record_fields={"sim_ns": (r"\bsim_time=(\d+) ns", int)})
    record = {}
    suite.check_log("c/t", "INFO cocotb sim_time=1200 ns\n", record)
    assert record == {"sim_ns": 1200}
    with pytest.raises(FAILS, match="stops at time 0"):
        suite.check_log("c/t", "** Error: 0ms+0: bad\n", {})
    with pytest.raises(AssertionError, match="RTL assertion"):
        suite.check_log("c/t", "** Error: 0ms+0: bad\n** Error: 12ns+1: bad\n", {})
    with pytest.raises(AssertionError, match="bench error"):
        suite.check_log("c/t", "  12.00ns ERROR    cocotb.top    mismatch\n", {})


def test_origin_logged(ns, tmp_path):
    suite = make_suite(ns, tmp_path, {}, origin_logged=True)
    suite.check_log("c/t", f"cocotbext.ofm imported from {REPO}/python/cocotbext/x.py\n", {})
    with pytest.raises(AssertionError, match="not logged"):
        suite.check_log("c/t", "", {})
    with pytest.raises(AssertionError, match="/elsewhere"):
        suite.check_log("c/t", "cocotbext.ofm imported from /elsewhere/x.py\n", {})


TEST_MODULE = """
import cocotb


@cocotb.test()
async def first(dut):
    pass


@cocotb.test
async def second(dut):
    pass


async def helper(dut):
    pass


@other.decorator
async def third(dut):
    pass
"""


def test_cocotb_tests(ns, tmp_path):
    (tmp_path / "cocotb_test.py").write_text(TEST_MODULE)
    assert ns.cocotb_tests(tmp_path / "cocotb_test.py") == ["first", "second"]


def bench_settings():
    """Every ver_settings.py next to a cocotb_test.py in the repository."""
    return sorted(p.relative_to(REPO) for p in REPO.glob("**/ver_settings.py") if (p.parent / "cocotb_test.py").exists())


@pytest.mark.parametrize("settings", bench_settings(), ids=str)
def test_ver_settings_configs(ns, tmp_path, settings):
    """The suite runs exactly the combinations multi_ver_cocotb.py runs without a random reduction (-r 100); the cocotb
    parameters go to the environment. The dry run starts outside the bench, whose pyproject.toml would make it build a
    virtual environment."""
    multi_ver = importlib.import_module("test_multi_ver")
    configs = ns.ver_settings_configs(REPO / settings, ["t"])
    reduced = "_combinations_run_percentage_" in runpy.run_path(str(REPO / settings))["SETTINGS"]
    assert list(configs) == multi_ver.dry_run(os.path.relpath(REPO / settings, tmp_path), tmp_path,
                                              *(["-r", "100"] if reduced else []))
    for cfg in configs.values():
        assert "__cocotb_params__" not in cfg.generics and all(k.startswith("COCOTB_") for k in cfg.env)


SELECTING_SETTINGS = r'''
SETTINGS = {
    "default": {"A": "1", "__cocotb_params__": {"TEST_FILTER": r"\.(first|second)\b"}},
    "b": {"A": "2", "__cocotb_params__": {"TEST_FILTER": r"\.second\b"}},
    "smoke": {"__cocotb_params__": {"TEST_MODULES": "smoke"}},
    "_combinations_": {"a": (), "b": ("b",), "s": ("smoke",)},
}
'''


def test_ver_settings_test_selection(ns, tmp_path):
    """TEST_FILTER gives the test shards of a combination, TEST_MODULES its module."""
    (tmp_path / "ver_settings.py").write_text(SELECTING_SETTINGS)
    configs = ns.ver_settings_configs(tmp_path / "ver_settings.py", ["first", "second", "second_slow"])
    assert configs["s"].module == "smoke"
    assert ids(make_suite(ns, tmp_path, configs)) == ["a-first", "a-second", "b-second", "s-first", "s-second"]


def test_shard_test_filter(ns, tmp_path):
    """A test shard narrows the combination's COCOTB_TEST_FILTER to its test, which cocotb refuses next to
    COCOTB_TESTCASE; a module shard keeps the combination's filter."""
    suite = make_suite(ns, tmp_path, {"c": ns.Config({}, ["t1"], env={"COCOTB_TEST_FILTER": r"\.t\d\b"})})
    env = suite._shard_env("c", "t1", "1")
    assert env["COCOTB_TEST_FILTER"] == r"^cocotb_test\.t1$" and "COCOTB_TESTCASE" not in env
    assert suite._shard_env("c", None, "1")["COCOTB_TEST_FILTER"] == r"\.t\d\b"
