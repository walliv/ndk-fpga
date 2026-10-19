# Makefile: cocotb verification of PCIE_BAR2AXI on nvc
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

TOP_LEVEL_ENT=PCIE_BAR2AXI
TARGET=nvc-sim
NVC_PLATFORM_TAGS := xilinx

# nvc needs libpython to load the cocotb VHPI bridge; its dir goes on LD_LIBRARY_PATH only for the
# nvc run step so it does not shadow system libs for tclsh.
PYTHON_LIBDIR := $(shell python3 -c 'import sysconfig; print(sysconfig.get_config_var("LIBDIR"))' 2>/dev/null)
ifneq ($(PYTHON_LIBDIR),)
NVC_RUN_ENV := LD_LIBRARY_PATH=$(PYTHON_LIBDIR):$$LD_LIBRARY_PATH
endif

# DUT configuration: elaborated into the RTL and exported to the testbench, so both always agree.
MFB_REGIONS    ?= 2
AXI_DATA_WIDTH ?= 512
DEVICE         ?= ULTRASCALE
BAR_ID         ?= 0
FUNC_ID        ?= 1
BAR_APERTURE   ?= 30
RD_OUTSTANDING ?= 8
MAX_WR_BYTES   ?= 1024
MAX_RD_BYTES   ?= 4096

NVC_ELAB_ARGS += -gMFB_REGIONS=$(MFB_REGIONS)
NVC_ELAB_ARGS += -gAXI_DATA_WIDTH=$(AXI_DATA_WIDTH)
NVC_ELAB_ARGS += -gDEVICE=$(DEVICE)
NVC_ELAB_ARGS += -gBAR_ID=$(BAR_ID)
NVC_ELAB_ARGS += -gFUNC_ID=$(FUNC_ID)
NVC_ELAB_ARGS += -gBAR_APERTURE=$(BAR_APERTURE)
NVC_ELAB_ARGS += -gRD_OUTSTANDING=$(RD_OUTSTANDING)
NVC_ELAB_ARGS += -gMAX_WR_BYTES=$(MAX_WR_BYTES)
NVC_ELAB_ARGS += -gMAX_RD_BYTES=$(MAX_RD_BYTES)

export TB_BAR_ID=$(BAR_ID)
export TB_FUNC_ID=$(FUNC_ID)
export TB_BAR_APERTURE=$(BAR_APERTURE)
export TB_RD_OUTSTANDING=$(RD_OUTSTANDING)
export TB_MAX_WR_BYTES=$(MAX_WR_BYTES)
export TB_MAX_RD_BYTES=$(MAX_RD_BYTES)

.PHONY: all configs

all: comp

# The four required configurations, one simulation each; results land in results_<cfg>.xml.
configs:
	./run_configs.sh

include ../../../../build/Makefile
