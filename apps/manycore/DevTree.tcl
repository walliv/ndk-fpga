# DevTree.tcl: contains procedures that generate nodes to the Device Tree of the FPGA
# design
# Copyright 2024 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

proc dts_multicore_debug_core {index base reg_size} {
	set ret ""
	append ret "multicore_debug_core$index {"
    append ret "compatible = \"ziti,minimal,multicore_debug_core\";"
	append ret "reg = <$base $reg_size>;"
    append ret "};"
	return $ret
}
