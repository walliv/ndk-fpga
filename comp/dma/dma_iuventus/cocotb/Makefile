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

.PHONY: all see-wave

all: comp

$(WAVEFORM_FILE): all

see-wave: $(WAVEFORM_FILE)
	surfer $< -s waveform.su &

include ../../../../build/Makefile
