# DevTree.tcl: DevTree generation script for Iuventus Application
# Copyright (c) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

proc dts_application {DTS base arch_type} {
    upvar 1 $DTS dts

    set mfb_gen_base     [expr $base + 0x100]
    set data_logger_base [expr $base + 0x200]

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

    # HBM smoke-test debug registers (base must match MI_ADC_PORT_HBM_DBG in mi_addr_space_pkg.vhd)
    dts_create_node ret "hbm_smoke_test" {
        dts_appendprop_comp_node ret 0x6000 0x80 "ziti,hbm_smoke_test"
    }

    dts_application ret $NdkCore::ADDR_USERAPP $usr_core_arch

    # PCIe Debug
    if {$pcie_debug_en} {
        append ret [dts_pcie_core_dbg $NdkCore::ADDR_PCIE_DBG $pcie_eps $pcie_endpoint_mode $pcie_mod_arch]

        set pcie_ctrl_base [expr $NdkCore::ADDR_PCIE_DBG + "0x100000"]
        append ret [dts_pcie_ctrl_dbg $pcie_ctrl_base $pcie_eps $pcie_endpoint_mode $pcie_mod_arch]
    }
}

proc dts_build_iuventus {pcie_eps pcie_debug_en pcie_endpoint_mode pcie_mod_arch usr_core_arch} {
    # =========================================================================
    # Top level Device tree file
    # =========================================================================
    set ret ""

    dts_ndk_core_info ret

    foreach pcie [nb_range $pcie_eps] {
        dts_create_default_mi_bar_node ret $pcie 0 {
            if {$pcie == 0} {
                dts_iuventus_main_mi ret $pcie_eps $pcie_debug_en $pcie_endpoint_mode $pcie_mod_arch $usr_core_arch
            }

            dts_dma_iuventus ret $NdkCore::ADDR_DMA_MOD
        }
    }
    return $ret
}

proc dts_build_project {} {
    global PCIE_ENDPOINTS PCIE_DEBUG_ENABLE PCIE_ENDPOINT_MODE PCIE_MOD_ARCH USR_CORE_ARCH
    return [dts_build_iuventus $PCIE_ENDPOINTS $PCIE_DEBUG_ENABLE \
        $PCIE_ENDPOINT_MODE $PCIE_MOD_ARCH $USR_CORE_ARCH]
}
