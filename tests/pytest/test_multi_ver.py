# test_multi_ver.py: checks of the ver_settings.py expansion shared by the multi_ver scripts
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import importlib
import re
import subprocess
import sys

import pytest

from flow_utils import MULTI_VER


@pytest.fixture
def utils(monkeypatch):
    monkeypatch.syspath_prepend(str(MULTI_VER))
    return importlib.import_module("multi_ver_utils")


def dry_run(settings_file, cwd, *args):
    """The combinations `multi_ver_cocotb.py -d` lists, in its order."""
    out = subprocess.run([sys.executable, str(MULTI_VER / "multi_ver_cocotb.py"), str(settings_file), "-d", *args],
                         cwd=cwd, capture_output=True, text=True, check=True).stdout
    return re.findall(r"^Running combination: (\S+) \(", out, re.M)


@pytest.mark.parametrize("settings,expected", [
    ({"default": {}, "a": {}}, {"default": ("default",), "a": ("a",)}),
    ({"default": {}, "a": {}, "_combinations_": ((), ("a",))}, {"test_name_0": (), "test_name_1": ("a",)}),
    ({"default": {}, "a": {}, "_combinations_": {"x": ("a",)}}, {"x": ("a",)}),
])
def test_expand_combinations(utils, settings, expected):
    assert utils.expand_combinations(settings) == expected
    assert not any(key.startswith("_combinations_") for key in settings)


def test_run_percentage(utils):
    settings = {"default": {}, "a": {}, "b": {}, "_combinations_": ((), ("a",), ("b",), ("a", "b")),
                "_combinations_run_percentage_": 50}
    combinations = utils.expand_combinations(settings)
    assert len(combinations) == 2 and "_combinations_run_percentage_" not in settings


def test_dry_run(tmp_path):
    (tmp_path / "ver_settings.py").write_text(
        'SETTINGS = {"default": {"A": "1"}, "b": {"A": "2"}, "_combinations_": ((), ("b",))}\n')
    assert dry_run("ver_settings.py", tmp_path) == ["test_name_0", "test_name_1"]


def test_cocotb_params_env(utils):
    setting = {"A": "1", "__cocotb_params__": {"FRAMES": "10"}}
    assert utils.cocotb_params_env(setting) == {"COCOTB_FRAMES": "10"}
    assert setting == {"A": "1"}
    assert utils.cocotb_params_env(setting) == {}
