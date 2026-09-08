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
add_cells_to_pblock [get_pblocks pblock_dma] [get_cells -quiet [list {core_logic_i/dma_i/card2nvme_ctrl_i} {core_logic_i/dma_i/nvme2card_ctrl_i}]]
# Four columns: both endpoints' datapaths and responders put 160 block-RAM tiles in the DMA, and
# X4-X6 alone holds 164, which pushed the completion buffer's BRAMs out of reach of CQE_PROCESSOR.
resize_pblock [get_pblocks pblock_dma] -add {CLOCKREGION_X4Y0:CLOCKREGION_X6Y3 CLOCKREGION_X3Y0:CLOCKREGION_X3Y0 CLOCKREGION_X3Y3:CLOCKREGION_X3Y3}
set_property IS_SOFT 0 [get_pblocks pblock_dma]

create_pblock pblock_wrbuff_drain
add_cells_to_pblock [get_pblocks pblock_wrbuff_drain] [get_cells -quiet [list {core_logic_i/dma_i/nvme2card_ctrl_i/ep_g[0].ep_datapath_i/hbm_stream_writer_i}]]
# X4Y0:X5Y1 follows the WRBUFF HBM ports, which now sit under X4Y0. The previous X5Y0:X6Y1 box ran
# at 90-98% SLICE occupancy in every one of its four regions, and being IS_SOFT 0 it left the
# placer no way out; X4Y0/X4Y1 are the least occupied regions inside the enclosing DMA pblock.
resize_pblock [get_pblocks pblock_wrbuff_drain] -add {CLOCKREGION_X4Y0:CLOCKREGION_X5Y1}
#set_property CONTAIN_ROUTING 1 [get_pblocks pblock_wrbuff_drain]
set_property IS_SOFT 0 [get_pblocks pblock_wrbuff_drain]

create_pblock pblock_ep1_wrbuff_drain
add_cells_to_pblock [get_pblocks pblock_ep1_wrbuff_drain] [get_cells -quiet [list {core_logic_i/dma_i/nvme2card_ctrl_i/ep_g[1].ep_datapath_i/hbm_stream_writer_i}]]
# Endpoint 1 fills WRBUFF through HBM ports 24 and 25, which sit under X6Y0.
resize_pblock [get_pblocks pblock_ep1_wrbuff_drain] -add {CLOCKREGION_X6Y0:CLOCKREGION_X6Y1}
set_property IS_SOFT 0 [get_pblocks pblock_ep1_wrbuff_drain]

create_pblock pblock_opctrl
add_cells_to_pblock [get_pblocks pblock_opctrl] [get_cells -quiet [list {core_logic_i/dma_i/operation_control_i}]]
# OP_CTRL and its four page allocators (33k LUTs) take a wide, two-row band between the USER_CORE
# interface pipes and the DMA. A tall two-column band put the allocators' comparator arrays four
# regions apart: 5 ns of routing on a 4 ns clock.
resize_pblock [get_pblocks pblock_opctrl] -add {CLOCKREGION_X0Y1:CLOCKREGION_X3Y2}
set_property IS_SOFT 0 [get_pblocks pblock_opctrl]

# One column per allocator: each first-fit search fans a request out to every page slot, so the
# array must stay compact, and four interleaved arrays are what the placer produces otherwise.
foreach {alloc col} {rd_alloc_g[0].rd_alloc_i X0 rd_alloc_g[1].rd_alloc_i X1 wr_alloc_g[0].wr_alloc_i X2 wr_alloc_g[1].wr_alloc_i X3} {
    set pb pblock_${col}_[string map {[ _ ] _ . _} $alloc]
    create_pblock $pb
    add_cells_to_pblock [get_pblocks $pb] [get_cells -quiet "core_logic_i/dma_i/operation_control_i/$alloc"]
    resize_pblock [get_pblocks $pb] -add "CLOCKREGION_${col}Y1:CLOCKREGION_${col}Y2"
    set_property IS_SOFT 0 [get_pblocks $pb]
}


create_pblock pblock_user_core
# Everything the selected USER_CORE architecture builds, except its interface pipeline. Naming the
# direct children rather than user_core_i itself is what catches each architecture's MI register
# file, which is synthesised at the architecture level and has no instance name of its own to list.
# The filter covers both architectures: GROUPBY names its pipeline if_pipe_i and TEST names it
# user_core_if_pipe_i, so matching the shared substring excludes whichever one is built.
add_cells_to_pblock [get_pblocks pblock_user_core] [get_cells -filter {NAME !~ "*if_pipe_i*"} core_logic_i/user_core_i/*]
# The user core (under 3k LUTs) takes the top-left region; OP_CTRL the X0-X3 middle band, the DMA X4-X6.
# The pipeline stays out so the placer can spread its register stages, data and reset alike, across
# the gap.
resize_pblock [get_pblocks pblock_user_core] -add {CLOCKREGION_X0Y3:CLOCKREGION_X0Y3}
set_property IS_SOFT 0 [get_pblocks pblock_user_core]
