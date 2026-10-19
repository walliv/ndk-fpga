# Makefile: cocotb bench of PCIE_RQ_MFB2AXI on the straddled 1024-bit Versal CPM5 RQ interface
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

TOP_LEVEL_ENT=RQ_MFB2AXI_TB
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

# TX_COND is an elaboration generic: sim-conv checks the converter alone with contract-compliant input,
# sim-cond puts PCIE_CPM5_TX_COND in front (as PCIE_ADAPTER does) and drives any legal MFB.
.PHONY: all sim-conv sim-cond
all: sim-conv sim-cond

sim-conv:
	NVC_ELAB_ARGS="-gTX_COND=false" COCOTB_TEST_FILTER="rq_random|rq_short_tlps|rq_region_gaps" $(MAKE) comp

sim-cond:
	NVC_ELAB_ARGS="-gTX_COND=true" COCOTB_TEST_FILTER="rq_gappy" $(MAKE) comp

include ../../../../../build/Makefile
