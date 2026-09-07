# Makefile: Common make script for firmware targets
# Copyright (C) 2019 CESNET z. s. p. o.
# Author(s): Martin Spinler <spinler@cesnet.cz>
#
# SPDX-License-Identifier: BSD-3-Clause

# Some basic tools
RM ?= rm -f
TCLSH ?= tclsh

.PHONY: simulation vhdocl cocotb clean_common coverage-report

GEN_MK_TARGETS += simulation vhdocl cocotb ghdl-sim nvc nvc-sim nvc-elab nvc-run
simulation: GEN_MK_ENV=SIM_SCRIPT=$(SIM_SCRIPT) SIM_FLAGS=$(SIM_FLAGS)

NVC_PLATFORM_TAGS ?= altera xilinx
nvc: NETCOPE_ENV+=PLATFORM_TAGS="$(NVC_PLATFORM_TAGS)"
nvc-sim: NETCOPE_ENV+=PLATFORM_TAGS="$(NVC_PLATFORM_TAGS)"
nvc-elab: NETCOPE_ENV+=PLATFORM_TAGS="$(NVC_PLATFORM_TAGS)"
nvc-run: NETCOPE_ENV+=PLATFORM_TAGS="$(NVC_PLATFORM_TAGS)"

# INFO: NETCOPE_TEMP is generated directory
clean_common:
	-@$(RM) -r nvcwork/ $(NETCOPE_TEMP)
	-@$(RM) DevTree_paths.txt vhdocl.doc vhdocl.conf

# coverage-report: recursively merges every *.ncdb under cwd, renders an HTML report. Run after
# seeded COVERAGE_EN=... runs (distinct COVERAGE_FILE each) for multi-seed coverage. Needs no
# Modules.tcl, so it skips the GEN_MK_TARGET machinery below.
COVERAGE_MERGED     ?= coverage_merged.ncdb
COVERAGE_REPORT_DIR ?= coverage_report
coverage-report:
	$(eval NCDB_FILES := $(shell find . -name '*.ncdb' -not -name '$(notdir $(COVERAGE_MERGED))'))
	@if [ -z "$(NCDB_FILES)" ]; then \
		echo "*** no .ncdb coverage databases found under $(CURDIR) -- run with COVERAGE_EN=... first ***" >&2; \
		exit 1; \
	fi
	nvc --cover-merge -o $(COVERAGE_MERGED) $(NCDB_FILES)
	nvc --cover-report -o $(COVERAGE_REPORT_DIR) $(COVERAGE_MERGED)
	@echo "Coverage report: $(COVERAGE_REPORT_DIR)/index.html (merged from: $(NCDB_FILES))"

MAKE_REC = $(MAKE) -f $(firstword $(MAKEFILE_LIST)) --no-print-directory $(NETCOPE_ENV)

define print_label
	@echo '*****************************************************************************'
	@echo '* $(1)'
	@echo '*****************************************************************************'
endef

GEN_MK_NAME ?= $(OUTPUT_NAME).$(SYNTH).mk

# $(GEN_MK_NAME) holds $(MOD) (source list) plus TCL-generated targets. Two-phase make: phase 1
# depends only on it and recurses; phase 2 includes it, using $(MOD) for the real target. List
# phase-2 targets in $(GEN_MK_TARGETS).
ifneq ($(GEN_MK_TARGET),)
include $(GEN_MK_NAME)

simulation: $(MOD)
	$(NETCOPE_ENV) vsim -64 -do "$(SIM_SCRIPT)" $(SIM_FLAGS)

.PHONY: cocotb
COCOTB_SIM_SCRIPT ?= $(OFM_PATH)/build/scripts/cocotb/cocotb.fdo
COCOTB_TEST_MODULES ?= cocotb_test
cocotb: $(MOD)
	$(NETCOPE_ENV) SYNTHFILES=$(SYNTHFILES) COCOTB_TEST_MODULES=$(COCOTB_TEST_MODULES) vsim -64 -do $(COCOTB_SIM_SCRIPT) $(SIM_FLAGS)

# Automated documentation script
vhdocl:
	echo "outputdir=vhdocl.doc" > vhdocl.conf
	for m in $(MOD); do echo $$m | grep .vhd | sed 's/^/input\ /' >> vhdocl.conf; done
	vhdocl -f vhdocl.conf

# Cocotb runtime args
COCOTB_RUN_ARGS:=

ifneq ($(RANDOM_SEED),)
COCOTB_RUN_ARGS += COCOTB_RANDOM_SEED=$(RANDOM_SEED)
endif

# Without this, nvc keeps running after a PSL/ERROR violation and cocotb prints a clean PASS
# summary -- only nvc's exit code goes nonzero. This flag aborts the run so cocotb marks it FAIL
# too. "error" avoids nvc's own "note"/"warning" messages.
NVC_RUN_ARGS += --exit-severity=error

# DEBUG_ENABLE=true adds waveform/introspection flags: --no-collapse at elaboration (keeps all
# signals visible), -w and --dump-arrays at run (dumps the waveform incl. arrays). Default false
# skips the dumping overhead.
DEBUG_ENABLE?=false
ifeq ($(DEBUG_ENABLE),true)
NVC_ELAB_ARGS += --no-collapse
NVC_RUN_ARGS  += -w --dump-arrays
endif

# COVERAGE_EN selects nvc coverage kinds at ELABORATION only; toggling it needs re-elaboration. Off
# by default. COVERAGE_FILE must be distinct per independently-seeded/sharded run, or a later run
# silently overwrites the earlier database.
COVERAGE_EN ?=
ifneq ($(COVERAGE_EN),)
ifeq ($(COVERAGE_EN),all)
NVC_ELAB_ARGS += --cover
else
NVC_ELAB_ARGS += --cover=$(COVERAGE_EN)
endif
ifneq ($(COVERAGE_FILE),)
NVC_ELAB_ARGS += --cover-file=$(COVERAGE_FILE)
endif
endif

