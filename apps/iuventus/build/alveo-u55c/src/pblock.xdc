# pblock.xdc
# Copyright 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

create_pblock pblock_pcie_i
add_cells_to_pblock [get_pblocks pblock_pcie_i] [get_cells -quiet [list core_logic_i/pcie_i]]
resize_pblock [get_pblocks pblock_pcie_i] -add {CLOCKREGION_X7Y0:CLOCKREGION_X7Y3}
set_property IS_SOFT 0 [get_pblocks pblock_pcie_i]

create_pblock pblock_dma
add_cells_to_pblock [get_pblocks pblock_dma] [get_cells -quiet [list {core_logic_i/dma_g[0].dma_i/card2nvme_ctrl_i} {core_logic_i/dma_g[0].dma_i/nvme2card_ctrl_i}]]
resize_pblock [get_pblocks pblock_dma] -add {CLOCKREGION_X4Y0:CLOCKREGION_X6Y3}
set_property IS_SOFT 0 [get_pblocks pblock_dma]

# Co-locates the WRBUFF drain FIFO with its consumer: that path is route-dominated and closes
# only with both ends in one region. Four regions, not two -- that consumer is ~41k
# cells and two leave it route-bound. Re-measure before shrinking.
create_pblock pblock_wrbuff_drain
add_cells_to_pblock [get_pblocks pblock_wrbuff_drain] [get_cells -quiet [list {core_logic_i/dma_g[0].dma_i/nvme2card_ctrl_i/wrbuff_fifo_i} {core_logic_i/dma_g[0].dma_i/nvme2card_ctrl_i/hbm_stream_writer_i}]]
resize_pblock [get_pblocks pblock_wrbuff_drain] -add {CLOCKREGION_X5Y2:CLOCKREGION_X6Y3}
set_property IS_SOFT 0 [get_pblocks pblock_wrbuff_drain]
