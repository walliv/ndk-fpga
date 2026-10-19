# gen_devtree.tcl: builds the scratchpad DevTree and its dtb_pkg VHDL package for the CORE_LOGIC bench
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

# Usage: tclsh gen_devtree.tcl <output DevTree.vhd>. Uses the firmware build's procs, so the bench reads the PDI's DTB (bar build time and tool lines).
set SCRIPT_DIR [file dirname [file normalize [info script]]]
set COMBO_BASE [file normalize "$SCRIPT_DIR/../../../.."]
set OFM_PATH      $COMBO_BASE
set FIRMWARE_BASE $COMBO_BASE
set OUT_VHD    [lindex $argv 0]

source "$COMBO_BASE/build/Shared.tcl"
source "$COMBO_BASE/build/DevTree.tcl"
source "$COMBO_BASE/build/VhdlPkgGen.tcl"
source "$COMBO_BASE/core/config/core_func.tcl"

VhdlPkgBegin
source "$COMBO_BASE/cards/amd/alveo-v80/config/card_conf.tcl"
source "$COMBO_BASE/cards/amd/alveo-v80/config/card_const.tcl"
set PCIE_DEBUG_ENABLE false
set PROJECT_VARIANT $PCIE_CONF
VhdlPkgProjectText "SCRATCHPAD"

source "$COMBO_BASE/core/top/DevTree.tcl"
source "$COMBO_BASE/comp/mi_tools/test_space/DevTree.tcl"
source "$COMBO_BASE/apps/scratchpad/comp/DevTree.tcl"

set SYNTH_FLAGS(TOOL) "SIM"
lappend DTB_LIST [concat [DevTreeGenerateBlob [file rootname $OUT_VHD] [DevTreeBuildString] "DevTree"] "DTB_PF0"]
lappend DTB_LIST [concat [DevTreeGenerateBlob "[file rootname $OUT_VHD]VF" "" "DevTreeVF"] "DTB_VF0"]
DevTreeCreateVhd $OUT_VHD $DTB_LIST
