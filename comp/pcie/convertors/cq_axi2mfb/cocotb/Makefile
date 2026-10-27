# Makefile: cocotb bench of PCIE_CQ_AXI2MFB
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

TOP_LEVEL_ENT=CQ_AXI2MFB_TB
TOP_LEVEL_PATH=.
TARGET=cocotb

.PHONY: all
all: comp

# make suite: every combination of ver_settings.py times every cocotb test, in parallel nvc runs.
include ../../../../../build/scripts/multi_ver/nvc_suite.mk

# Without GENERICS, as multi_ver_cocotb.py gives them, a run takes the "default" setting of ver_settings.py.
include ../../../../../build/scripts/multi_ver/ver_settings.mk

include ../../../../../build/Makefile
