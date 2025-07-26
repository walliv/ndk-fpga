# DevTree.tcl: script containg Device Tree generation procedure
# Copyright (C) 2025 CESNET
# Author(s): Vladislav Valek <valekv@cesnet.cz>
#
# SPDX-License-Identifier: BSD-3-Clause

# DEPRECATED: Use more general procedure below
proc dts_speed_meter {base {name "speed_meter"}} {
    set ret ""
    append ret "$name {"
    append ret "compatible = \"cesnet,ofm,speed_meter\";"
    append ret "version = <0x00000001>;"
    append ret "reg = <$base 0x1c>;"
    append ret "};"
    return $ret
}

proc dts_speed_meter {DTS base {id 0} {name "speed_meter"} {vendor "cesnet"}} {
    upvar 1 $DTS dts

    dts_create_node dts "$name" {
        dts_appendprop_comp_node dts $base 0x1c "$vendor,$name"
        dts_appendprop_int dts "version" 0x00000001
    }
}
