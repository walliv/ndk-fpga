# test_vivado_flow.py: checks of the Vivado build flow that need tclsh only
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import os
import re
import shutil
import subprocess

from pathlib import Path

import pytest

from flow_utils import REPO, make, tcl_stubs, write_makefile

pytestmark = pytest.mark.skipif(shutil.which("tclsh") is None, reason="needs tclsh")

# Stand-ins for the Vivado commands that a generated filelist.tcl calls; each call is printed as one Tcl list.
VIVADO_STUBS = tcl_stubs(
    *"read_vhdl read_verilog read_xdc read_ip read_bd generate_target synth_ip get_ips get_files set_property".split()
)

VIVADO_INC = f"""
set env(OFM_PATH) {REPO}/
set env(FIRMWARE_BASE) {REPO}/
source {REPO}/build/Vivado.inc.tcl
"""

# An IP script that reports the build directory it was given and whether that exists.
IP_SCRIPT = """
set dir [dict get $IP_PARAMS_L IP_BUILD_DIR]
puts "ip_build_dir $dir [file isdirectory $dir]"
"""

# Runs SetupDesign of the Vivado flow on stand-ins for the Vivado commands it calls, which print their arguments.
SETUP_DESIGN = VIVADO_INC + tcl_stubs(
    *"create_project set_param set_property current_project update_ip_catalog config_ip_cache".split()
) + """
proc version {args} { return 2025.1 }
set NB_MAIN_CALLED 1
array set SYNTH_FLAGS {FPGA xcu55c-fsvh2892-2L-e OUTPUT stub SETUP_FLAGS {}}
SetupDesign SYNTH_FLAGS
"""

# An IP modification script for EvalFile that writes an output into its build directory only if asked to.
EVAL_IP_SCRIPT = """
set dir [dict get $IP_PARAMS_L IP_BUILD_DIR]
puts "exists [file isdirectory $dir]"
if {[dict get $IP_PARAMS_L WRITE]} { close [open $dir/stub.xci w] }
"""


def tclsh(directory, script, env=None):
    result = subprocess.run(["tclsh"], input=script, cwd=directory, capture_output=True, text=True, env=env)
    assert result.returncode == 0, result.stderr
    return result.stdout.splitlines()


@pytest.fixture
def repository(tmp_path):
    """A stub repository with one VHDL source and one IP script, and a build directory that makes it like a card does."""
    repo = tmp_path / "repo"
    (repo / "comp" / "ip").mkdir(parents=True)
    (repo / "comp" / "top.vhd").touch()
    (repo / "comp" / "ip" / "stub.ip.tcl").write_text(IP_SCRIPT)
    (repo / "comp" / "Modules.tcl").write_text(
        'lappend MOD "$ENTITY_BASE/top.vhd"\n'
        'lappend MOD [list "$ENTITY_BASE/ip/stub.ip.tcl" TYPE VIVADO_TCL PHASE {ADD_FILES}'
        ' IP_BUILD_DIR "$ENTITY_BASE/ip/ipcfg_0123abcd" IP_DIR_KEYED 1'
        ' VARS [list IP_PARAMS_L [list IP_BUILD_DIR "$ENTITY_BASE/ip/ipcfg_0123abcd"]]]\n'
    )
    build = repo / "build"
    build.mkdir()
    (build / "Vivado.tcl").write_text(
        f"set COMBO_BASE {repo}\n"
        f"source {REPO}/build/targets/comp_vivado.tcl\n"
    )
    write_makefile(build, "stub", repo / "comp")
    return repo


def test_filelist(repository, tmp_path):
    result = make(repository / "build", "filelist")
    assert result.returncode == 0, result.stderr
    filelist = repository / "build" / "filelist.tcl"
    assert str(repository) not in filelist.read_text()

    # The generated script must work from another checkout, which the sourcing shell names in shell_git_root.
    moved = tmp_path / "moved"
    shutil.copytree(repository, moved)
    output = tclsh(moved / "build", f"{VIVADO_STUBS}\nset shell_git_root {moved}\nsource filelist.tcl\n")
    assert f"read_vhdl -library work -vhdl2008 {moved}/comp/top.vhd" in output
    assert f"ip_build_dir {moved}/comp/ip/ipcfg_0123abcd 1" in output
    assert not (moved / "comp" / "ip" / "ipcfg_0123abcd").exists()


def test_filelist_needs_shell_git_root(repository):
    result = make(repository / "build", "filelist")
    assert result.returncode == 0, result.stderr
    result = subprocess.run(["tclsh", "filelist.tcl"], cwd=repository / "build", capture_output=True, text=True)
    assert result.returncode != 0
    assert "shell_git_root variable is undefined" in result.stderr


def filelist_output(repository, modules):
    """What sourcing the filelist.tcl that make generates for a Modules.tcl prints, with stand-ins for Vivado."""
    (repository / "comp" / "Modules.tcl").write_text(modules)
    result = make(repository / "build", "filelist")
    assert result.returncode == 0, result.stderr
    return tclsh(repository / "build", f"{VIVADO_STUBS}\nset shell_git_root {repository}\nsource filelist.tcl\n")


def test_filelist_follows_eval_file(repository):
    """The filelist takes the library and the file properties of a source and skips a script outside ADD_FILES."""
    (repository / "comp" / "pkg.vhd").touch()
    (repository / "comp" / "pins.xdc").touch()
    (repository / "comp" / "ip" / "unphased.ip.tcl").write_text('puts "must not run"\n')
    output = filelist_output(repository, (
        'lappend MOD [list lib "$ENTITY_BASE/pkg.vhd"]\n'
        'lappend MOD [list "$ENTITY_BASE/pins.xdc" TYPE CONSTR_VIVADO SCOPED_TO_REF top'
        " VIVADO_SET_PROPERTY {USED_IN synthesis}]\n"
        'lappend MOD [list "$ENTITY_BASE/ip/unphased.ip.tcl" TYPE VIVADO_TCL]\n'
    ))
    assert f"read_vhdl -library lib -vhdl2008 {repository}/comp/pkg.vhd" in output
    assert f"read_xdc {repository}/comp/pins.xdc" in output
    assert "set_property SCOPED_TO_REF top {}" in output
    assert "set_property USED_IN synthesis {}" in output
    assert "must not run" not in output


