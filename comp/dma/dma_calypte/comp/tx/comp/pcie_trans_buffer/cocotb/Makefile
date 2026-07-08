# Makefile: Makefile to compile module
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

TOP_LEVEL_ENT=TX_DMA_PCIE_TRANS_BUFFER
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

WAVEFORM_FILE=tx_dma_pcie_trans_buffer.fst

# Waveform dumping is off by default for speed; set DEBUG_ENABLE=true to enable.
DEBUG_ENABLE ?= false

.PHONY: all see-wave sim-elab sim-run

all: comp

# Fast-iteration wrappers. The cocotb dir has no Vivado.tcl, so nvc-elab /
# nvc-run (invoked directly, bypassing 'comp') need the comp_vivado.tcl
# SYNTHFILES override explicitly (the 'comp' target gets it automatically
# via TARGET=nvc-sim, see build/Makefile.Vivado.inc).
sim-elab:
	$(MAKE) "SYNTHFILES=$(OFM_PATH)/build/targets/comp_vivado.tcl" nvc-elab
sim-run:
	$(MAKE) "SYNTHFILES=$(OFM_PATH)/build/targets/comp_vivado.tcl" nvc-run

$(WAVEFORM_FILE): all

see-wave: $(WAVEFORM_FILE)
	surfer $< -s waveform.su &

include ../../../../../../../../build/Makefile
