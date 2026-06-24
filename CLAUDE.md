# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

NDK-FPGA is the FPGA part of the Network Development Kit (NDK) for FPGA acceleration cards. It supports up to 400 Gigabit Ethernet applications. The primary languages are VHDL (HDL), SystemVerilog (verification), Tcl (build scripts), and Python (tooling/simulation).

Required tools: **Intel Quartus Prime Pro 25.1** (for Intel/Altera cards) or **Xilinx Vivado 2025.1** (for AMD/Xilinx cards), **Questa Sim-64 2025.2** (for UVM verification with System Verilog), **nvc** (for cocotb simulation).

## Commands

### Environment Setup
```sh
source env.sh      # Must be run before any Python tooling or cocotb flows
```

### Building FPGA Firmware (App for a Card)
```sh
cd apps/<app_name>/build/<card>/
make               # Default target (calls quartus or vivado depending on Makefile)
make SYNTH=vivado  # Override synthesis tool
make SYNTH=quartus

# Card-specific targets (e.g., for agi-fh400g):
make 400g1         # 1x400G Ethernet
make 100g4         # 4x100G Ethernet
```

### Building/Checking a Single Component
```sh
# From a component's synth/ directory:
cd comp/mi_tools/pipe/synth/
make               # Default vivado
make SYNTH=quartus
```

### UVM Simulation (Questa Sim)
```sh
# From a component's ver/ or uvm/ directory, launch with vsim:
cd apps/minimal/uvm/
vsim -do top_level.fdo

# Or trigger through make from synth dir (when SIM_SCRIPT is set):
make simulation
```

### Cocotb Tests
```sh
# Components with cocotb/ directory:
cd comp/mi_tools/pipe/cocotb/
make               # TARGET=cocotb is set in the Makefile

# Setup venv first (once):
source env.sh && ndk_fpga_venv_prepare && pip install python/cocotbext/
```

- Use Mamba (preffered) or Conda virtual environments instead of Python's venv if possible
- Install cocotb extensions if necessary (cocotb-bus, AXI, Avalon, etc.)
- Use version `cocotb>=2.0.1`

### Pytest (Makefile Validation)

- used for checking the physical hardware

```sh
pytest tests/pytest/test_make.py
pytest tests/pytest/test_make.py::TestClass::test_make   # Single test
```

### Linting
```sh
# SystemVerilog (Verible):
verible-verilog-lint --ruleset=none --rules_config=tests/verible/rules path/to/file.sv

# VHDL style (vsg):
vsg --configuration tests/ci/vsg_config.yaml --filename path/to/file.vhd
```

### OFM Python Package

- contains Python classes to access control physical devices with a running NDK bitsream 
- preferred to be installed system-wide or into Mamba virtual environment (with debugging flag when necessary)

```sh
source env.sh
cd python/ofm && pip install .
```

### Documentation
```sh
cd doc
python3 -m venv venv-doc && source venv-doc/bin/activate
pip install -r requirements.txt
make html          # Output: doc/build/index.html
```

## Architecture

### Directory Structure
```
core/         NDK core logic and configuration that is common for all cards
comp/         Reusable VHDL component library
apps/         Applications on the NDK platform with specific logic based on the application and cards
cards/        Per-board FPGA integration and configuration
build/        Common build infrastructure (Makefile includes, Tcl scripts)
python/       OFM Python package and cocotbext for simulation tooling
tests/        CI scripts, pytest suites, Verible lint rules
```

### Core (`core/`)
- `core/top/fpga_common.vhd` — sub top-level VHDL entity wiring all core NDK subsystems together (PCIe, DMA, Ethernet network module, TSU, MI bus, clocks, resets).
- `core/top/Modules.tcl` — lists all synthesizable sources for the core
  (packages, RTL sources); wires sub-components (PCIE, DMA, NETWORK_MOD,
  CLOCK_GEN, etc.). ARCHGRP variable allows to pass values down the hierarchy.
