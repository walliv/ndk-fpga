# Makefile: bench for FS_IN_PLANNER on its own
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

TOP_LEVEL_ENT=FS_IN_PLANNER

# Two completion lanes, as with two endpoints; a stream index other than 0 shows in every context.
STREAM_IDX ?= 5
CDONE_LANES ?= 2
FS_GENERICS := STREAM_IDX CDONE_LANES

include ../cocotb_fs.mk
