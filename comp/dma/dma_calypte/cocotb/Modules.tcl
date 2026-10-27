# Modules.tcl: cocotb-only top level, wrapping the real DMA_CALYPTE component
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

# DMA_CALYPTE_TB_WRAPPER is test-only and must stay out of any app build, so it has its own
# Modules.tcl and references the real component as a COMPONENTS entry.
lappend COMPONENTS [list "DMA_CALYPTE" "$OFM_PATH/comp/dma/dma_calypte" "FULL"]

lappend MOD "$ENTITY_BASE/dma_calypte_tb_wrapper.vhd"
