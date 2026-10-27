# Makefile: cocotb verification of TX_DMA_PCIE_TRANS_BUFFER
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

# The test-only wrapper turns READ_BARREL_SHIFTER_EN into a mask generic that nvc -g can set.
# TOP_LEVEL_PATH selects this directory's Modules.tcl.
TOP_LEVEL_ENT=TX_DMA_PCIE_TRANS_BUFFER_TB_WRAPPER
TOP_LEVEL_PATH=.
TARGET=cocotb
# The AMD and the Intel implementation are both analysed, so -gDEVICE selects either.
NVC_PLATFORM_TAGS ?= altera xilinx
# The buffer's PSL checks are part of the bench, and an RTL error must fail the run.
NVC_PSL := 1
NVC_EXIT_SEVERITY := error

.PHONY: all sim-elab sim-run

all: comp

# Analysis and elaboration once, then runs on the elaborated design (e.g. one per COCOTB_TEST_MODULES).
sim-elab:
	$(MAKE) TARGET=nvc-elab comp
sim-run:
	$(MAKE) TARGET=nvc-run comp

# make suite: every combination of ver_settings.py in parallel.
SUITE_FILE := test_tx_dma_pcie_trans_buffer.py
SUITE_PREFIX := TRBUF
include ../../../../../../../../build/scripts/multi_ver/nvc_suite.mk

# Without GENERICS, as multi_ver_cocotb.py gives them, a run takes the "default" setting of ver_settings.py.
include ../../../../../../../../build/scripts/multi_ver/ver_settings.mk

include ../../../../../../../../build/Makefile
