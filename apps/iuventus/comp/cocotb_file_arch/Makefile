# Makefile: system bench of USER_CORE with the FILE architecture (the file shell)
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

TOP_LEVEL_ENT=USER_CORE

# USER_CORE as the app instantiates it: four queues, two endpoints, one 512 b region.
NVC_ELAB_ARGS += -g NUM_QUEUES=4 -g PCIE_ENDPOINTS=2 -g DMA_STREAMS=2 -g DMA_MFB_REGION_SIZE=1 \
	-g DMA_MFB_BLOCK_SIZE=64

include ../file_shell/cocotb_fs.mk
