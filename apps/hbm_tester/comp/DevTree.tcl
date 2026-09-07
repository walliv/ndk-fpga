# DevTree.tcl: DevTree generation script for the HBM tester application
# Copyright (c) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

proc dts_hbm_tester_main_mi {DTS pcie_eps pcie_debug_en pcie_endpoint_mode pcie_mod_arch} {
    upvar 1 $DTS ret

    # Boot module
    dts_ndk_core_boot_module ret

    # MI test space
    append ret [dts_mi_test_space "mi_test_space" $NdkCore::ADDR_TEST_SPACE]

    # Single-beat HBM poke, kept for bring-up: it answers "does the port respond at all" before
    # any throughput number is worth reading. Base must match MI_ADC_PORT_HBM_DBG in
    # mi_addr_space_pkg.vhd.
    dts_create_node ret "hbm_smoke_test" {
        dts_appendprop_comp_node ret 0x6000 0x80 "ziti,hbm_smoke_test"
    }

    # Sustained traffic generator and per-port beat counters. Base must match
    # MI_ADC_PORT_HBM_TPUT; the size covers the control block plus one counter block per port.
    dts_create_node ret "hbm_throughput_tester" {
        dts_appendprop_comp_node ret 0x1000000 0x1000 "ziti,hbm_throughput_tester"
    }

    # PCIe Debug
    if {$pcie_debug_en} {
        append ret [dts_pcie_core_dbg $NdkCore::ADDR_PCIE_DBG $pcie_eps $pcie_endpoint_mode $pcie_mod_arch]

        set pcie_ctrl_base [expr $NdkCore::ADDR_PCIE_DBG + "0x100000"]
        append ret [dts_pcie_ctrl_dbg $pcie_ctrl_base $pcie_eps $pcie_endpoint_mode $pcie_mod_arch]
    }
}

proc dts_build_hbm_tester {pcie_eps pcie_debug_en pcie_endpoint_mode pcie_mod_arch} {
    # =========================================================================
    # Top level Device tree file
    # =========================================================================
    set ret ""

    dts_ndk_core_info ret

    # No DMA node: this design has no DMA at all, so emitting one would hand software a base
    # address that decodes to nothing.
    foreach pcie [nb_range $pcie_eps] {
        dts_create_default_mi_bar_node ret $pcie 0 {
            if {$pcie == 0} {
                dts_hbm_tester_main_mi ret $pcie_eps $pcie_debug_en $pcie_endpoint_mode $pcie_mod_arch
            }
        }
    }
    return $ret
}

proc dts_build_project {} {
    global PCIE_ENDPOINTS PCIE_DEBUG_ENABLE PCIE_ENDPOINT_MODE PCIE_MOD_ARCH
    return [dts_build_hbm_tester $PCIE_ENDPOINTS $PCIE_DEBUG_ENABLE \
        $PCIE_ENDPOINT_MODE $PCIE_MOD_ARCH]
}
