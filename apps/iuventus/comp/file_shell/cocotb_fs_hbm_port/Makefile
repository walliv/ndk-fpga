# Makefile: bench for FS_HBM_PORT on its own
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

TOP_LEVEL_ENT=FS_HBM_PORT

# Two rings per stream, eight streams: the shipping value.
FETCHERS ?= 16
FS_GENERICS := FETCHERS

include ../cocotb_fs.mk
