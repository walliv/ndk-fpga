# cocotb_fs.mk: what the file shell's cocotb benches share; a bench Makefile includes it last
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

FS_DIR    := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
BENCH_DIR := $(abspath $(dir $(firstword $(MAKEFILE_LIST))))

TOP_LEVEL_PATH ?= .
# build/Makefile turns cocotb into nvc-sim under SIM=nvc; SIM=questa runs the same bench in Questa.
TARGET ?= cocotb
SIM ?= nvc

# Each bench names its generics once: they reach nvc's elaboration and the cocotb test's environment.
NVC_ELAB_ARGS += $(foreach g,$(FS_GENERICS),-g $(g)=$($(g)))
export $(FS_GENERICS)

NVC_PLATFORM_TAGS := xilinx
# The PSL checks and the abort on an error are opt-in in the nvc flow; the benches rely on both.
NVC_PSL ?= 1
NVC_EXIT_SEVERITY ?= error

# This tree's cocotbext.ofm must win over an installed one; the models, the bench helpers and the app's
# shared DMA model and scoreboard are imported as top-level modules.
NVC_RUN_ENV += PYTHONPATH=$(OFM_PYTHONPATH):$(BENCH_DIR):$(FS_DIR)/model:$(FS_DIR)/tb:$(FS_DIR)/../cocotb_common:$(FS_DIR)/../../sw:$$PYTHONPATH

# nvc-elab and nvc-run (build once, run many seeds) need the generator `comp` would export.
SYNTHFILES ?= $(abspath $(FS_DIR)/../../../../build/targets/comp_vivado.tcl)
export SYNTHFILES

.PHONY: all
all: comp

include $(FS_DIR)/../../../../build/Makefile
