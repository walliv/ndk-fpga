# 1.  base - base module address
# 2.  type - controller type: 4 for DMA Calypte
# 3.  rxn  - number of RX channels
# 4.  txn  - number of TX channels
# 5.  pcie - index(es) of PCIe endpoint(s) which DMA module uses.
# 6.  rx_frame_size_max - maximum allowed size of DMA RX frame
# 7.  tx_frame_size_max - maximum allowed size of DMA TX frame
# 8.  rx_frame_size_min - minimum allowed size of DMA RX frame
# 9.  tx_frame_size_min - minimum allowed size of DMA TX frame
# 10. dbg_en - enabled debug logic for DMA (if there is one fs)
# 11. offset - address offset for TX controllers
# Generates Device Tree nodes for H2C DMA Hyperion write-combine buffers in BAR2.
# BAR2 maps the 16 GB HBM address space.  Each channel owns 1 GB
# (channel N → base = N * 2^30 = N * 0x40000000); channels 4-15 sit above the
# 4 GB boundary, hence the 64-bit (hi/lo) reg encoding below.
#
# 1. DTS      - variable name of the DevTree string (upvar)
# 2. pcie     - PCIe endpoint index
# 3. channels - number of H2C DMA Hyperion channels
proc dts_sparklev_h2c_dma_hyperion_bar2 {DTS pcie channels} {
    upvar 1 $DTS dts

    # 16 GB HBM / 32 channels = 0.5 GB per channel.  Channels 4+ exceed 4 GB so the
    # parent BAR2 node must use #address-cells = <2> and #size-cells = <2>.
    set CHAN_SIZE [expr {1 << 29}]

    for {set i 0} {$i < $channels} {incr i} {
        set base    [expr {$i * $CHAN_SIZE}]
        set base_hi [format "0x%x" [expr {$base >> 32}]]
        set base_lo [format "0x%x" [expr {$base & 0xFFFFFFFF}]]
        set size_hi "0x0"
        set size_lo [format "0x%x" $CHAN_SIZE]

        dts_create_node dts "h2c_dma_hyperion_buf$i" {
            dts_appendprop_string dts "compatible" "ziti,sparklev,h2c_dma_hyperion_buffer"
            dts_appendprop_reg    dts "$base_hi $base_lo" "$size_hi $size_lo"
            dts_appendprop_int    dts "pcie" $pcie
            dts_appendprop_int    dts "channel" $i
        }
    }
}

proc dts_dmamod_open {base type rxn txn pcie rx_frame_size_max tx_frame_size_max rx_frame_size_min tx_frame_size_min dbg_en {offset 0x00200000}} {
    set    ret ""
    append ret "dma_module@$base {"

    append ret "#address-cells = <1>;"
    append ret "#size-cells = <1>;"

    if {$type != 6} {
        error "ERROR: Unsupported DMA Type: $type for DMA Module!"
    }

    if {$rxn > 0} {
        append ret "dma_params_rx$pcie:" [dts_dma_params "dma_params_rx$pcie" $rx_frame_size_max $rx_frame_size_min]
    }

    # RX DMA Calypte Channels
    for {set i 0} {$i < $rxn} {incr i} {
        set    var_base [expr $base + $i * 0x80]
        dts_dma_calypte_ctrl ret "rx" $i $var_base $pcie
    }

    # H2C DMA Hyperion: one node per channel, 0x80 bytes each
    set h2c_base [expr $base + $rxn * 0x80 + 0x100000]
    dts_create_node ret "h2c_dma_hyperion" {
        dts_appendprop_comp_node ret $h2c_base 0x80 "ziti,sparklev,h2c_dma_hyperion"
        dts_appendprop_int ret "pcie" $pcie
    }

    # C2H HBM Reader: single orchestrator node for the whole HBM
    set c2h_base [expr $base + $rxn * 0x80 + 0x200000]
    dts_create_node ret "c2h_hbm_reader" {
        dts_appendprop_comp_node ret $c2h_base 0x80 "ziti,sparklev,c2h_hbm_reader"
        dts_appendprop_int ret "pcie" $pcie
    }

    append ret "};"
    return $ret
}

# 1. name - node name
# 2. frame_size_max - maximum allowed size of DMA frame
# 3. frame_size_min - minimum allowed size of DMA frame
proc dts_dma_params {name frame_size_max frame_size_min} {
    set ret ""
    append ret "$name {"
    append ret "frame_size_max = <$frame_size_max>;"
    append ret "frame_size_min = <$frame_size_min>;"
    append ret "};"
    return $ret
}
