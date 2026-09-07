# Makefile: agent self-test harness built on a wired-through MFB_PIPE
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

TOP_LEVEL_ENT=mfb_pipe
TARGET=nvc-sim

# FAKE_PIPE makes PIPE a combinational wire in both directions (pipe_arch.vhd:227-231), so TX
# carries exactly what the driver put on RX. Anything this bench catches is the cocotb agent's,
# not the DUT's.
REGIONS     ?= 1
REGION_SIZE ?= 8
BLOCK_SIZE  ?= 8
ITEM_WIDTH  ?= 8
NVC_ELAB_ARGS += -g REGIONS=$(REGIONS) -g REGION_SIZE=$(REGION_SIZE) -g BLOCK_SIZE=$(BLOCK_SIZE) \
                 -g ITEM_WIDTH=$(ITEM_WIDTH) -g META_WIDTH=8 -g FAKE_PIPE=true
NVC_RUN_ENV   += REGIONS=$(REGIONS) REGION_SIZE=$(REGION_SIZE) BLOCK_SIZE=$(BLOCK_SIZE) ITEM_WIDTH=$(ITEM_WIDTH)

.PHONY: all
all: comp

include ../../../../../build/Makefile