- `core/top/DevTree.tcl` — defines MI address space layout and NDK device-tree nodes.
- `core/top/mi_addr_space_pkg.vhd` - defines MI address space for RTL sources in `FPGA_COMMON` 
- `core/config/core_const.vhd` — PCIe BAR base addresses (ignore) and NDK version constants.
- `core/comp/` — core-specific major sub-components: `pcie/pcie_mod`, `dma/dma_mod`, `eth/network_mod`, `misc/`.
- `core/core.mk` — common Makefile include used by all card Makefiles; defines DMA_TYPE, ETH parameters, PCIe configuration defaults.

### Component Library (`comp/`)
Organized by bus protocol and function:
- `base/` — async utilities, FIFOs, memories, DSP, hash, packages (`math_pack.vhd`, `type_pack.vhd`, `dma_bus_pack.vhd`)
- `mfb_tools/` — Multi-Frame Bus (MFB) protocol components
- `mi_tools/` — MI (Memory-mapped Interface) bus components
- `mvb_tools/` — MVB (Multi-Value Bus) components
- `dma/` — DMA engine implementations: `dma_calypte/` (open-source), `dma_iuventus/` (open-source)
- `pcie/` — extending PCIe IP components
- `nic/` — NIC-level components, Ethernet LED control
- `tsu/` — Timestamp Unit

Each component typically has:
- `Modules.tcl` — source list (PACKAGES, MOD, COMPONENTS)
- `DevTree.tcl` — device-tree descriptor (if MI bus-addressable)
- `synth/Makefile` — synthesis/compile check entry point
- `ver/` or `uvm/` — UVM/functional verification testbench
- `cocotb/` — Python-based cocotb tests (newer components)

### Applications (`apps/`)
- `minimal/` — Reference application; passes packets between DMA and Ethernet with no processing.
- `iuventus/` — DMA Iuventus application.
- `sparklev/` — SparkleV application.

Each app has:
- `top/application_core.vhd` — application logic entity
- `build/<card>/Makefile` — card-specific build entry; sets `COMBO_BASE`, `CARD_BASE`, `APP_CONF`, Ethernet/PCIe/DMA parameters
- `build/<card>/app_conf.tcl` — app-level parameter overrides (DMA channels, project name, etc.)
- `uvm/` or `tests/` — verification testbenches and cocotb tests

### Cards (`cards/`)
Organized by vendor: `reflexces/`, `intel/`, `amd/`, `bittware/`, `silicom/`, `terasic/`, `iwave/`, `napatech/`, `prodesign/`.

Each card has:
- `src/fpga.vhd` — FPGA top-level entity (pin assignments, transceiver instantiation)
- `src/Modules.tcl` — pulls in `fpga_common` and card-specific IP
- `src/ip/` — vendor IP files (`.xci`(older)/`.tcl`(newer) for Vivado, `.ip`/`.qsys` for Quartus)
- `config/card_conf.tcl` — card parameters (ETH ports, PCIe config, DDR config)
- `src/card.mk` — card-specific Makefile include; sets NETCOPE_ENV and includes the appropriate synthesis Makefile
- `constr/` — timing and physical constraints

### Build System (`build/`)
- `Makefile` — entry point; selects `Makefile.Vivado.inc` or `Makefile.Quartus.inc` based on `SYNTH`
- `Makefile.Vivado.inc` / `Makefile.Quartus.inc` / `Makefile.Synplify.inc` — tool-specific rules
- `common.mk` — shared rules including the two-phase GEN_MK approach (Tcl generates a `.mk` file listing all sources, then make recurses with it)
- `Shared.tcl` — core Tcl procedures for traversing `Modules.tcl` hierarchy
- `Modelsim.inc.fdo` — ModelSim/Questa simulation helpers (`nb_sim_run`, `CompileMod`, `add_wave`)
- `DevTree.tcl` — device-tree assembly procedures
- `cocotb.mk` — cocotb venv setup target

## Key Conventions

### Device tree generation

- use functions in `dts_templates.tcl` to add nodes to the Device tree string
  instead of appending string directly

