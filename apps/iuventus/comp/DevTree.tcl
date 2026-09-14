# DevTree.tcl: DevTree generation script for Iuventus Application
# Copyright (c) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

# The node set follows the architecture that was built: the register maps have nothing in common,
# so emitting the TEST layout for a GROUPBY build would hand software addresses that decode to
# something else entirely.
proc dts_application {DTS base arch_type} {
    upvar 1 $DTS dts

    set mfb_gen_base     [expr $base + 0x100]
    set data_logger_base [expr $base + 0x200]

    if {$arch_type eq "GROUPBY"} {
        dts_create_node dts "user_core" {
            dts_create_node dts "iuventus_groupby" {
                dts_appendprop_comp_node dts $base 0x100 "ziti,iuventus_groupby"
            }
        }
        return
    }

    dts_create_node dts "user_core" {
        dts_create_node dts "iuventus_test_ctrl" {
            dts_appendprop_comp_node dts $base 0x80 "ziti,iuventus_test_ctrl"
        }
        append dts [dts_mfb_generator $mfb_gen_base "nvme_wr_data_gen"]
        append dts [data_logger $data_logger_base 0 "latency_meter"]
    }
}

proc dts_iuventus_main_mi {DTS pcie_eps pcie_debug_en pcie_endpoint_mode pcie_mod_arch usr_core_arch} {
    upvar 1 $DTS ret

    # Boot module
    dts_ndk_core_boot_module ret

    # MI test space
    append ret [dts_mi_test_space "mi_test_space" $NdkCore::ADDR_TEST_SPACE]

    dts_application ret $NdkCore::ADDR_USERAPP $usr_core_arch

    # PCIe Debug
    if {$pcie_debug_en} {
        append ret [dts_pcie_core_dbg $NdkCore::ADDR_PCIE_DBG $pcie_eps $pcie_endpoint_mode $pcie_mod_arch]

        set pcie_ctrl_base [expr $NdkCore::ADDR_PCIE_DBG + "0x100000"]
        append ret [dts_pcie_ctrl_dbg $pcie_ctrl_base $pcie_eps $pcie_endpoint_mode $pcie_mod_arch]
    }
}

proc dts_build_iuventus {pcie_eps pcie_debug_en pcie_endpoint_mode pcie_mod_arch usr_core_arch cq_sink} {
    # =========================================================================
    # Top level Device tree file
    # =========================================================================
    set ret ""

    dts_ndk_core_info ret

    foreach pcie [nb_range $pcie_eps] {
        dts_create_default_mi_bar_node ret $pcie 0 {
            if {$pcie == 0} {
                dts_iuventus_main_mi ret $pcie_eps $pcie_debug_en $pcie_endpoint_mode $pcie_mod_arch $usr_core_arch

                if {$cq_sink} {
                    # The CQ sink variant has no DMA: the same address space holds one speed
                    # meter per endpoint, 0x20 apart (core_logic.vhd's cq_sink_g).
                    append ret [dts_speed_meter $NdkCore::ADDR_DMA_MOD "cq_sink_ep0"]
                    if {$pcie_eps == 2} {
                        append ret [dts_speed_meter [expr $NdkCore::ADDR_DMA_MOD + 0x20] "cq_sink_ep1"]
                    }
                } else {
                    # The one DMA_IUVENTUS instance sits behind endpoint 0's MI only; endpoint 1's
                    # PF0 is a dummy no driver reads, so it gets no ziti,dma_iuventus node.
                    dts_dma_iuventus ret $NdkCore::ADDR_DMA_MOD
                }
            }
        }
    }
    return $ret
}

proc dts_build_project {} {
    global PCIE_ENDPOINTS PCIE_DEBUG_ENABLE PCIE_ENDPOINT_MODE PCIE_MOD_ARCH USR_CORE_ARCH CQ_SINK
    return [dts_build_iuventus $PCIE_ENDPOINTS $PCIE_DEBUG_ENABLE \
        $PCIE_ENDPOINT_MODE $PCIE_MOD_ARCH $USR_CORE_ARCH $CQ_SINK]
}
