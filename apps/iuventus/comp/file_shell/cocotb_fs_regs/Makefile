# Makefile: bench for FS_REGS on its own
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

TOP_LEVEL_ENT=FS_REGS

# Eight streams ship; fewer exercise the unmapped stream blocks.
STREAMS ?= 8
FS_GENERICS := STREAMS

include ../cocotb_fs.mk
