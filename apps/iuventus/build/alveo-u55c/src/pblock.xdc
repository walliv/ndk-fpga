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

create_pblock pblock_wrbuff_drain
add_cells_to_pblock [get_pblocks pblock_wrbuff_drain] [get_cells -quiet [list {core_logic_i/dma_g[0].dma_i/nvme2card_ctrl_i/hbm_stream_writer_i}]]
# X4Y0:X5Y1 follows the WRBUFF HBM ports, which now sit under X4Y0. The previous X5Y0:X6Y1 box ran
# at 90-98% SLICE occupancy in every one of its four regions, and being IS_SOFT 0 it left the
# placer no way out; X4Y0/X4Y1 are the least occupied regions inside the enclosing DMA pblock.
resize_pblock [get_pblocks pblock_wrbuff_drain] -add {CLOCKREGION_X4Y0:CLOCKREGION_X5Y1}
#set_property CONTAIN_ROUTING 1 [get_pblocks pblock_wrbuff_drain]
set_property IS_SOFT 0 [get_pblocks pblock_wrbuff_drain]


create_pblock pblock_user_core
# Everything the selected USER_CORE architecture builds, except its interface pipeline. Naming the
# direct children rather than user_core_i itself is what catches each architecture's MI register
# file, which is synthesised at the architecture level and has no instance name of its own to list.
# The filter covers both architectures: GROUPBY names its pipeline if_pipe_i and TEST names it
# user_core_if_pipe_i, so matching the shared substring excludes whichever one is built.
add_cells_to_pblock [get_pblocks pblock_user_core] [get_cells -filter {NAME !~ "*if_pipe_i*"} core_logic_i/user_core_i/*]
# The user core has no reason to sit next to the DMA and every reason not to: SLR0's left half is
# empty while X4-X7 hold the DMA and PCIe. The pipeline stays out so the placer can spread its
# register stages, data and reset alike, across the gap.
resize_pblock [get_pblocks pblock_user_core] -add {CLOCKREGION_X0Y0:CLOCKREGION_X3Y3}
set_property IS_SOFT 0 [get_pblocks pblock_user_core]
