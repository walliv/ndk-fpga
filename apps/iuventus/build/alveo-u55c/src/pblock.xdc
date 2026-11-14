# pblock.xdc
# Copyright 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

create_pblock pblock_pcie_i
add_cells_to_pblock [get_pblocks pblock_pcie_i] [get_cells -quiet [list core_logic_i/pcie_i]]
resize_pblock [get_pblocks pblock_pcie_i] -add {CLOCKREGION_X7Y0:CLOCKREGION_X7Y3}
set_property IS_SOFT 0 [get_pblocks pblock_pcie_i]

# The DMA is left to the placer: the builds that closed timing ran with it unconstrained.

create_pblock pblock_user_core
# Every USER_CORE cell but its interface pipeline. Direct children catch the unnamed MI register
# file; FILE's if_pipe_i sits inside file_shell_i. XDC has no if, so one get_cells over both levels
# keeps the list non-empty in every architecture.
add_cells_to_pblock [get_pblocks pblock_user_core] [get_cells -quiet -filter {NAME !~ "*if_pipe_i*" && NAME != "core_logic_i/user_core_i/file_shell_i"} [list core_logic_i/user_core_i/* core_logic_i/user_core_i/file_shell_i/*]]
# Except the pipeline's engine end: the read credits, the first request stage and the first write
# stage handshake with the engine in the same cycle, so they sit beside it, not out in the gap.
add_cells_to_pblock [get_pblocks pblock_user_core] [get_cells -quiet -hier -filter {NAME =~ "core_logic_i/user_core_i/*if_pipe_i/credit_reg*" || NAME =~ "core_logic_i/user_core_i/*if_pipe_i/req_chain_g?1?.req_*_reg*" || (NAME =~ "core_logic_i/user_core_i/*if_pipe_i/wr_pipe_g?1?.wr_pipe_i/*" && IS_PRIMITIVE)}]
# The user core keeps three columns to itself: its integrity checker's CARRY8 chains routed at 7 ns
# when boxed into one clock region beside the allocators. The pipeline stays out so the placer can
# spread its register stages across the gap.
resize_pblock [get_pblocks pblock_user_core] -add {CLOCKREGION_X0Y0:CLOCKREGION_X2Y3}
set_property IS_SOFT 0 [get_pblocks pblock_user_core]
