# pblock.xdc
# Copyright 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

create_pblock pblock_pcie_i
add_cells_to_pblock [get_pblocks pblock_pcie_i] [get_cells -quiet [list core_logic_i/pcie_i]]
resize_pblock [get_pblocks pblock_pcie_i] -add {CLOCKREGION_X7Y1:CLOCKREGION_X7Y3}
set_property IS_SOFT FALSE [get_pblocks pblock_pcie_i]

create_pblock pblock_1
add_cells_to_pblock [get_pblocks pblock_1] [get_cells -quiet [list {core_logic_i/dma_g[0].dma_i}]]
resize_pblock [get_pblocks pblock_1] -add {CLOCKREGION_X4Y0:CLOCKREGION_X6Y3}

create_pblock pblock_data_logger_i
add_cells_to_pblock [get_pblocks pblock_data_logger_i] [get_cells -quiet [list core_logic_i/user_core_i/data_logger_i core_logic_i/user_core_i/iops_cntr_i core_logic_i/user_core_i/latency_meter_i core_logic_i/user_core_i/lfsr_rand_addr_gen_i core_logic_i/user_core_i/mfb_generator_i core_logic_i/user_core_i/mfb_reconfigurator_i core_logic_i/user_core_i/rd_mfb_speed_meter_i core_logic_i/user_core_i/wr_mfb_speed_meter_i]]
resize_pblock [get_pblocks pblock_data_logger_i] -add {CLOCKREGION_X4Y0:CLOCKREGION_X4Y3}