# Vivado.tcl: Vivado tcl script to compile whole FPGA design
# Copyright 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

set OUTPUT_NAME   $env(OUTPUT_NAME)
set OFM_PATH      $env(OFM_PATH)
set COMBO_BASE    $env(COMBO_BASE)
set FIRMWARE_BASE $env(FIRMWARE_BASE)
set CARD_BASE     $env(CARD_BASE)
set CORE_BASE     $env(CORE_BASE)

set CORE_FUNC  $COMBO_BASE/core/config/core_func.tcl
set APP_CONF $env(APP_CONF)

source $OFM_PATH/build/VhdlPkgGen.tcl
source $OFM_PATH/build/Vivado.inc.tcl
source $COMBO_BASE/core/ip/common.tcl

VhdlPkgBegin

# Source CORE functions
source $CORE_FUNC
# Source configuratble parameters
source $APP_CONF

set SYNTH_FLAGS(OUTPUT) $OUTPUT_NAME

# Prerequisites for generated VHDL package
set UCP_PREREQ [list $APP_CONF]

# Let generate package from configuration files and add it to project
lappend HIERARCHY(PACKAGES) [nb_generate_file_register_userpkg "combo_user_const" "" $UCP_PREREQ]

# Let generate DevTree.vhd and add it to project
lappend HIERARCHY(PACKAGES) [nb_generate_file_register_devtree]

# ----- Default target: synthesis of the project ------------------------------
proc target_default {} {
    global SYNTH_FLAGS HIERARCHY
    SynthesizeProject SYNTH_FLAGS HIERARCHY
}

# ----- Setting basic synthesis options ---------------------------------------
set SYNTH_FLAGS(MODULE)    "CARD_TOP"
set SYNTH_FLAGS(FPGA)      "xcu55c-fsvh2892-2L-e"
set SYNTH_FLAGS(MCS_IFACE) "SPIx4"
set SYNTH_FLAGS(BOARD)     $CARD_NAME

# Create only a Vivado project for further design GUI flow
# "0" ... full design flow in command line
# "1" ... gather sources and create project
set SYNTH_FLAGS(PROJ_ONLY) "0"

# Synthesize the created project (does not take effect if PROJ_ONLY is "1")
# "0" ... full design flow in command line
# "1" ... synthesize the project
set SYNTH_FLAGS(SYNTH_ONLY) "0"

# Timing-closure directives for the N=4 x QD64 build. The directive search is exhausted here:
# place ExtraTimingOpt with route AggressiveExplore measured best, and both alternatives tried
# (place Explore, route NoTimingRelaxation) came out clearly worse.
set SYNTH_FLAGS(ROUTE_DIRECTIVE)           "AggressiveExplore"
# AggressiveExplore, not Explore: on this design Explore measured WNS -0.278 / TNS -378 against
# AggressiveExplore's -0.191 / -210 on identical RTL.
set SYNTH_FLAGS(PPLACE_PHYS_OPT_DIRECTIVE) "AggressiveExplore"
# Post-route phys_opt: build/Vivado.inc.tcl only enables STEPS.POST_ROUTE_PHYS_OPT_DESIGN when
# this variable exists, and no other app in the repo sets it. It is Vivado's last-mile step, worth
# having on a design whose margin is tens of ps.
set SYNTH_FLAGS(PROUTE_PHYS_OPT_DIRECTIVE) "ExploreWithAggressiveHoldFix"
# PLACE_DIRECTIVE stays ExtraTimingOpt. AltSpreadLogic_medium trades timing for spreading, the
# wrong trade on a design whose worst paths are inside the CQ write buffer.
set SYNTH_FLAGS(PLACE_DIRECTIVE)           "ExtraTimingOpt"

# Retiming is ON: with ~16 logic levels either side of a pipeline register deep in the DMA,
# moving work across it by hand is zero-sum. Re-measure before disabling.
set SYNTH_FLAGS(RETIMING)                  "true"

# power_opt_design stays ON. Its clock-enable gating cells can land on a critical path, but turning
# the step off costs about 0.14 ns across the whole design: the logic optimisation it also performs
# is worth more than the gating costs.
set SYNTH_FLAGS(POWER_OPT_DESIGN)          "true"

# Associative array which is propagated throughout Modules.tcl files
set APP_ARCHGRP(CORE_BASE)       $CORE_BASE
set APP_ARCHGRP(CLOCK_GEN_ARCH)  $CLOCK_GEN_ARCH
set APP_ARCHGRP(PCIE_MOD_ARCH)   $PCIE_MOD_ARCH
set APP_ARCHGRP(SDM_SYSMON_ARCH) $SDM_SYSMON_ARCH
set APP_ARCHGRP(DMA_TYPE)        $DMA_TYPE

set APP_ARCHGRP(PCIE_GEN)           $PCIE_GEN
set APP_ARCHGRP(PCIE_ENDPOINTS)     $PCIE_ENDPOINTS
set APP_ARCHGRP(PCIE_ENDPOINT_MODE) $PCIE_ENDPOINT_MODE

set APP_ARCHGRP(IP_BUILD_DIR)     $CARD_BASE/src
set APP_ARCHGRP(IP_GEN_FILES)     false
set APP_ARCHGRP(IP_MODIFY_BASE)   $COMBO_BASE/cards/amd/alveo-u55c/src/ip
set APP_ARCHGRP(USE_IP_SUBDIRS)   true

# Convert associative array to list
set APP_ARCHGRP_L [array get APP_ARCHGRP]

# --------- Add source files for the design ---------------------------------------
lappend HIERARCHY(COMPONENTS) [list "CORE_LOGIC" "$OFM_PATH/apps/hbm_tester/comp" $APP_ARCHGRP_L]

lappend HIERARCHY(MOD) "$CARD_BASE/src/card_top.vhd"

# --------- Add constraints to the design ---------------------------------------
lappend SYNTH_FLAGS(CONSTR) "$CARD_BASE/src/general.xdc"
# ILA left out: its capture paths are the only timing-failing group, and the counters it would
# probe are readable over MI instead. Uncomment to capture received data over JTAG.
# lappend SYNTH_FLAGS(CONSTR) "$CARD_BASE/src/ilas.xdc"

lappend SYNTH_FLAGS(CONSTR) "$COMBO_BASE/cards/amd/alveo-u55c/constr/pcie_half.xdc"

if {$PCIE_ENDPOINT_MODE == 0 || $PCIE_ENDPOINT_MODE == 1} {
    lappend SYNTH_FLAGS(CONSTR) "$COMBO_BASE/cards/amd/alveo-u55c/constr/pcie_full.xdc"
}

# Call main function which handle targets
nb_main
