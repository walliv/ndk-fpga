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

# Number of independent SQ/CQ queues (one per SSD) to elaborate the RTL with (DMA_IUVENTUS's
# NUM_QUEUES generic) AND to run the cocotb multi-queue testbench with (misc_const.NUM_QUEUES
# reads this same env var at run time) -- see cocotb_test.py's prepare_multi(). Both sides MUST
# agree, so this single variable drives both `nvc -e -g NUM_QUEUES=...` and the pytest subprocess
# environment. Usage:
#   make sim-parallel                    # NUM_QUEUES=1 (default), original single-queue suite
#   make sim-parallel NUM_QUEUES=4       # elaborate + run at NUM_QUEUES=4
NUM_QUEUES ?= 1

# Width of OP_CTRL's per-queue FLUSH keepalive delay counter (DMA_IUVENTUS's/OP_CTRL's
# FLUSH_DELAY_CNTR_WIDTH generic; misc_const.FLUSH_DELAY_CNTR_WIDTH reads this same env var at run
# time -- see cocotb_test.py's flush tests). Defaults to 28, the real production value -- far too
# slow (2**28 cycles) to ever reach in functional simulation. Override to a small value (e.g. 4-6)
# so a FLUSH keepalive test can actually trigger and observe it in a reasonable sim time; NEVER
# change the default itself. Usage:
#   make sim-parallel FLUSH_DELAY_CNTR_WIDTH=6 NUM_QUEUES=4
FLUSH_DELAY_CNTR_WIDTH ?= 28

# QUEUE_DEPTH: NVMe command-tag depth per queue. Overrides the DMA_IUVENTUS generic (default 16)
# so the timing-tuned QD8 multi-queue build can be functionally validated:
#   make sim-parallel NUM_QUEUES=4 QUEUE_DEPTH=8
# misc_const.QUEUE_DEPTH reads this same env var so RTL and model agree.
QUEUE_DEPTH ?= 16

.PHONY: all see-wave clean_shards sim-parallel sim-elab sim-run

all: comp

# Fast-iteration wrappers. The cocotb dir has no Vivado.tcl, so nvc-elab / nvc-run
# need the comp_vivado.tcl SYNTHFILES override (same as sim-parallel). Use for
# editing the Python testbench without re-elaborating the design:
#   make sim-elab                                   # analyze + elaborate once
#   COCOTB_TESTCASE=<name> make sim-run             # run one test (no re-elaborate)
# NVC_ELAB_ARGS is passed as an ENVIRONMENT variable (not a `make VAR=value` command-line
# argument) so build/common.mk's own `NVC_ELAB_ARGS += --no-collapse`/`+= --cover` (DEBUG_ENABLE=
# true / COVERAGE_EN) still APPEND to it instead of being suppressed (a command-line-set make
# variable can't be overridden by a later `+=` in an included makefile without `override`).
sim-elab:
	NVC_ELAB_ARGS="-g NUM_QUEUES=$(NUM_QUEUES) -g FLUSH_DELAY_CNTR_WIDTH=$(FLUSH_DELAY_CNTR_WIDTH) -g QUEUE_DEPTH=$(QUEUE_DEPTH)" $(MAKE) "SYNTHFILES=$(OFM_PATH)/build/targets/comp_vivado.tcl" nvc-elab
sim-run:
	NUM_QUEUES=$(NUM_QUEUES) FLUSH_DELAY_CNTR_WIDTH=$(FLUSH_DELAY_CNTR_WIDTH) QUEUE_DEPTH=$(QUEUE_DEPTH) $(MAKE) "SYNTHFILES=$(OFM_PATH)/build/targets/comp_vivado.tcl" nvc-run

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
#   make sim-parallel                    # all tests in parallel, no waveforms, NUM_QUEUES=1 (~60s)
#   make sim-parallel NUM_QUEUES=4       # elaborate + run at NUM_QUEUES=4 (validates multi-queue)
#   make sim-parallel DEBUG_ENABLE=true  # same, with per-shard .fst waveforms
sim-parallel:
	NVC_ELAB_ARGS="-g NUM_QUEUES=$(NUM_QUEUES) -g FLUSH_DELAY_CNTR_WIDTH=$(FLUSH_DELAY_CNTR_WIDTH) -g QUEUE_DEPTH=$(QUEUE_DEPTH)" $(MAKE) "SYNTHFILES=$(OFM_PATH)/build/targets/comp_vivado.tcl" nvc-elab
	cd $(CURDIR) && DEBUG_ENABLE=$(DEBUG_ENABLE) NUM_QUEUES=$(NUM_QUEUES) FLUSH_DELAY_CNTR_WIDTH=$(FLUSH_DELAY_CNTR_WIDTH) QUEUE_DEPTH=$(QUEUE_DEPTH) pytest -n auto -v test_dma_iuventus.py

include ../../../../build/Makefile
