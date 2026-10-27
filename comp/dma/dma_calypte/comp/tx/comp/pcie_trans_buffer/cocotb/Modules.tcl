# Modules.tcl: cocotb-only top level, wrapping the real TX_DMA_PCIE_TRANS_BUFFER component
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

# The wrapper is test-only and must stay out of any app build, so it has its own Modules.tcl and
# references the real component as a COMPONENTS entry.
lappend COMPONENTS [list "TX_DMA_PCIE_TRANS_BUFFER" "$OFM_PATH/comp/dma/dma_calypte/comp/tx/comp/pcie_trans_buffer" "FULL"]

lappend MOD "$ENTITY_BASE/tx_dma_pcie_trans_buffer_tb_wrapper.vhd"
