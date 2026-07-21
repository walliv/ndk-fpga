# Makefile: Makefile to compile module
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

TOP_LEVEL_ENT=USER_CORE
# Modules.tcl lives right here (not one level up, unlike the default) -- see Modules.tcl's own
# header for why USER_CORE is elaborated with a bespoke, component-scoped source list instead of
# reusing ../Modules.tcl (which builds the WHOLE app: PCIe core, DMA_IUVENTUS, boot/SDM/HWID...).
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

# NETCOPE_TEMP: where the component-level DevTree.dtb (see gen_devtree.tcl) is written; read by
# cocotbext.nfb.NfbDevice.read_dtb() at cocotb-test run time (os.environ["NETCOPE_TEMP"] +
# "DevTree.dtb"). The generic nvc build path in build/common.mk does not export NETCOPE_TEMP for
# us (unlike the Vivado/Quartus/Synplify targets), so this component owns it directly.
NETCOPE_TEMP ?= $(CURDIR)/netcope_tmp/
export NETCOPE_TEMP

.PHONY: all devtree test clean_devtree

all: test

# Regenerate the component DevTree.dtb before elaborating/running -- the generic nvc target
# (build/common.mk) analyzes+elaborates+runs in a single recipe, so this must run first.
devtree:
	mkdir -p $(NETCOPE_TEMP)
	tclsh gen_devtree.tcl $(NETCOPE_TEMP)DevTree.dtb

# test: elaborate + run the cocotb smoke test(s) (test_dma_iuventus.py's sibling here is
# cocotb_test.py). Mirrors comp/dma/dma_iuventus/cocotb/Makefile's sim-elab/sim-run split, but
# collapsed into one step since Stage 1 only needs a single smoke test, not a parallel gate.
# NUM_QUEUES is passed BOTH as an elaboration generic (-g) AND as a plain env var so the cocotb
# Python side (see cocotb_test.py's os.environ["NUM_QUEUES"] read) knows which NUM_QUEUES the
# elaborated design actually used, to predict the matching round-robin QID pattern.
test: devtree
	NUM_QUEUES=$(NUM_QUEUES) NVC_ELAB_ARGS="-g NUM_QUEUES=$(NUM_QUEUES)" $(MAKE) "SYNTHFILES=$(OFM_PATH)/build/targets/comp_vivado.tcl" nvc-sim

$(WAVEFORM_FILE): all

see-wave: $(WAVEFORM_FILE)
	surfer $< -s waveform.su &

clean_devtree:
	$(RM) -r $(NETCOPE_TEMP)

CLEAN_DEPENDS += clean_devtree

include ../../../../build/Makefile
