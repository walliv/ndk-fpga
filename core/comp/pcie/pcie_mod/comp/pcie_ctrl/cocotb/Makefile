# Makefile: cocotb bench of the CQ routing in PCIE_CTRL
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

TOP_LEVEL_ENT=PCIE_CTRL_CQ_TB
TOP_LEVEL_PATH=.
TARGET=cocotb

.PHONY: all
all: comp

# make suite: every combination of ver_settings.py times every cocotb test, in parallel nvc runs.
include ../../../../../../../build/scripts/multi_ver/nvc_suite.mk

include ../../../../../../../build/Makefile
