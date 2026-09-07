# Makefile: Makefile to compile module
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

TOP_LEVEL_ENT=USER_CORE
# Modules.tcl lives here, not one level up: see its header for why USER_CORE gets a bespoke,
# component-scoped source list instead of ../Modules.tcl, which builds the whole app (PCIe core,
# DMA_IUVENTUS, boot/SDM/HWID).
TOP_LEVEL_PATH=.
TARGET=nvc-sim
NVC_PLATFORM_TAGS := xilinx

# nvc needs libpython to load the cocotb VHPI bridge (see comp/dma/dma_iuventus/cocotb/Makefile
# for the same trick).
PYTHON_LIBDIR := $(shell python3 -c 'import sysconfig; print(sysconfig.get_config_var("LIBDIR"))' 2>/dev/null)
ifneq ($(PYTHON_LIBDIR),)
NVC_RUN_ENV := LD_LIBRARY_PATH=$(PYTHON_LIBDIR):$$LD_LIBRARY_PATH
endif

# NUM_QUEUES: USER_CORE's own generic (round-robin QID width across DMA queues). No QUEUE_DEPTH
# generic exists on USER_CORE (that belongs to DMA_IUVENTUS) so it is not exposed here.
NUM_QUEUES ?= 1

WAVEFORM_FILE=user_core.fst
DEBUG_ENABLE ?= false

# Where the component-level DevTree.dtb is written, and where cocotbext.nfb reads it back at run
# time. The generic nvc build path does not export NETCOPE_TEMP the way the vendor targets do, so
# this component sets it directly.
NETCOPE_TEMP ?= $(CURDIR)/netcope_tmp/
export NETCOPE_TEMP

.PHONY: all devtree test clean_devtree

all: test

# Regenerate the component DevTree.dtb before elaborating/running -- the generic nvc target
# (build/common.mk) analyzes+elaborates+runs in a single recipe, so this must run first.
devtree:
	mkdir -p $(NETCOPE_TEMP)
	tclsh gen_devtree.tcl $(NETCOPE_TEMP)DevTree.dtb

# NUM_QUEUES goes in as both an elaboration generic and an env var, so the Python side knows
# which value the design was built with and can predict the round-robin QID pattern.
test: devtree
	NUM_QUEUES=$(NUM_QUEUES) NVC_ELAB_ARGS="-g NUM_QUEUES=$(NUM_QUEUES)" $(MAKE) "SYNTHFILES=$(OFM_PATH)/build/targets/comp_vivado.tcl" nvc-sim

$(WAVEFORM_FILE): all

see-wave: $(WAVEFORM_FILE)
	surfer $< -s waveform.su &

clean_devtree:
	$(RM) -r $(NETCOPE_TEMP)

CLEAN_DEPENDS += clean_devtree

include ../../../../build/Makefile
