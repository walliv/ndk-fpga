# Copilot instructions for ndk-fpga

## Build, test, and lint
- **Docs build:** `pip3 install --user GitPython sphinx sphinx-vhdl sphinx-rtd-theme` then `cd doc && make html` (output: `doc/build/index.html`).
- **OFM Python package (tools/utilities):** from `python/ofm`, `source ../../env.sh` then `pip install .` (requires Python 3.11+).
- **Pytest Makefile validation:** `pytest tests/pytest/test_make.py`
- **Run a single pytest:** `pytest tests/pytest/test_make.py::TestClass::test_make`
- **Card pytest suites (hardware-dependent):** `pytest cards/reflexces/agi-fh400g/bts/test_pcie.py::test_check_pcie_device_in_lspci`
- **SystemVerilog lint (Verible):** `verible-verilog-lint --ruleset=none --rules_config=tests/verible/rules path/to/file.sv`

## High-level architecture
- **core/** holds the NDK core top-level and shared configs; its `Modules.tcl` and `DevTree.tcl` wire core components together.
- **comp/** is the reusable VHDL component library. Components generally ship with a `Modules.tcl` (source list) and sometimes `DevTree.tcl` for device-tree integration.
- **apps/** contains application-specific logic (e.g., Minimal, Iuventus). Each app typically has `comp/` sources, `sw/` tools/scripts, and `build/<card>/` build setups for specific cards.
- **cards/** contains per-board integration: constraints under `constr/`, top-level FPGA wrappers under `src/`, and vendor IP generation scripts or XCI sources (older approach) under `src/ip/`.
- **python/** hosts the OFM package and cocotbext helpers used for simulation tooling and register-map utilities.

## Key conventions
- **Commit atomicity:** keep changes for a single logical change in one commit; do not split a change across multiple commits so intermediate checkouts stay coherent for debugging.
- **Modules.tcl** lists synthesizable sources for build scripts; **DevTree.tcl** defines NDK device-tree nodes where present. New components should follow this pattern.
- **env.sh** at the repo root is the expected way to populate environment variables for Python tooling and cocotb flows.
- **Vendor IP generation scripts** live under `cards/<vendor>/<card>/src/ip/` and can be represented either by a pre-generated XCI file or a generation TCL script. These directories can contain build artifacts which are not tracked, however.
- **Verible lint rules** are centralized in `tests/verible/rules` and used by CI tooling for SystemVerilog checks.
