# Makefile: bench for IUVENTUS_GROUPBY_ENGINE on its own.
# Copyright 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

TOP_LEVEL_ENT=IUVENTUS_GROUPBY_ENGINE
TOP_LEVEL_PATH=.
TARGET=nvc-sim
NVC_PLATFORM_TAGS := xilinx

# A 128-slot table keeps a full clear plus a full result sweep inside a few thousand cycles, so a
# test can run the engine end to end. The shipping build uses 4096.
SLOTS ?= 128
NVC_ELAB_ARGS += -g SLOTS=$(SLOTS)

# Two sectors per read command, so an input of a few sectors becomes several commands and the
# round-robin, the completion count and the mid-run abort are all reachable. Shipping value: 255.
RD_LBA_NUM ?= 1
NVC_ELAB_ARGS += -g RD_LBA_NUM=$(RD_LBA_NUM)
# The bench derives the table geometry from the same value, so it must reach Python too.
export SLOTS RD_LBA_NUM

.PHONY: all
all: comp

include ../../../../../build/Makefile
