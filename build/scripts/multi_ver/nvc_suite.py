# nvc_suite.py: parallel nvc runs of a cocotb bench, one pytest-xdist shard per (configuration, test)
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0
"""A bench's pytest file builds a Suite from its configurations and binds ``test_cocotb = suite.test_cocotb()``.
A configuration elaborates once into elab/<config>/nvcwork (file lock against concurrent workers); each shard runs
``nvc -r`` in a private copy under the pytest basetemp and appends one line to <PREFIX>_SUMMARY. nvc_suite.mk holds
the make targets."""

import ast
import fcntl
import json
import os
import re
import runpy
import shlex
import shutil
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path
from typing import Callable, Dict, List, Optional, Sequence, Tuple

import pytest

from multi_ver_utils import cocotb_params_env, create_setting_from_combination, expand_combinations
from ver_settings_default import shell_value

REPO_ROOT = Path(__file__).resolve().parents[3]
WALL_CAP_S = int(os.environ.get("WALL_CAP_S", "600"))
SUITE_REPEAT = int(os.environ.get("SUITE_REPEAT", "1"))
WAVES = os.environ.get("WAVES") == "1"
# --exit-severity of the nvc run, as NVC_EXIT_SEVERITY of the build; empty keeps nvc running after an RTL error.
EXIT_SEVERITY = os.environ.get("NVC_EXIT_SEVERITY", "error")
RTL_ERROR_PREFIXES = ("** Error", "** Failure", "** Fatal")


@dataclass
class Config:
    """One elaboration of the bench. A test None runs the whole test module in one shard; a configuration with run
    False only elaborates unless the configuration filter selects it."""
    generics: Dict[str, object]
    tests: Sequence[Optional[str]]
    run: bool = True
    env: Dict[str, str] = field(default_factory=dict)
    module: Optional[str] = None


def nvc_generic_args(generics: Dict[str, object]) -> List[str]:
    """A string is a ver_settings.py value, which the shell of multi_ver_cocotb.py and that of the make recipe both
    unquote, e.g. a string generic written as "\\\"ULTRASCALE\\\""."""
    args = []
    for key, val in generics.items():
        if isinstance(val, bool):
            val = "true" if val else "false"
        elif isinstance(val, str):
            val = " ".join(shlex.split(shell_value(val)))
        args += ["-g", f"{key}={val}"]
    return args


def cocotb_tests(module_file: Path) -> List[Optional[str]]:
    """The @cocotb.test functions of a test module, read without importing it."""
    tree = ast.parse(Path(module_file).read_text())
    return [node.name for node in tree.body if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
            and any(ast.unparse(dec.func if isinstance(dec, ast.Call) else dec) == "cocotb.test"
                    for dec in node.decorator_list)]


def ver_settings_configs(settings_file: Path, tests: Sequence[Optional[str]]) -> Dict[str, Config]:
    """The combinations multi_ver_cocotb.py runs from a ver_settings.py, each running `tests`. All of them: the
    random reduction by _combinations_run_percentage_ would give each xdist worker a different set. The cocotb
    parameters TEST_MODULES and TEST_FILTER select the module and the tests of a combination."""
    settings = runpy.run_path(str(settings_file))["SETTINGS"]
    settings.pop("_combinations_run_percentage_", None)
    configs = {}
    for name, comb in expand_combinations(settings).items():
        setting = create_setting_from_combination(settings, comb)
        env = cocotb_params_env(setting)
        configs[name] = Config(setting, tests, env=env, module=env.get("COCOTB_TEST_MODULES"))
    return configs


@lru_cache(maxsize=None)
def _cocotb_config(*args: str) -> str:
    return subprocess.check_output(["cocotb-config", *args], text=True).strip()


@lru_cache(maxsize=None)
def _ofm_origin(python: str, pythonpath: str) -> str:
    """Where the simulator's Python takes cocotbext.ofm from; an editable install of another tree can win."""
    code = "import cocotbext.ofm; print(list(cocotbext.ofm.__path__)[0])"
    env = dict(os.environ, PYTHONPATH=pythonpath)
    res = subprocess.run([python, "-c", code], env=env, capture_output=True, text=True)
    return res.stdout.strip() if res.returncode == 0 else f"not importable: {res.stderr.strip()[-200:]}"


