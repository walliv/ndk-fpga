# This is an automatically generated file.
# You can regenerate it using "make filelist".

if {![info exists shell_git_root]} {
    error "The shell_git_root variable is undefined! Initialize it in a calling shell."
}

read_xdc ${shell_git_root}/cards/amd/alveo-u55c/constr/pcie_x4.xdc
read_xdc ${shell_git_root}/apps/sparklev/build/alveo-u55c/src/pblock.xdc
read_xdc ${shell_git_root}/apps/sparklev/build/alveo-u55c/src/general.xdc
read_vhdl -library work -vhdl2008 ${shell_git_root}/apps/sparklev/build/alveo-u55c/src/card_top.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/apps/sparklev/comp/core_logic.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/apps/sparklev/comp/user_core_full_arch.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/apps/sparklev/comp/user_core_ent.vhd
set IP_PARAMS_L {IP_COMP_TYPE 0 SDM_SYSMON_ARCH USP_IDCOMP CLOCK_GEN_ARCH USP PCIE_GEN 4 IP_GEN_FILES false PCIE_MOD_ARCH USP_PCIE4C PCIE_ENDPOINT_MODE 3 IP_COMP_NAME axi_quad_spi_0 USE_IP_SUBDIRS true IP_MODIFY_BASE @@SHELL_GIT_ROOT@@/cards/amd/alveo-u55c/src/ip/axi_quad_spi DMA_TYPE 6 CORE_BASE @@SHELL_GIT_ROOT@@/core PCIE_ENDPOINTS 1 IP_BUILD_DIR @@SHELL_GIT_ROOT@@/apps/sparklev/build/alveo-u55c/src USR_CORE_ARCH FULL}
set IP_PARAMS_L [string map [list @@SHELL_GIT_ROOT@@ $shell_git_root] $IP_PARAMS_L]
source ${shell_git_root}/cards/amd/alveo-u55c/src/ip/axi_quad_spi/axi_quad_spi.ip.tcl
set IP_PARAMS_L {IP_COMP_TYPE 0 SDM_SYSMON_ARCH USP_IDCOMP CLOCK_GEN_ARCH USP PCIE_GEN 4 IP_GEN_FILES false PCIE_MOD_ARCH USP_PCIE4C PCIE_ENDPOINT_MODE 3 IP_COMP_NAME hbm_ip USE_IP_SUBDIRS true IP_MODIFY_BASE @@SHELL_GIT_ROOT@@/cards/amd/alveo-u55c/src/ip/hbm_ip DMA_TYPE 6 CORE_BASE @@SHELL_GIT_ROOT@@/core PCIE_ENDPOINTS 1 IP_BUILD_DIR @@SHELL_GIT_ROOT@@/apps/sparklev/build/alveo-u55c/src USR_CORE_ARCH FULL}
set IP_PARAMS_L [string map [list @@SHELL_GIT_ROOT@@ $shell_git_root] $IP_PARAMS_L]
source ${shell_git_root}/cards/amd/alveo-u55c/src/ip/hbm_ip/hbm_ip.ip.tcl
set IP_PARAMS_L {IP_COMP_TYPE 0 SDM_SYSMON_ARCH USP_IDCOMP CLOCK_GEN_ARCH USP PCIE_GEN 4 IP_GEN_FILES false PCIE_MOD_ARCH USP_PCIE4C PCIE_ENDPOINT_MODE 3 IP_COMP_NAME pcie4_uscale_plus USE_IP_SUBDIRS true IP_MODIFY_BASE @@SHELL_GIT_ROOT@@/cards/amd/alveo-u55c/src/ip/pcie4_uscale_plus DMA_TYPE 6 CORE_BASE @@SHELL_GIT_ROOT@@/core PCIE_ENDPOINTS 1 IP_BUILD_DIR @@SHELL_GIT_ROOT@@/apps/sparklev/build/alveo-u55c/src USR_CORE_ARCH FULL}
set IP_PARAMS_L [string map [list @@SHELL_GIT_ROOT@@ $shell_git_root] $IP_PARAMS_L]
source ${shell_git_root}/cards/amd/alveo-u55c/src/ip/pcie4_uscale_plus/pcie4_uscale_plus.ip.tcl
read_vhdl -library work -vhdl2008 ${shell_git_root}/cards/silicom/fb2cghh/src/comp/axi_quad_flash_controller/axi_quad_flash_controller.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/cards/silicom/fb2cghh/src/comp/axi_quad_flash_controller/comp/axi4_lite_mi_bridge/axi4_lite_mi_bridge.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/core/comp/misc/boot_ctrl/boot_ctrl.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/apps/sparklev/comp/comp/dma/dma_hyperion.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/dma/dma_calypte/comp/ptr_updater/dma_ptr_updater.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/dma/dma_calypte/comp/rx/rx_dma_calypte.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/debug/data_logger/data_logger.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/debug/histogramer/histogramer.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/mem/mem_clear/mem_clear.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/mem/dp_bram/dp_bram_behav.vhd
set_property -quiet FILE_TYPE VHDL [get_files dp_bram_behav.vhd]
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/logic/cnt/cnt.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/logic/cnt/cnt_types.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/mfb_tools/logic/frame_lng_check/frame_lng_check.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/mfb_tools/logic/frame_lng/mfb_frame_lng.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/dma/dma_calypte/comp/rx/comp/software_manager/rx_dma_calypte_sw_manager.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/logic/cnt_multi_memx/cnt_multi_memx.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/mem/sdp_memx/sdp_memx.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/dsp/dsp_comparator/dsp_comparator.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/dsp/dsp_comparator_intel/dsp_comparator_intel_empty.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/dsp/dsp_comparator_intel/dsp_comparator_intel_ent.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/logic/cmp/cmp_top.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/logic/cmp/comp/cmp_dsp/cmp_dsp.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/logic/cmp/comp/cmp_dsp/cmp48.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/logic/cmp/comp/cmp_dsp/cmp_decode.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/logic/cmp/comp/cmp_dsp/cmp_dsp_ent.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/dma/dma_calypte/comp/rx/comp/input_buffer/rx_dma_calypte_input_buffer.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/dma/dma_calypte/comp/rx/comp/trans_buffer/rx_dma_calypte_trans_buffer.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/fifo/reg_fifo/reg_fifo.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/dma/dma_calypte/comp/rx/comp/hdr_manager/rx_dma_calypte_hdr_manager.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/fifo/sh_fifo/sh_fifo.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/fifo/sh_fifo/sh_fifo_fsm.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/dma/dma_calypte/comp/rx/comp/hdr_manager/addr_manager/rx_dma_calypte_addr_manager.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/dma/dma_calypte/comp/rx/comp/hdr_insertor/rx_dma_calypte_hdr_insertor.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/pkg/pcie_hdr_fields_pkg.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/apps/sparklev/comp/comp/dma/c2h_hbm_reader/c2h_hbm_reader.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/apps/sparklev/comp/comp/dma/c2h_hbm_reader/c2h_beat_fifo.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/apps/sparklev/comp/comp/dma/h2c_dma_hyperion/h2c_dma_hyperion.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/apps/sparklev/comp/comp/dma/h2c_dma_hyperion/comp/sw_manager/h2c_dma_hyperion_sw_mgr.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/apps/sparklev/comp/comp/dma/h2c_dma_hyperion/comp/sw_manager/stat_cntr.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/apps/sparklev/comp/comp/dma/h2c_dma_hyperion/comp/axi_adapter/h2c_hyperion_axi_adapter.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/apps/sparklev/comp/comp/dma/h2c_dma_hyperion/comp/metadata_extractor/h2c_hyperion_meta_ext.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/apps/sparklev/comp/comp/dma/h2c_dma_hyperion/comp/data_shifter/h2c_hyperion_data_shifter.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/apps/sparklev/comp/comp/dma/h2c_dma_hyperion/pkg/h2c_meta_pkg.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/misc/hwid/hwid_usp.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/misc/hwid/hwid_ent.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/core/comp/misc/sdm_ctrl/sdm_ctrl_usp_idcomp.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/core/comp/misc/sdm_ctrl/sdm_ctrl_ent.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/misc/id32/id_top_virtex7.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/misc/id32/id_comp.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/misc/id32/sysmon_usp.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/misc/id32/sysmon_ent.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/misc/interrupt_manager/interrupt_manager.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/logic/edge_detect/edge_detect.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/mi_tools/test_space/mi_test_space.vhd
read_xdc ${shell_git_root}/comp/base/async/open_loop/open_loop.xdc
set_property SCOPED_TO_REF ASYNC_OPEN_LOOP [get_files open_loop.xdc]
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/async/open_loop/open_loop.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/core/comp/pcie/pcie_mod/pcie_top.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/core/comp/pcie/pcie_mod/comp/pcie_ctrl/pcie_ctrl.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/pcie/ptc/ptc_wrapper.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/pcie/ptc/ptc_full.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/pcie/ptc/ptc_ent.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/mfb_tools/flow/cutter_simple/mfb_cutter_simple.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/pcie/ptc/comp/storage_fifo/ptc_storage_fifo.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/pcie/ptc/comp/frame_eraser_upto96bits/ptc_frame_eraser_upto96bits.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/pcie/ptc/comp/pcie2dma_hdr_transform/ptc_pcie2dma_hdr_transform_full.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/pcie/ptc/comp/pcie2dma_hdr_transform/ptc_pcie2dma_hdr_transform_ent.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/mfb_tools/logic/get_items/mfb_get_items.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/mfb_tools/storage/fifo_bram_xilinx/fifo_bram_xilinx.vhd
read_xdc ${shell_git_root}/comp/base/fifo/fifo_bram_xilinx/fifo_bram_xilinx.xdc
set_property SCOPED_TO_REF FIFO_BRAM_XILINX [get_files fifo_bram_xilinx.xdc]
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/fifo/fifo_bram_xilinx/fifo_bram_xilinx.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/fifo/fifo_bram_xilinx/fifo_bram_xilinx_ent.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/pcie/ptc/comp/tag_manager/ptc_tag_manager.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/logic/n_loop_op/n_loop_op.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/mem/gen_reg_array/gen_reg_array.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/mem/np_lutram/np_lutram.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/pcie/ptc/comp/hdr_data_merge/ptc_hdr_data_merge.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/pcie/ptc/comp/hdr_data_merge/ptc_hdr_data_merge_dins.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/pcie/ptc/comp/hdr_data_merge/ptc_hdr_data_merge_hpai.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/pcie/ptc/comp/codapa_checker/ptc_codapa_checker.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/pcie/ptc/comp/dma2pcie_hdr_transform/ptc_dma2pcie_hdr_transform_full.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/pcie/ptc/comp/dma2pcie_hdr_transform/ptc_dma2pcie_hdr_transform_ent.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/logic/pipe_tree_adder/pipe_tree_adder.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/pcie/ptc/comp/mfb_asfifo_256to512/mfb_asfifo_256to512.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/pcie/ptc/comp/mfb_asfifo_512to256/mfb_asfifo_512to256.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/mfb_tools/flow/splitter/mfb_splitter_gen.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/mfb_tools/flow/splitter/mfb_splitter.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/mfb_tools/flow/merger/mfb_merger_gen.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/mfb_tools/flow/merger/mfb_merger_full.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/mfb_tools/flow/merger/mfb_merger_old.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/mfb_tools/flow/merger/mfb_merger_ent.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/mvb_tools/flow/merge_streams/merge_streams.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/mfb_tools/logic/auxiliary_signals/mfb_auxiliary_signals.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/logic/bin2hot/bin2hot.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/mfb_tools/storage/asfifox/mfb_asfifox.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/mvb_tools/storage/asfifox/mvb_asfifox.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/mvb_tools/storage/fifox/mvb_fifox.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/pcie/mtc/mtc_wrapper.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/pcie/mtc/mtc.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/pcie/logic/bar_addr_translator/bar_addr_translator.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/pcie/logic/byte_count/byte_count.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/pcie/others/hdr_gen/rc_hdr_deparser/rc_hdr_deparser.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/pcie/others/hdr_gen/cq_hdr_deparser/cq_hdr_deparser.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/pcie/others/hdr_gen/cc_hdr_gen/cc_hdr_gen.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/pcie/others/hdr_gen/rq_hdr_gen/rq_hdr_gen.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/mfb_tools/flow/transformer/transformer.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/mfb_tools/flow/transformer/transformer_up.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/mfb_tools/flow/transformer/transformer_down.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/core/comp/pcie/pcie_mod/comp/pcie_core/pcie_core_usp.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/core/comp/pcie/pcie_mod/comp/pcie_core/pcie_core_ent.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/core/comp/pcie/pcie_mod/comp/pcie_core/pcie_core_debug.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/mi_tools/async/mi_async.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/fifo/asfifox/asfifox.vhd
read_xdc ${shell_git_root}/comp/base/async/open_loop_smd/open_loop_smd.xdc
set_property SCOPED_TO_REF ASYNC_OPEN_LOOP_SMD [get_files open_loop_smd.xdc]
set_property PROCESSING_ORDER LATE [get_files open_loop_smd.xdc]
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/async/open_loop_smd/open_loop_smd.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/mi_tools/splitter_plus_gen/ver/mi_splitter_plus_gen_wrapper.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/mi_tools/splitter_plus_gen/mi_splitter_plus_gen.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/mi_tools/pipe/mi_pipe_arch.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/mi_tools/pipe/mi_pipe.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/mi_tools/splitter_plus_gen/ab_init_pack.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/ver/vhdl_ver_tools/basics/basics_test_pkg.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/misc/event_counter/event_counter_mi_wrapper.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/misc/event_counter/event_counter.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/debug/streaming_debug/streaming_debug_master.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/logic/dec1fn/dec1fn2b.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/logic/dec1fn/dec1fn_enable.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/logic/dec1fn/dec1fn.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/core/comp/pcie/pcie_mod/comp/pcie_adapter/pcie_adapter.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/pcie/ptc/comp/mfb2pcie_axi/ptc_mfb2pcie_axi.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/pcie/ptc/comp/pcie_axi2mfb/ptc_pcie_axi2mfb.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/pcie/convertors/cc_mfb2axi/pcie_mfb2axi.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/pcie/convertors/cq_axi2mfb/pcie_axi2mfb.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/pkg/pcie_axi_meta_pack.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/pcie/others/connection_block/connection_block.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/pcie/others/connection_block/crdt_down.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/pcie/others/connection_block/crdt_up.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/mfb_tools/storage/fifox/mfb_fifox.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/mfb_tools/flow/splitter_simple/mfb_splitter_simple_gen.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/mfb_tools/flow/splitter_simple/mfb_splitter_simple.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/mfb_tools/flow/merger_simple/mfb_merger_simple_gen.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/mfb_tools/flow/merger_simple/mfb_merger_simple.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/pcie/others/axicc2mfb/pcie_axicc2mfb.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/mfb_tools/flow/pipe/mfb_pipe.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/pcie/others/mfb2axicq/pcie_mfb2axicq.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/fifo/fifox_multi/fifox_multi.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/fifo/fifox_multi/comp/fifox_multi_gen/fifox_multi_full.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/fifo/fifox_multi/comp/fifox_multi_gen/fifox_multi_shakedown.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/fifo/fifox_multi/comp/fifox_multi_gen/fifox_multi_ent.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/mvb_tools/flow/shakedown/mvb_shakedown.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/mvb_tools/flow/pipe/mvb_pipe.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/mvb_tools/flow/split/split.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/logic/demux/demux.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/logic/sum_one/sum_one.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/logic/first_one/first_one.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/mvb_tools/flow/merge_n_to_m/shakedown.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/mvb_tools/flow/merge_n_to_m/merge_n_to_m.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/mvb_tools/flow/merge_n_to_m/merge_n_to_m_ent.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/misc/pipe/pipe_deeper_arch.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/misc/pipe/pipe_deeper.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/misc/pipe/pipe_arch.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/misc/pipe/pipe.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/misc/pipe/pipe_reg.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/debug/streaming_debug/streaming_debug_probe_mfb.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/debug/streaming_debug/streaming_debug_probe_n.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/debug/streaming_debug/streaming_debug_probe.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/logic/n_one/n_one.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/logic/n_one/n_one_logic.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/logic/n_one/n_one_core.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/logic/n_one/n_one_ent.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/logic/barrel_shifter/barrel_shifter_gen_piped.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/logic/barrel_shifter/barrel_shifter.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/logic/barrel_shifter/barrel_shifter_gen.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/logic/mux/mux_piped.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/logic/mux/mux_onehot.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/logic/mux/mux.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/logic/enc/enc.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/logic/enc/enc_ent.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/logic/enc/enc_logic.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/logic/gen_nor/gen_nor.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/logic/gen_nor/gen_nor_ent.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/logic/gen_nor/comp/gen_and_fixed/gen_and_fixed.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/logic/gen_nor/comp/gen_and_fixed/gen_and_fixed_ent.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/logic/gen_nor/comp/gen_nor_fixed/gen_nor_fixed.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/logic/gen_nor/comp/gen_nor_fixed/gen_nor_fixed_ent.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/logic/carry_chain/carry_chain.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/pcie/others/mfb2avst/pcie_mfb2avst.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/pcie/others/avst2mfb/pcie_avst2mfb.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/fifo/fifox/fifox.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/shreg/sh_reg_base/sh_reg_base_static.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/shreg/sh_reg_base/sh_reg_base_dynamic_arch.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/shreg/sh_reg_base/sh_reg_base_dynamic_ent.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/mem/sdp_uram_xilinx/sdp_uram_xilinx_arch.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/mem/sdp_uram_xilinx/sdp_uram_xilinx_ent.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/mem/dp_uram_xilinx/dp_uram_xilinx_arch.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/mem/dp_uram_xilinx/dp_uram_xilinx_ent.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/mem/gen_lutram/gen_lutram.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/mem/gen_lutram/altdpram/altdpram_wrap_empty.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/mem/gen_lutram/altdpram/altdpram_wrap_ent.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/mem/sdp_bram/sdp_bram_be.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/mem/sdp_bram/sdp_bram.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/mem/sdp_bram/sdp_bram_behav.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/mem/sdp_bram/sdp_bram_xilinx/sdp_bram_xilinx.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/mem/sdp_bram/sdp_bram_xilinx/sdp_bram_xilinx_ent.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/mem/sdp_bram/sdp_bram_intel/sdp_bram_intel_empty.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/mem/sdp_bram/sdp_bram_intel/sdp_bram_intel_ent.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/pcie/common/pci_ext_cap.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/pkg/pcie_meta_pack.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/pkg/dma_bus_pack.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/misc/reset_tree_gen/reset_tree_gen.vhd
read_xdc ${shell_git_root}/comp/base/async/reset/async_reset.xdc
set_property SCOPED_TO_REF ASYNC_RESET [get_files async_reset.xdc]
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/async/reset/reset.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/apps/sparklev/comp/mi_addr_space_pkg.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/core/config/core_const.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/pkg/type_pack.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/comp/base/pkg/math_pack.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/apps/sparklev/build/alveo-u55c/alveo-u55c-sparklev-pcie1xGen4x4.netcope_tmp/DevTree.vhd
read_vhdl -library work -vhdl2008 ${shell_git_root}/apps/sparklev/build/alveo-u55c/alveo-u55c-sparklev-pcie1xGen4x4.netcope_tmp/netcope_const.vhd
generate_target all [get_ips]
synth_ip [get_ips]