### Modules.tcl Structure
Every synthesizable component must have `Modules.tcl`. Variables used:
- `PACKAGES` — VHDL package files (compiled first)
- `MOD` — ordered list of VHDL/SV source files or `DevTree.tcl` generation
  scripts. These sources are sourced directly without referencing its own
  `Modules.tcl`. Use only for direct components in the entity's directory.
- `COMPONENTS` — sub-components as `[list "ENTITY_NAME" $ENTITY_BASE $ARCHGRP]`.
  Such referenced components have to have their own `Modules.tcl`.

The build system provides `ENTITY`, `ENTITY_BASE`, and `ARCHGRP` to every `Modules.tcl`.

```tcl
lappend COMPONENTS [list "MI_PIPE" $MI_PIPE_BASE "FULL"]
lappend MOD "$ENTITY_BASE/my_component.vhd"
```

### ARCHGRP Parameters
Architecture groups pass configuration down the hierarchy. At the top level
they're a TCL list; components convert them to an associative array for easier navigation:
```tcl
array set ARCHGRP_ARR $ARCHGRP
set DMA_TYPE $ARCHGRP_ARR(DMA_TYPE)
```

### DMA Types
Configured via `DMA_TYPE` environment variable or make parameter:
- `0` — no DMA
- `3` — DMA Medusa (closed-source, via DYNANIC partner)
- `4` — DMA Calypte (open-source)
- `5` — DMA Iuventus (open-source)
- `6` — DMA Hyperion (open-source)

### Commit Style
Commits must follow Conventional Commits (enforced by CI commitlint):
```
feat(component): add new feature
fix(dma): correct buffer overflow
refactor(pcie): simplify handshake logic
```

- The commits should be atomic, i.e. that they should contain a self containing
  change where checkout before them as well as on them should still allow to
  compile the sources. This requirement can be ommited when prototyping before
  doing the final cleanup. 
- merging into devel should be never done
- no automatic commiting unless allowed by the user on a per-prompt basis
- no "co-authored by" trailer

### Code Style

- 4-space indent, checked by `vsg` with config in `tests/ci/vsg_config.yaml`
- Python: pycodestyle + mypy type checking (Python 3.12+)
- All files: LF line endings, UTF-8, trailing whitespace trimmed (enforced by `.editorconfig`)

#### Verilog/SystemVerilog coding style

- Verible rules in `tests/verible/rules` (120-char line limit, explicit `begin`, generate labels required)
- explicitly specify parameters types for class parameters

#### VHDL coding style

- uppercase: entity names, architecture names, constants, enum constants, entity
  ports and generic parameters
- snake case: names of processes, functions, signals, variables
- postfixes for names: `_p` for processes, `_f` for functions, `_g` for generate
  statements, `_i` for component instances
- use only `std_logic_vector` and `std_logc` with their derived types in
  `type_pack.vhd` for interconnect between components and entity ports
- instantiate components directly using `<instance_name>_i : entity
  work.<ENTITY_NAME> ...` template
- use only IEEE compliant packages `numeric_std`, `numeric_std`, `math_real`,
  etc. for synthesis and not Synopsis compliant ones
- custom mathematical functions are available in `math_pack` package
- FSMs can be implemented in 3 ways based on its complexity:
  - 1 synchronous process for state register, next-state-logic and output logic
  - 2 processes: 1 synchronous for state register, 1 combinatorial for
    next-state logic and output logic
  - 3 processes: 1 synchronous for state register, 1 combinatorial for
    next-state logic, 1 for output logic
- each file has to be supplied with a header as a language-specific comment following this template:
```
<file_name>: <short description>
Copyright (C) 2025 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>

SPDX-License-Identifier: <license_specifier> 
```
    - there are three used licenses, `CERN-OHL-W-2.0` for RTL files,
      `Apache-2.0` for software sources and `CC-BY-4.0` for documentation. This applies
      for newly created files only and for the files where change of license has
      been explicitly requested.

