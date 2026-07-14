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
        # 0x1000 = the sw_manager register-file window (its internal MI splitter routes
        # 0x000..0xFFF to the register file, 0x1000 to the data_logger). Must span the whole
        # register file: the common block is at 0x000.. and the per-queue 2D block at
        # PER_Q_BASE=0x200 + q*0x40 (up to ~0x400 for NUM_QUEUES=8), all of which are past the old
        # 0x200 size -- so the old size left every per-queue register (all queues, including q=0)
        # outside the nfb-accessible window. data_logger sits at $base+0x1000, immediately after.
        dts_appendprop_comp_node dts $base 0x1000 "ziti,dma_iuventus"

        append dts [data_logger $dlogger_base 0 "data_logger"]
        append dts [dts_speed_meter $speed_meter_base "pcie_cq_speed_meter"]
    }
}
