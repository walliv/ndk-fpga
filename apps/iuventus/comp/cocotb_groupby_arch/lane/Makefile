# Makefile: bench for IUVENTUS_GROUPBY_LANE on its own.
# Copyright 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

TOP_LEVEL_ENT=IUVENTUS_GROUPBY_LANE
TOP_LEVEL_PATH=.
TARGET=nvc-sim
NVC_PLATFORM_TAGS := xilinx
# The nvc flow makes the PSL checks and the abort on an error opt-in; these benches rely on both.
NVC_PSL ?= 1
NVC_EXIT_SEVERITY ?= error

.PHONY: all
all: comp

include ../../../../../build/Makefile
