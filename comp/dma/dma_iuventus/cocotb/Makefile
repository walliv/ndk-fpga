# Makefile: Makefile to compile module
# Copyright (C) 2025 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0


TOP_LEVEL_ENT=dma_iuventus
TARGET=nvc-sim
NVC_PLATFORM_TAGS := xilinx

# nvc needs libpython to load the cocotb VHPI bridge; add the Python lib dir
# to LD_LIBRARY_PATH only for the nvc run step so the dynamic linker finds
# libpython3.12.so without shadowing system libraries for tclsh/other tools.
# NVC_RUN_ENV is picked up by build/common.mk's nvc recipe (nvc -r step only).
PYTHON_LIBDIR := $(shell python3 -c 'import sysconfig; print(sysconfig.get_config_var("LIBDIR"))' 2>/dev/null)
ifneq ($(PYTHON_LIBDIR),)
NVC_RUN_ENV := LD_LIBRARY_PATH=$(PYTHON_LIBDIR):$$LD_LIBRARY_PATH
endif

WAVEFORM_FILE=dma_iuventus.fst

# Hook shard directory cleanup into 'make clean'.
CLEAN_DEPENDS += clean_shards

# Waveform dumping is off by default for speed; set DEBUG_ENABLE=true to enable.
DEBUG_ENABLE ?= false

.PHONY: all see-wave clean_shards sim-parallel

all: comp

$(WAVEFORM_FILE): all

see-wave: $(WAVEFORM_FILE)
	surfer $< -s waveform.su &

clean_shards:
	-@$(RM) -r shard_*/

# sim-parallel: elaborate once, then run all 6 tests in parallel.
#
# The cocotb directory has no Vivado.tcl synthesis script.  Source-file
# discovery uses build/targets/comp_vivado.tcl instead, which is the same
# script the 'comp' target uses.  We pass it as a command-line override to
# the recursive $(MAKE) nvc-elab call so it takes highest-priority precedence
# over the Makefile-defined SYNTHFILES default (which would be 'Vivado.tcl').
#
# Usage:
#   make sim-parallel              # 6 tests in parallel, no waveforms (~60s)
#   make sim-parallel DEBUG_ENABLE=true  # same, with per-shard .fst waveforms
sim-parallel:
	$(MAKE) "SYNTHFILES=$(OFM_PATH)/build/targets/comp_vivado.tcl" nvc-elab
	cd $(CURDIR) && DEBUG_ENABLE=$(DEBUG_ENABLE) pytest -n auto -v test_dma_iuventus.py

include ../../../../build/Makefile
