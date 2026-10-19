# Makefile: cocotb bench of PCIE_CQ_AXI2MFB on the straddled 1024-bit Versal CPM5 CQ interface
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

TOP_LEVEL_ENT=CQ_AXI2MFB_TB
TOP_LEVEL_PATH=.
TARGET=nvc-sim
NVC_PLATFORM_TAGS := xilinx

# nvc needs libpython to load the cocotb VHPI bridge, only for its run step.
PYTHON_LIBDIR := $(shell python3 -c 'import sysconfig; print(sysconfig.get_config_var("LIBDIR"))' 2>/dev/null)
ifneq ($(PYTHON_LIBDIR),)
NVC_RUN_ENV := LD_LIBRARY_PATH=$(PYTHON_LIBDIR):$$LD_LIBRARY_PATH
endif

# Stimulus size, read by cocotb_test.py
CPM5_TLPS ?= 4000
NVC_RUN_ENV += CPM5_TLPS=$(CPM5_TLPS)

.PHONY: all
all: comp

include ../../../../../build/Makefile
