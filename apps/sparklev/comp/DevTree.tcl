# DevTree.tcl: DevTree generation script for Sparklev Application
# Copyright 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

proc dts_application {DTS base arch_type} {
    upvar 1 $DTS dts

    dts_create_node dts "user_core" {
        if {$arch_type eq "FULL"} {
            dts_create_node dts "sparklev_conf_space" {
                dts_appendprop_comp_node dts $base 0x300 "ziti,sparklev,conf_space"
            }
        } elseif {$arch_type eq "TEST"} {
            append dts [dts_hbm_tester "hbm_tester" $base]
        }
    }
}

proc dts_sparklev_main_mi {DTS dma_gen_loop_en pcie_eps pcie_debug_en pcie_endpoint_mode pcie_mod_arch usr_core_arch} {
    upvar 1 $DTS ret

    # Boot module
    dts_ndk_core_boot_module ret

    # MI test space
    append ret [dts_mi_test_space "mi_test_space" $NdkCore::ADDR_TEST_SPACE]

    dts_application ret $NdkCore::ADDR_USERAPP $usr_core_arch

    # Gen Loop Switch debug modules for each DMA stream/module
    if {$dma_gen_loop_en} {
        for {set i 0} {$i < $pcie_eps} {incr i} {
            set    gls_offset [expr $i * 0x200]
            append ret [dts_gen_loop_switch [expr $NdkCore::ADDR_GEN_LOOP + $gls_offset] "dbg_gls$i"]
        }
    }

    # PCIe Debug
    if {$pcie_debug_en} {
        append ret [dts_pcie_core_dbg $NdkCore::ADDR_PCIE_DBG $pcie_eps $pcie_endpoint_mode $pcie_mod_arch]

        set pcie_ctrl_base [expr $NdkCore::ADDR_PCIE_DBG + "0x100000"]
        append ret [dts_pcie_ctrl_dbg $pcie_ctrl_base $pcie_eps $pcie_endpoint_mode $pcie_mod_arch]
    }
}

proc dts_build_project {} {
    global PCIE_ENDPOINTS H2C_DMA_CHANNELS C2H_DMA_CHANNELS DMA_PKT_SIZE_MAX DMA_DEBUG_ENABLE PCIE_DEBUG_ENABLE \
              PCIE_ENDPOINT_MODE PCIE_MOD_ARCH DMA_GEN_LOOP_EN H2C_DMA_PTR_WIDTH USR_CORE_ARCH

    set ret ""
    dts_ndk_core_info ret

    foreach pcie [nb_range $PCIE_ENDPOINTS] {
        # BAR0: MI control space — boot, application core, DMA module (C2H + H2C control + C2H HBM reader)
        dts_create_default_mi_bar_node ret $pcie 0 {
            if {$pcie == 0} {
                dts_sparklev_main_mi ret $DMA_GEN_LOOP_EN $PCIE_ENDPOINTS $PCIE_DEBUG_ENABLE \
                                        $PCIE_ENDPOINT_MODE $PCIE_MOD_ARCH $USR_CORE_ARCH
            }
            append ret [dts_dmamod_open $NdkCore::ADDR_DMA_MOD 6 $C2H_DMA_CHANNELS $H2C_DMA_CHANNELS \
                            $pcie $DMA_PKT_SIZE_MAX $DMA_PKT_SIZE_MAX 60 60 $DMA_DEBUG_ENABLE]
        }

        # BAR2: 16 GB HBM write-combine window for H2C DMA Hyperion direct writes.
        # Channel N occupies 1 GB at offset N * 0x40000000; channels 4-15 sit
        # above the 4 GB boundary, so this bar needs 64-bit (2-cell) addressing
        # and is built manually instead of via dts_create_default_mi_bar_node
        # (which hardcodes #address-cells = <1>; #size-cells = <1>;).
        dts_create_labeled_node ret "mi_pci${pcie}_bar2" "mi_pci${pcie}_bar2" {
            dts_add_cells ret 2 2
            dts_appendprop_string ret "compatible" "netcope,bus,mi"
            dts_appendprop_string ret "resource" "PCI${pcie},BAR2"
            dts_appendprop_int ret "width" "0x20"
            # Mapped write-combined: BAR2 is a prefetchable region (required for the
            # host to place this 16 GB window above the 4 GB boundary), so write-
            # combining is the natural mapping; the driver issues a FENCE after each
            # bulk write to order writes within a chunk.
            append ret "map-as-wc;"
            dts_sparklev_h2c_dma_hyperion_bar2 ret $pcie $H2C_DMA_CHANNELS
        }
    }

    return $ret
}
