# Makefile: bench for FS_CTRL on its own
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

TOP_LEVEL_ENT=FS_CTRL

# The defaults are the shipping ones; a short DONE_QUIET or a second endpoint exercise the other corners.
STREAMS ?= 8
NUM_QUEUES ?= 4
PCIE_ENDPOINTS ?= 1
DONE_QUIET ?= 1024
FS_GENERICS := STREAMS NUM_QUEUES PCIE_ENDPOINTS DONE_QUIET

include ../cocotb_fs.mk
