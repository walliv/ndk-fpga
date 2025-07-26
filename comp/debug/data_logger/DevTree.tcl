# DevTree.tcl: Dev tree of stats component
# Copyright (C) 2021 CESNET z. s. p. o.
# Author(s): Lukas Nevrkla <xnevrk03@stud.fit.vutbr.cz>
#
# SPDX-License-Identifier: BSD-3-Clause

# DEPRECATED: Use a more dynamically adjustable procedure below
# 1. base 		- base address on MI bus
# 2. id  		- stats id
# 3. compatible	- compatible
proc data_logger {base id compatible} {
	set    ret ""
	append ret "$compatible" "_$id {"
	append ret "reg = <$base 0x30>;"
	append ret "compatible = \"netcope,$compatible\";"
	append ret "};"
	return $ret
}

proc dts_data_logger {DTS base {id 0} {compatible "data_logger"} {vendor "netcope"}} {
    upvar 1 $DTS dts

	dts_create_node dts "$compatible\_$id" {
		dts_appendprop_comp_node dts $base 0x30 "$vendor,$compatible"
	}
}
