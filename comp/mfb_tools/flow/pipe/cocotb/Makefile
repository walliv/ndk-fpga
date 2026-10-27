# Makefile: Makefile to compile module
# Copyright (C) 2024 CESNET z. s. p. o.
# Author(s): David Beneš <xbenes52@vutbr.cz>
#
# SPDX-License-Identifier: BSD-3-Clause

TOP_LEVEL_ENT=mfb_pipe
TARGET=cocotb

# make LOOPBACK=1: the fast MFB driver/monitor self-test on a wired-through MFB_PIPE (nvc)
ifeq ($(LOOPBACK),1)
TARGET=nvc-sim
COCOTB_TEST_MODULES=cocotb_loopback_test
# FAKE_PIPE makes PIPE a combinational wire in both directions, so TX carries exactly what the driver
# put on RX. Anything this bench catches belongs to the cocotb drivers and monitors, not to the DUT.
REGIONS     ?= 1
REGION_SIZE ?= 8
BLOCK_SIZE  ?= 8
ITEM_WIDTH  ?= 8
NVC_ELAB_ARGS += -g REGIONS=$(REGIONS) -g REGION_SIZE=$(REGION_SIZE) -g BLOCK_SIZE=$(BLOCK_SIZE) \
	-g ITEM_WIDTH=$(ITEM_WIDTH) -g META_WIDTH=8 -g FAKE_PIPE=true
NVC_RUN_ENV   += REGIONS=$(REGIONS) REGION_SIZE=$(REGION_SIZE) BLOCK_SIZE=$(BLOCK_SIZE) ITEM_WIDTH=$(ITEM_WIDTH)
endif

.PHONY: all
all: comp

include ../../../../../build/Makefile
