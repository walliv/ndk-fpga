# Makefile: bench for FS_RING_FETCH on its own
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

TOP_LEVEL_ENT=FS_RING_FETCH

# A 512-entry ring at a nonzero base wraps a few times per test; the shipping rings are 2**14/2**16.
LOG2_DEPTH ?= 9
RING_BASE ?= 12288
FIFO_ENTRIES ?= 64
FS_GENERICS := LOG2_DEPTH RING_BASE FIFO_ENTRIES

include ../cocotb_fs.mk
