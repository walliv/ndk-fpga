# Makefile: bench for FS_OUT_WRITER on its own.
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

TOP_LEVEL_ENT=FS_OUT_WRITER

# A 512-beat staging buffer fills and wraps within a few thousand cycles, so backpressure from it is
# reachable in every test. The shipping build uses 12.
STAGE_LOG2_BEATS ?= 9
FS_GENERICS := STAGE_LOG2_BEATS

include ../cocotb_fs.mk
