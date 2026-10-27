# Makefile: cocotb verification of DMA_CALYPTE (RX and TX together)
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

# The test-only wrapper merges the user MFB metadata fields into one META port per stream, so the
# cocotbext MFB driver and monitor bind by prefix. TOP_LEVEL_PATH selects this directory's Modules.tcl.
TOP_LEVEL_ENT=DMA_CALYPTE_TB_WRAPPER
TOP_LEVEL_PATH=.
TARGET=cocotb
# One analysis serves the AMD and the Intel configurations; the Intel memories need the Quartus
# simulation libraries in nvc (nvc --install quartus).
NVC_PLATFORM_TAGS := altera xilinx
# The RTL's PSL checks are part of the bench, and an RTL error must fail the shard.
NVC_PSL := 1
NVC_EXIT_SEVERITY := error

CONFIG ?= default
SUITE_FILE := test_dma_calypte.py
SUITE_PREFIX := CALYPTE

.PHONY: all sim-analyse sim-elab sim-run

all: comp

include ../../../../build/scripts/multi_ver/nvc_suite.mk

sim-analyse: suite-analyse

sim-elab:
	$(SUITE_ENV) $(PYTHON) test_dma_calypte.py --elab $(CONFIG)

sim-run: suite-run

# Without GENERICS, as multi_ver_cocotb.py gives them, a run takes the "default" setting of ver_settings.py.
include ../../../../build/scripts/multi_ver/ver_settings.mk

include ../../../../build/Makefile
