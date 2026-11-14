# Makefile: bench for FS_KERNEL_DIGEST_FILL on its own
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

TOP_LEVEL_ENT=FS_KERNEL_DIGEST_FILL

# One lane per PCIe endpoint; the shipping build has two.
LANES ?= 2
FS_GENERICS := LANES

include ../cocotb_fs.mk