def test_eval_file_sets_the_file_properties(tmp_path):
    output = tclsh(tmp_path, VIVADO_INC + tcl_stubs("add_files", "get_files", "set_property") + (
        "EvalFile /src/pins.xdc [list TYPE CONSTR_VIVADO SCOPED_TO_REF top VIVADO_SET_PROPERTY {USED_IN synthesis}]\n"
    ))
    assert "set_property SCOPED_TO_REF top {}" in output
    assert "set_property USED_IN synthesis {}" in output


def setup_design(directory, cache_dir=None):
    env = {k: v for k, v in os.environ.items() if k != "NDK_IP_CACHE_DIR"}
    if cache_dir is not None:
        env["NDK_IP_CACHE_DIR"] = str(cache_dir)
    return tclsh(directory, SETUP_DESIGN, env)


def test_ip_cache_is_opt_in(tmp_path):
    output = setup_design(tmp_path)
    assert not [line for line in output if "config_ip_cache" in line or "IP synthesis cache" in line]


def test_ip_cache(tmp_path):
    cache = tmp_path / "cache" / "2025.1"
    output = setup_design(tmp_path, tmp_path / "cache")
    assert f"config_ip_cache -use_cache_location {cache}" in output
    assert [line for line in output if line.startswith("set_property IP_CACHE_PERMISSIONS {read write}")]
    assert f"IP synthesis cache: {cache}" in output
    assert cache.is_dir()
    assert not list(cache.iterdir())


def test_unusable_ip_cache_is_disabled(tmp_path):
    (tmp_path / "file").touch()
    output = setup_design(tmp_path, tmp_path / "file" / "cache")
    assert not [line for line in output if "config_ip_cache" in line]
    assert [line for line in output if line.startswith("WARNING: IP synthesis cache disabled")]


@pytest.fixture
def ip_base(tmp_path):
    (tmp_path / "ip").mkdir()
    (tmp_path / "ip" / "stub.ip.tcl").write_text("# modification script\n")
    return tmp_path


def ip_build_dirs(base, **params):
    """IP_BUILD_DIR of each source that get_ip_mod_files returns for a stub IP of the given parameters."""
    params = {"IP_BUILD_DIR": base / "build", "IP_MODIFY_BASE": base / "ip", "IP_TEMPLATE_BASE": base / "template",
              "IP_DEVICE_FAMILY": "Ultrascale+", **params}
    tcl_params = " ".join(f"{name} {{{value}}}" for name, value in params.items())
    return tclsh(base, (
        f"source {REPO}/core/ip/common.tcl\n"
        f'foreach item [get_ip_mod_files [list [list "" stub stub_ip "" 1]] [list {tcl_params}]] {{\n'
        "    puts [dict get [lrange $item 1 end] IP_BUILD_DIR]\n"
        "}\n"
    ))


def test_ip_dir_is_keyed_by_the_parameters(ip_base):
    dirs = ip_build_dirs(ip_base, WIDTH=8)
    assert len(dirs) == 1
    assert Path(dirs[0]).parent == ip_base / "build"
    assert re.fullmatch(r"ipcfg_[0-9a-f]{8}", Path(dirs[0]).name)
    assert ip_build_dirs(ip_base, WIDTH=8) == dirs
    assert ip_build_dirs(ip_base, WIDTH=16) != dirs
    (ip_base / "ip" / "stub.ip.tcl").write_text("# another modification script\n")
    assert ip_build_dirs(ip_base, WIDTH=8) != dirs


def test_ip_dir_key_ignores_the_build_dir(ip_base):
    dirs = ip_build_dirs(ip_base, WIDTH=8)
    moved = ip_build_dirs(ip_base, WIDTH=8, IP_BUILD_DIR=ip_base / "other")
    assert Path(moved[0]).name == Path(dirs[0]).name


def test_quartus_ip_dir_is_not_keyed(ip_base):
    assert set(ip_build_dirs(ip_base, IP_DEVICE_FAMILY="Agilex")) == {str(ip_base / "build")}


def eval_ip_script(directory, ip_dir, write, keyed=True):
    """Runs a stub IP script through EvalFile, as the Vivado flow does, with ip_dir as its build directory."""
    script = directory / "stub.ip.tcl"
    script.write_text(EVAL_IP_SCRIPT)
    return tclsh(directory, VIVADO_INC + (
        f"EvalFile {script} [list TYPE VIVADO_TCL PHASE ADD_FILES IP_BUILD_DIR {ip_dir} IP_DIR_KEYED {int(keyed)}"
        f" VARS [list IP_PARAMS_L [list IP_BUILD_DIR {ip_dir} WRITE {int(write)}]]]\n"
    ))


@pytest.mark.parametrize("write", [False, True])
def test_keyed_ip_dir(tmp_path, write):
    ip_dir = tmp_path / "ipcfg_0123abcd"
    assert "exists 1" in eval_ip_script(tmp_path, ip_dir, write)
    assert ip_dir.is_dir() == write


def test_unkeyed_ip_dir_is_left_alone(tmp_path):
    assert "exists 0" in eval_ip_script(tmp_path, tmp_path / "ipcfg_0123abcd", False, keyed=False)
    assert not (tmp_path / "ipcfg_0123abcd").exists()
