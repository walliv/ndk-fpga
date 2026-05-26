# DevTree.tcl: node generating TCL procedures
# Copyright 2025 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

# Adds a node to the Device Tree for the NVMe Command Dispatcher
# 1. DTS - reference to DeviceTree string
# 2. Base - base address of the registers in the MI address space
# 3. Idx - index of a component in case there are more of these cores
proc dts_dma_iuventus {DTS base} {
    upvar 1 $DTS dts

    set dlogger_base [expr $base + 0x1000]
    set speed_meter_base [expr $base + 0x2000]

    dts_create_node dts "dma_iuventus_ctrl" {
        dts_appendprop_comp_node dts $base 0x200 "ziti,dma_iuventus"

        append dts [data_logger $dlogger_base 0 "data_logger"]
        append dts [dts_speed_meter $speed_meter_base "pcie_cq_speed_meter"]
    }
}
