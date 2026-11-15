# hbm_pblock.tcl: per-port pblocks over the HBM AXI interfaces for the DMA's 450 MHz pipe stages
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

# The HBM drives READY/VALID late on a skewed clock, so the stage that handshakes with it must sit
# over its interface; the placer otherwise splits the DMA-to-HBM distance evenly across the stages.
proc hbm_pblock_col {port} {
    set rpm_x [get_property RPM_X [get_sites BLI_HBM_AXI_INTF_X${port}Y0]]
    set best_col 0
    set best_d  ""
    foreach site [get_sites -filter {SITE_TYPE =~ SLICE* && NAME =~ SLICE_X*Y0}] {
        set d [expr {abs([get_property RPM_X $site] - $rpm_x)}]
        if {$best_d eq "" || $d < $best_d} {
            set best_d $d
            regexp {SLICE_X(\d+)Y0} $site -> best_col
        }
    }
    return $best_col
}

proc hbm_pblock_cr_cols {port} {
    set x_lo ""
    set x_hi 0
    set y_hi 0
    foreach site [get_sites -of [get_clock_regions -of [get_sites BLI_HBM_AXI_INTF_X${port}Y0]] -filter {SITE_TYPE =~ SLICE*}] {
        regexp {SLICE_X(\d+)Y(\d+)} $site -> x y
        if {$x_lo eq "" || $x < $x_lo} {
            set x_lo $x
        }
        set x_hi [expr {max($x_hi, $x)}]
        set y_hi [expr {max($y_hi, $y)}]
    }
    return [list $x_lo $x_hi $y_hi]
}

proc hbm_pblocks {} {
    set ports {}
    foreach pipe [get_cells -quiet -hier -filter {NAME =~ core_logic_i/hbm_port_wiring_g*.dma_driven_port_g.hbm_450_pipe_i}] {
        regexp {hbm_port_wiring_g\[(\d+)\]} $pipe -> port
        lappend ports [list [hbm_pblock_col $port] $port $pipe]
    }
    set ports [lsort -integer -index 0 $ports]
    set n [llength $ports]

    for {set i 0} {$i < $n} {incr i} {
        lassign [lindex $ports $i] col port pipe
        lassign [hbm_pblock_cr_cols $port] cr_lo cr_hi y_hi
        # Neighbouring ports split the columns between their interfaces. An outer port mirrors its
        # inner half and stays in its interface's clock region, clear of the PCIe pblock.
        if {$i > 0} {
            set lo [expr {([lindex $ports $i-1 0] + $col) / 2 + 1}]
        } elseif {$n > 1} {
            set lo [expr {max($cr_lo, $col - ([lindex $ports 1 0] - $col) / 2)}]
        } else {
            set lo $cr_lo
        }
        if {$i < $n-1} {
            set hi [expr {($col + [lindex $ports $i+1 0]) / 2}]
        } elseif {$n > 1} {
            set hi [expr {min($cr_hi, $col + ($col - [lindex $ports $i-1 0]) / 2)}]
        } else {
            set hi $cr_hi
        }

        # The stages facing the HBM: the last of AW, W and AR, the first of B and R.
        set last {}
        set stages {}
        foreach c [get_cells -quiet -hier -filter "PARENT == $pipe"] {
            if {[regexp {\.(aw|w|ar)_stage_g\[(\d+)\]\.\w+_pipe_i$} $c -> ch idx]} {
                if {![dict exists $last $ch] || $idx > [lindex [dict get $last $ch] 0]} {
                    dict set last $ch [list $idx $c]
                }
            } elseif {[regexp {\.(b|r)_stage_g\[0\]\.\w+_pipe_i$} $c]} {
                lappend stages $c
            }
        }
        dict for {ch idx_cell} $last {
            lappend stages [lindex $idx_cell 1]
        }
        if {[llength $stages] == 0} {
            continue
        }

        set pb [create_pblock pblock_hbm_port_$port]
        add_cells_to_pblock $pb $stages
        # Vivado counts one dynamic SRL per SLICEM LUT and SLICEM columns are sparse, so a narrow port
        # grows upwards until its SRLs fill at most 3/4 of its SLICEMs.
        set srls 0
        regexp {LUT as Shift Register\s*\|\s*(\d+)} [report_utilization -pblocks $pb -return_string] -> srls
        set m_cols 0
        for {set x $lo} {$x <= $hi} {incr x} {
            if {[get_property SITE_TYPE [get_sites SLICE_X${x}Y0]] eq "SLICEM"} {
                incr m_cols
            }
        }
        set rows [expr {max($y_hi + 1, (4*$srls + 24*max($m_cols, 1) - 1) / (24*max($m_cols, 1)))}]
        resize_pblock $pb -add "SLICE_X${lo}Y0:SLICE_X${hi}Y[expr {$rows - 1}]"
        set_property IS_SOFT 0 $pb
    }
}

hbm_pblocks
