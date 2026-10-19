# DevTree.tcl: DevTree generation script of the scratchpad application
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

# Status blocks of PCIE_BAR2AXI, one per endpoint, behind endpoint 0's MI (mi_addr_space_pkg.vhd).
proc dts_scratchpad_status {DTS base pcie_eps} {
    upvar 1 $DTS dts

    dts_create_node dts "scratchpad" {
        dts_add_cells dts
        foreach ep [nb_range $pcie_eps] {
            dts_create_node dts "scratchpad_status$ep" {
                dts_appendprop_comp_node dts [expr $base + $ep*0x100] 0x100 "ziti,scratchpad_status"
                dts_appendprop_int dts "pcie-endpoint" $ep
            }
        }
    }
}

proc dts_build_scratchpad {pcie_eps pcie_debug_en pcie_endpoint_mode pcie_mod_arch} {
    set ret ""

    dts_ndk_core_info ret

    foreach pcie [nb_range $pcie_eps] {
        dts_create_default_mi_bar_node ret $pcie 0 {
            append ret [dts_mi_test_space "mi_test_space" $NdkCore::ADDR_TEST_SPACE]
            if {$pcie == 0} {
                dts_scratchpad_status ret $NdkCore::ADDR_USERAPP $pcie_eps

                if {$pcie_debug_en} {
                    append ret [dts_pcie_core_dbg $NdkCore::ADDR_PCIE_DBG $pcie_eps $pcie_endpoint_mode $pcie_mod_arch]
                    set pcie_ctrl_base [expr $NdkCore::ADDR_PCIE_DBG + "0x100000"]
                    append ret [dts_pcie_ctrl_dbg $pcie_ctrl_base $pcie_eps $pcie_endpoint_mode $pcie_mod_arch]
                }
            }
        }
    }
    return $ret
}

proc dts_build_project {} {
    global PCIE_ENDPOINTS PCIE_DEBUG_ENABLE PCIE_ENDPOINT_MODE PCIE_MOD_ARCH
    return [dts_build_scratchpad $PCIE_ENDPOINTS $PCIE_DEBUG_ENABLE $PCIE_ENDPOINT_MODE $PCIE_MOD_ARCH]
}