class Suite:
    """`bench` is the bench directory or a file in it. `prefix` names the environment knobs <PREFIX>_CONFIG_FILTER,
    _TEST_FILTER, _SUMMARY and the <PREFIX>_CONFIG a shard gets. `record_fields` maps a summary field to a
    (regex, converter) on the shard log."""

    def __init__(self, bench: object, top: str, configs: Dict[str, Config], prefix: str, *,
                 module: str = "cocotb_test", heap: str = "4G", bench_error_re: str = r"\bERROR +cocotb\b",
                 origin_logged: bool = False,
                 record_fields: Optional[Dict[str, Tuple[str, Callable[[str], object]]]] = None):
        path = Path(str(bench)).resolve()
        self.bench_dir = path if path.is_dir() else path.parent
        self.top = top
        self.configs = configs
        self.prefix = prefix
        self.module = module
        self.heap = heap
        self.bench_error_re = bench_error_re
        self.origin_logged = origin_logged
        self.record_fields = record_fields or {}
        self.analysed = self.bench_dir / "nvcwork"
        self.elab_root = self.bench_dir / "elab"
        # The packages of this repository must win over any editable install of cocotbext/ofm pointing elsewhere.
        self.pythonpath = [str(self.bench_dir), str(REPO_ROOT / "python" / "cocotbext"),
                           str(REPO_ROOT / "python" / "ofm")]

    def _analysis_key(self) -> str:
        """Changes whenever nvcwork/ is re-analysed, so a stale per-config elaboration is redone."""
        stamps = [p.stat().st_mtime_ns for p in self.analysed.iterdir()]
        return f"{max(stamps)}:{len(stamps)}"

    def elaborate(self, name: str) -> Optional[str]:
        """Elaborates `name` once. Returns None on success, else the first fatal line of the elaboration log."""
        if not self.analysed.exists() or not any(self.analysed.glob("*")):
            raise RuntimeError(f"{self.analysed} is empty: run 'make suite-analyse' first")
        self.elab_root.mkdir(exist_ok=True)
        cfg_dir = self.elab_root / name
        stamp = cfg_dir / "nvcwork" / "elab_stamp.json"
        gen_args = nvc_generic_args(self.configs[name].generics)
        with open(self.elab_root / f".{name}.lock", "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            key = json.dumps({"generics": gen_args, "waves": WAVES, "analysis": self._analysis_key(),
                              "libpath": os.environ.get("NVC_LIBPATH", "")})
            if stamp.exists():
                prev = json.loads(stamp.read_text())
                if prev.get("key") == key:
                    return prev.get("error")
            if cfg_dir.exists():
                shutil.rmtree(cfg_dir)
            cfg_dir.mkdir(parents=True)
            shutil.copytree(self.analysed, cfg_dir / "nvcwork")
            cmd = ["nvc", "--work=nvcwork", "-H", "1G", "-M", self.heap, "-e", "-O3"]
            if WAVES:
                cmd += ["--no-collapse"]
            cmd += gen_args + [self.top]
            res = subprocess.run(cmd, cwd=cfg_dir, capture_output=True, text=True)
            log = res.stdout + res.stderr
            (cfg_dir / "elab.log").write_text(" ".join(cmd) + "\n" + log)
            error = None
            if res.returncode != 0:
                lines = log.splitlines()
                idx = next((i for i, ln in enumerate(lines) if ln.startswith(RTL_ERROR_PREFIXES)), None)
                error = " | ".join(lines[idx:idx + 2]) if idx is not None else f"nvc -e exit {res.returncode}"
            stamp.write_text(json.dumps({"key": key, "error": error}))
            return error

    def _label(self, name: str, test: Optional[str]) -> str:
        return test or self.configs[name].module or self.module

    def _selected(self, name: str, test: Optional[str]) -> bool:
        """Whether the COCOTB_TEST_FILTER of a configuration, matched as cocotb does, lets a test of it run."""
        cfg = self.configs[name]
        test_filter = cfg.env.get("COCOTB_TEST_FILTER")
        return test is None or not test_filter or bool(re.search(test_filter, f"{cfg.module or self.module}.{test}"))

    def params(self) -> list:
        only_cfg = os.environ.get(f"{self.prefix}_CONFIG_FILTER")
        only_test = os.environ.get(f"{self.prefix}_TEST_FILTER")
        params = []
        for rep in range(SUITE_REPEAT):
            for name, cfg in self.configs.items():
                if (only_cfg and name != only_cfg) or (not only_cfg and not cfg.run):
                    continue
                for test in cfg.tests:
                    label = self._label(name, test)
                    if (only_test and label != only_test) or not self._selected(name, test):
                        continue
                    pid = f"{name}-{label}" + (f"-r{rep}" if SUITE_REPEAT > 1 else "")
                    params.append(pytest.param(name, test, rep, id=pid))
        return params

    def _summary(self, record: dict) -> None:
        path = Path(os.environ.get(f"{self.prefix}_SUMMARY", self.bench_dir / "shards" / "summary.jsonl"))
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "a") as fh:
            fcntl.flock(fh, fcntl.LOCK_EX)
            fh.write(json.dumps(record) + "\n")

    def test_elaboration(self) -> Callable:
        """A pytest test that every configuration elaborates, also one that is not run by default."""
        @pytest.mark.parametrize("cfg", list(self.configs))
        def test_elaboration(cfg):
            error = self.elaborate(cfg)
            assert error is None, f"{cfg} does not elaborate: {error}"
        return test_elaboration

    def test_cocotb(self) -> Callable:
        """The pytest test of one shard, parametrized over (configuration, test, repetition)."""
        @pytest.mark.parametrize("cfg,testcase,rep", self.params())
        def test_cocotb(cfg, testcase, rep, tmp_path):
            record = {"config": cfg, "test": self._label(cfg, testcase), "rep": rep, "seed": None, "wall_s": None,
                      "result": "fail", "reason": "", "dir": str(tmp_path)}
            try:
                self.run_shard(cfg, testcase, tmp_path, record)
                record["result"] = "pass"
            except BaseException as exc:
                record["reason"] = str(exc).splitlines()[0][:300] if str(exc) else type(exc).__name__
                raise
            finally:
                self._summary(record)
        return test_cocotb

    def _shard_env(self, name: str, testcase: Optional[str], seed: str) -> dict:
        cfg = self.configs[name]
        env = dict(os.environ)
        env.update(
            COCOTB_TEST_MODULES=cfg.module or self.module,
            TOPLEVEL=self.top,
            TOPLEVEL_LANG="vhdl",
            PYGPI_PYTHON_BIN=_cocotb_config("--python-bin"),
            COCOTB_RESOLVE_X="ZEROS",
            LIBPYTHON_LOC=_cocotb_config("--libpython"),
            COCOTB_RANDOM_SEED=seed,
            PYTHONPATH=os.pathsep.join(self.pythonpath + [p for p in [env.get("PYTHONPATH", "")] if p]),
        )
        env[f"{self.prefix}_CONFIG"] = name
        env.update(cfg.env)
        # cocotb refuses COCOTB_TESTCASE next to COCOTB_TEST_FILTER, which a test shard narrows to its one test.
        env.pop("COCOTB_TESTCASE", None)
        if testcase is not None:
            env["COCOTB_TEST_FILTER"] = rf"^{re.escape(env['COCOTB_TEST_MODULES'])}\.{re.escape(testcase)}$"
        # cocotb >= 2.1 loads libpython only through GPI_USERS; 2.0 lacks --pygpi-entry-point.
        entry = subprocess.run(["cocotb-config", "--pygpi-entry-point"], capture_output=True, text=True)
        if entry.returncode == 0:
            env["GPI_USERS"] = f"{env['LIBPYTHON_LOC']};{entry.stdout.strip()}"
        libdir = subprocess.check_output(
            [sys.executable, "-c", "import sysconfig; print(sysconfig.get_config_var('LIBDIR') or '')"],
            text=True).strip()
        if libdir:
            env["LD_LIBRARY_PATH"] = os.pathsep.join([libdir, env.get("LD_LIBRARY_PATH", "")])
        return env

    def run_shard(self, name: str, testcase: Optional[str], tmp_path: Path, record: dict) -> None:
        label = f"{name}/{self._label(name, testcase)}"
        error = self.elaborate(name)
        if error is not None:
            pytest.fail(f"{name} does not elaborate: {error}")

        seed = (os.environ.get("COCOTB_RANDOM_SEED") or os.environ.get("RANDOM_SEED")
                or str(int.from_bytes(os.urandom(4), "little") & 0x7FFFFFFF))
        record["seed"] = int(seed)
        env = self._shard_env(name, testcase, seed)
        origin = _ofm_origin(env["PYGPI_PYTHON_BIN"], env["PYTHONPATH"])
        assert origin.startswith(str(REPO_ROOT)), f"{label}: cocotbext.ofm not taken from this repository ({origin})"

        # A private copy, not a symlink: nvc -r writes into the library, so shards would race on it.
        shutil.copytree(self.elab_root / name / "nvcwork", tmp_path / "nvcwork")
        cmd = ["nvc", "--work=nvcwork", "-H", "1G", "-M", self.heap, "-r"]
        if EXIT_SEVERITY:
            cmd += [f"--exit-severity={EXIT_SEVERITY}"]
        if WAVES:
            cmd += ["-w", f"{self.top}.fst", "--dump-arrays"]
        cmd += [self.top, "--ieee-warnings=off", "--load", _cocotb_config("--lib-name-path", "vhpi", "nvc")]

        logf = tmp_path / "shard.log"
        start = time.monotonic()
        with logf.open("w") as fh:
            fh.write(f"# {name} {self._label(name, testcase)} COCOTB_RANDOM_SEED={seed}\n# {' '.join(cmd)}\n")
            fh.flush()
            proc = subprocess.Popen(cmd, cwd=tmp_path, env=env, stdout=fh, stderr=subprocess.STDOUT)
            try:
                rc = proc.wait(timeout=WALL_CAP_S)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
                record["wall_s"] = round(time.monotonic() - start, 1)
                pytest.fail(f"{label}: exceeded the {WALL_CAP_S} s wall cap (seed {seed}, log {logf})")
        record["wall_s"] = round(time.monotonic() - start, 1)
        log_text = logf.read_text(errors="replace")
        tail = f"seed {seed}, log {logf}\n" + log_text[-3000:]
        self.check_results(label, testcase, tmp_path / "results.xml", rc, tail)
        self.check_log(label, log_text, record)

    def check_log(self, label: str, log_text: str, record: dict) -> None:
        if self.origin_logged:
            used = re.search(r"cocotbext\.ofm imported from (\S+)", log_text)
            assert used and used.group(1).startswith(str(REPO_ROOT)), (
                f"{label}: cocotbext.ofm not taken from this repository ({used.group(1) if used else 'not logged'})")
        # A severity-error assertion (PSL or VHDL) lets the simulation run on and cocotb still reports PASS, so
        # without this the RTL's own checks never fail anything.
        rtl_errors = [ln for ln in log_text.splitlines() if ln.startswith(RTL_ERROR_PREFIXES)]
        if rtl_errors and all(re.match(r"\*\* \w+: 0ms\+0", ln) for ln in rtl_errors):
            pytest.fail(f"{label}: stops at time 0, before any stimulus: {rtl_errors[0][:300]}")
        assert not rtl_errors, f"{label}: {len(rtl_errors)} RTL assertion error(s), first: {rtl_errors[0][:300]}"
        bench_errors = [ln for ln in log_text.splitlines() if re.search(self.bench_error_re, ln)]
        assert not bench_errors, f"{label}: {len(bench_errors)} bench error(s), first: {bench_errors[0][:300]}"
        for key, (pattern, conv) in self.record_fields.items():
            found = re.search(pattern, log_text)
            record[key] = conv(found.group(1)) if found else None

    def check_results(self, label: str, testcase: Optional[str], results: Path, rc: int, tail: str) -> None:
        """The shard's test passed, or with a whole-module shard every test of the module passed or was skipped."""
        assert results.exists(), f"{label}: nvc produced no results.xml (exit {rc}). {tail}"
        cases = list(ET.parse(results).getroot().iter("testcase"))
        if testcase is not None:
            cases = [tc for tc in cases if tc.get("name", "") == testcase
                     or tc.get("name", "").endswith("." + testcase)][:1]
            if not cases:
                pytest.fail(f"{label} not present in results.xml. {tail}")
            assert cases[0].find("skipped") is None, f"{label} reported skipped. {tail}"
        failed = [tc.get("name") for tc in cases if tc.find("failure") is not None or tc.find("error") is not None]
        assert not failed, f"{label} FAILED: {', '.join(str(n) for n in failed)}. {tail}"
        assert any(tc.find("skipped") is None for tc in cases), f"{label}: no test ran. {tail}"

    def main(self) -> None:
        """`<bench pytest file> --elab <config>` elaborates one configuration outside pytest."""
        if len(sys.argv) == 3 and sys.argv[1] == "--elab":
            err = self.elaborate(sys.argv[2])
            print(f"{sys.argv[2]}: " + ("elaborated" if err is None else f"does not elaborate: {err}"))
            sys.exit(0 if err is None else 1)
        sys.exit(f"usage: {sys.argv[0]} --elab <config>")
