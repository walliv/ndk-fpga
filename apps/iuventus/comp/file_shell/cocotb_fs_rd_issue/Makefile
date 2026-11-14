# Makefile: bench for FS_RD_ISSUE and FS_RD_DATA behind the real USER_CORE_IF_PIPE
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

TOP_LEVEL_ENT=FS_RD_TB_TOP

# A small frame-context queue, so the issue window that protects it is reached.
XCTX_ITEMS ?= 32
STAGES ?= 6
FS_GENERICS := XCTX_ITEMS STAGES

include ../cocotb_fs.mk
