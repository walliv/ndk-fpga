# General rules 

- required tools: **Intel Quartus Prime Pro 25.1** (for Intel/Altera cards) or **Xilinx Vivado 2025.1** (for AMD/Xilinx cards), **Questa Sim-64 2025.2** (for UVM verification with System Verilog), **nvc** (for cocotb simulation).
- each background task running in Claude should be actively monitored so it doesn't stuck.
  Poll at 5, 15, 30 or 60 s -- no other rate. Wait on the artefact the task produces (a log
  marker, an exit code), never on a `pgrep` pattern that also matches the waiter's own command
  line: that self-matches, never exits, and reports a finished task as still running
- results can be deemed successful if the experiment they came from is
  repeatable at least 10 times and each iteration yielded comparable results 
- use multiple agents with various models:
  - the strongest available model (Fable/Opus) as the main orchestrator and conductor — it owns
    design, precise task specs, root-cause triage, review of agent output, and premise-questioning
    (e.g. "is this fix's area cost acceptable?", "is the testbench traffic model realistic?").
    Judgment calls bounce back to this layer; don't expect implementation agents to resolve them.
  - Sonnet for code writing, testbench iteration and debugging — excellent when the spec is
    precise and self-contained (implementations land near-clean; verification discipline is
    strong: cycle-level tracing, A/B controls, honest gate reporting). Its known limits: deep
    multi-hypothesis debugging converges slowly across hand-offs, and it defaults to workarounds
    over convention-level fixes when a premise is wrong — the orchestrator must supply that.
  - escalate selectively: for gnarly root-cause work in shared/high-blast-radius components
    (timing races, cross-component protocol bugs), override the per-invocation agent model to
    Opus/Fable rather than burning multiple Sonnet hand-offs.
  - Haiku for rapid testing, research and explore (read-only reconnaissance with file:line
    evidence).
- additional resources can be copied to the `../docs/` directory. These include:
  - documentation
  - data sheets
  - scientific articles
  - product guides
  - design guides
  - etc.

## Assistant output formatting

- hard-wrap prose in chat responses at **80 characters** per line; do not rely
  on the terminal to soft-wrap it
- exempt from wrapping, because breaking them makes them wrong rather than tidy:
  - fenced code blocks and inline code
  - tables
  - file paths and `file:line` references
  - command lines meant to be copy-pasted
- this governs chat output only. Source-comment length is a separate rule
  (250 characters per comment block) under Commentaries in the code below

## Commit Style

Commits must follow Conventional Commits (enforced by CI commitlint):
```
feat(component): add new feature
fix(dma): correct buffer overflow
refactor(pcie): simplify handshake logic
```

- The commits should be atomic, i.e. that they should contain a self containing
  change where checkout before them as well as on them should still allow to
  compile the sources successfully, test that it is working AND contain
  means to test/verify that it is working. This requirement can be ommited during 
  prototyping on a separate branch before creating a pull request. 
- merging into the `devel` branch should be never done
- use branch `ziti_devel` as this repository's equivalent of a devel branch but
  never merge nor commit to it
- no automatic commiting unless allowed by the user on a per-prompt basis
- no "co-authored by" trailer

## Verification

- use `cocotb` for verification
- insert PSL assertions to VHDL as an additional level of verification
- each verification suite has to be equpped with:
  1. One or multiple stimulus generators for multiple interfaces
  2. DUT
  3. High-level model of the DUT that generates reference output
  4. One or multiple monitors on the output signals and interfaces
  5. Scoreboard where data from monitor(s) and reference data from the model are compared
- If there are are backpressure signals to the DUT (for example MFB's `DST_RDY`,
AXI Masters's `AWREADY`/`WREADY`, etc.), there should be randomly toggled or
toggled based on that component's specification with specific rate. Having
backpressure successively disengaged is only allowed when explicitly requested
on a per-prompt basis.
- The verification agents can use specific seeds for debugging to get
  deterministic outputs. However, verification is only valid when it uses random
  seeding inspite passig previously on concrete seed.
- Use Python bus modules for standardized interfaces (like
  `MFBDriver`/`MFBMonitor` for MFB or classes of `cocotbext-axi`, for axi
  interfaces)

## Code Style

- 4-space indent, checked by `vsg` with config in `tests/ci/vsg_config.yaml`
- for commentaries see the Commentaries in the code section below

### Verilog/SystemVerilog coding style

- Verible rules in `tests/verible/rules`
- explicitly specify parameters types for class parameters

### VHDL coding style

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
- use `all` keyword in sensitivity list of combinatorial processes
- instantiate `for` loops in processes as little as possible
- instances of components need to declare all generics and ports even when just
  assigning them a constant or default value

## Commentaries in the code

- Commentaries in the code should be kept sufficiently condensed, its maximum length must be 250
  characters for each statement they are commenting.
  There are some exceptions to this rule:
  - commented out code
  - file headers with authors/licenses/small descriptions
  - compiler-specific directives
- The paragraphs in comments are not allowed. Two commentary blocks separated by one or more
  newlines are considered a single commentary block and thus also a subject of this prohibition.
- The best commentary is no commentary since code should document itself to the highest degree
  possible. The code answers WHAT is done whereas the commentary, if it needs to be used, describes
  WHY is it done.

## Commands

### Environment Setup
```sh
source env.sh      # Must be run before any Python tooling or cocotb flows
export PATH=$HOME/miniforge3/envs/ndk-env/bin:$PATH   # ndk-env python for ALL Python tooling
```

Always use the Python from the **`ndk-env`** mamba environment. It is the only one with
`pytest`, `pytest-xdist` and `cocotb` together. Put its `bin` on `PATH` rather than passing
`PYTHON=` to make: the cocotb Makefile derives `PYTHON_LIBDIR` from a hardcoded `python3` and
resolves `cocotb-config` from `PATH`, so overriding only `PYTHON` desynchronises them and every
test fails at once with `nvc produced no results.xml (exit 0)` — the VHPI bridge failing to load,
which reads like an RTL fault but is not one. Bare `python3` is miniforge base and has no pytest.

### Building FPGA Firmware (App for a Card)

Building a card's bitstream: see the `bitstream-build` skill.

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

### Linting
```sh
# SystemVerilog (Verible):
verible-verilog-lint --ruleset=none --rules_config=tests/verible/rules path/to/file.sv

# VHDL style (vsg):
vsg --configuration tests/ci/vsg_config.yaml --filename path/to/file.vhd
```

### OFM Python Package

- preferred to be installed system-wide or into Mamba virtual environment (with debugging flag when necessary)

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

