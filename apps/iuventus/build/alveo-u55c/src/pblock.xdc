# pblock.xdc
# Copyright 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

create_pblock pblock_pcie_i
add_cells_to_pblock [get_pblocks pblock_pcie_i] [get_cells -quiet [list core_logic_i/pcie_i]]
resize_pblock [get_pblocks pblock_pcie_i] -add {CLOCKREGION_X7Y0:CLOCKREGION_X7Y3}
set_property IS_SOFT 0 [get_pblocks pblock_pcie_i]

# The DMA is left to the placer: none of its old pblocks matched a cell since it moved under
# core_logic's dma_g generate, and the builds that closed timing ran with it unconstrained.

create_pblock pblock_user_core
# Everything the selected USER_CORE architecture builds, except its interface pipeline. Naming the
# direct children rather than user_core_i itself is what catches each architecture's MI register
# file, which is synthesised at the architecture level and has no instance name of its own to list.
# The filter covers both architectures: GROUPBY names its pipeline if_pipe_i and TEST names it
# user_core_if_pipe_i, so matching the shared substring excludes whichever one is built.
add_cells_to_pblock [get_pblocks pblock_user_core] [get_cells -filter {NAME !~ "*if_pipe_i*"} core_logic_i/user_core_i/*]
# The user core keeps three columns to itself: its integrity checker's CARRY8 chains routed at 7 ns
# when boxed into one clock region beside the allocators.
# The pipeline stays out so the placer can spread its register stages, data and reset alike, across
# the gap.
resize_pblock [get_pblocks pblock_user_core] -add {CLOCKREGION_X0Y0:CLOCKREGION_X2Y3}
set_property IS_SOFT 0 [get_pblocks pblock_user_core]
