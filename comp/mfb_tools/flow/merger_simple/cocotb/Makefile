# Makefile: cocotb verification of MFB_MERGER_SIMPLE
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

TOP_LEVEL_ENT=MFB_MERGER_SIMPLE
TOP_LEVEL_PATH=..
TARGET=cocotb
# MFB_MERGER_SIMPLE_GEN's input FIFOs are analysed too; the Xilinx memories need no vendor library beyond unisim.
NVC_PLATFORM_TAGS := xilinx
# The merger's PSL checks are part of the bench, and an RTL error must fail the shard.
NVC_PSL := 1
NVC_EXIT_SEVERITY := error

CONFIG ?= default
SUITE_FILE := test_mfb_merger_simple.py
SUITE_PREFIX := MERGER

.PHONY: all sim-analyse sim-run

all: comp

include ../../../../../build/scripts/multi_ver/nvc_suite.mk

sim-analyse: suite-analyse

sim-run: suite-run

# Without GENERICS, as multi_ver_cocotb.py gives them, a run takes the "default" setting of ver_settings.py.
include ../../../../../build/scripts/multi_ver/ver_settings.mk

include ../../../../../build/Makefile