# check_cocotb_results: fails the recipe when results.xml records a failure -- --exit-severity=error
# only makes nvc's exit nonzero on a VHDL/PSL abort, not a TestFailure, so rc would stay 0.
# expect_fail=True scores PASSED, so it won't trip this.
define check_cocotb_results
	@if grep -q '<failure' results.xml 2>/dev/null; then \
		echo "*** cocotb reported a test FAILURE -- see results.xml ***" >&2; \
		exit 1; \
	fi
endef

COCOTB_ENV=\
COCOTB_TEST_MODULES=$(COCOTB_TEST_MODULES) \
TOPLEVEL=$(TOP_LEVEL_ENT_LC) \
TOPLEVEL_LANG=vhdl \
$(NETCOPE_ENV) \
$(COCOTB_RUN_ARGS) \
PYGPI_PYTHON_BIN=$(shell cocotb-config --python-bin) \
COCOTB_RESOLVE_X=ZEROS \
LIBPYTHON_LOC=$(shell cocotb-config --libpython)

GHDL_WORK_DIR?=work_ghdl
ghdl-sim: $(MOD)
	@mkdir -p $(GHDL_WORK_DIR)
	$(eval TOP_LEVEL_ENT_LC:=$(shell echo $(TOP_LEVEL_ENT) | tr '[:upper:]' '[:lower:]'))
	ghdl -i --workdir=$(GHDL_WORK_DIR) $(addprefix -P,$(GHDL_LIBS)) --std=08 -frelaxed --ieee=synopsys $(filter %.vhd,$(MOD))
	ghdl -m --workdir=$(GHDL_WORK_DIR) $(addprefix -P,$(GHDL_LIBS)) --std=08 -frelaxed --ieee=synopsys --warn-no-hide $(TOP_LEVEL_ENT_LC)
	$(COCOTB_ENV) ghdl -r -v --workdir=$(GHDL_WORK_DIR) -P$(GHDL_WORK_DIR) $(addprefix -P,$(GHDL_LIBS)) $(TOP_LEVEL_ENT_LC) --vpi=$(shell cocotb-config --lib-name-path vpi ghdl) --asserts=disable --vcd=$(OUTPUT_NAME).vcd

NVC_LOAD ?=
nvc-sim: NVC_LOAD=--load $(shell cocotb-config --lib-name-path vhpi nvc)
nvc-sim: nvc
nvc-run: NVC_LOAD=--load $(shell cocotb-config --lib-name-path vhpi nvc)

# NVC_RUN_ENV: extra environment variables prepended only to the nvc -r step.
# Use this to set LD_LIBRARY_PATH or similar per-project without affecting
# the tclsh mk-file generation step that also uses NETCOPE_ENV.
NVC_RUN_ENV ?=
nvc: $(MOD)
	$(eval TOP_LEVEL_ENT_LC:=$(shell echo $(TOP_LEVEL_ENT) | tr '[:upper:]' '[:lower:]'))
	nvc --work=nvcwork -H 1G -M 16G --std=2008 -a --relaxed --psl $(filter %.vhd,$(MOD))
	nvc --work=nvcwork -H 1G -M 16G -e -O3 $(NVC_ELAB_ARGS) $(TOP_LEVEL_ENT_LC)
	$(NVC_RUN_ENV) $(COCOTB_ENV) nvc --work=nvcwork -H 1G -M 16G -r $(NVC_RUN_ARGS) $(TOP_LEVEL_ENT_LC) --ieee-warnings=off $(NVC_LOAD)
	$(call check_cocotb_results)

# nvc-elab: analyze + elaborate only (no run). Used by the parallel runner
# (make sim-parallel) to build nvcwork/ once before launching per-test shards.
nvc-elab: $(MOD)
	$(eval TOP_LEVEL_ENT_LC:=$(shell echo $(TOP_LEVEL_ENT) | tr '[:upper:]' '[:lower:]'))
	nvc --work=nvcwork -H 1G -M 16G --std=2008 -a --relaxed --psl $(filter %.vhd,$(MOD))
	nvc --work=nvcwork -H 1G -M 16G -e -O3 $(NVC_ELAB_ARGS) $(TOP_LEVEL_ENT_LC)

# nvc-run reuses an existing nvcwork/ (no analyze/elaborate): fast iteration on cocotb Python,
# loaded at run time. Run `make nvc-elab` once, then `COCOTB_TESTCASE=<name> make nvc-run` per
# edit, skipping ~50 s of analyze+elaborate.
nvc-run: $(MOD)
	$(eval TOP_LEVEL_ENT_LC:=$(shell echo $(TOP_LEVEL_ENT) | tr '[:upper:]' '[:lower:]'))
	$(NVC_RUN_ENV) $(COCOTB_ENV) nvc --work=nvcwork -H 1G -M 16G -r $(NVC_RUN_ARGS) $(TOP_LEVEL_ENT_LC) --ieee-warnings=off $(NVC_LOAD)
	$(call check_cocotb_results)

else
.PHONY: $(GEN_MK_NAME)
$(GEN_MK_NAME):
	$(call print_label,Generate Makefile "$(GEN_MK_NAME)" with prerequisites)
	@$(NETCOPE_ENV) $(TCLSH) $(SYNTHFILES) -t makefile -p $(GEN_MK_NAME)

$(GEN_MK_TARGETS): $(GEN_MK_NAME)
	@$(MAKE_REC) $(GEN_MK_ENV) GEN_MK_TARGET=1 $@
endif
