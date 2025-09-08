# Quartus.inc.tcl: Quartus.tcl include for DK-DEV-1SDX-P card
# Copyright (C) 2022 CESNET z. s. p. o.
# Author(s): Jakub Cabal <cabal@cesnet.cz>
#           Vladislav Valek <valekv@cesnet.cz>
#
# SPDX-License-Identifier: BSD-3-Clause

# NDK constants (populates all NDK variables from env)
source $env(CORE_BASE)/config/core_bootstrap.tcl

# Include common card script
source $CORE_BASE/Quartus.inc.tcl

# Propagating card constants to the Modules.tcl files of the underlying components.
# The description of usage of this array is provided in the Parametrization section
# of the NDK-CORE repository.
set CARD_ARCHGRP(CORE_BASE)          $CORE_BASE
set CARD_ARCHGRP(IP_BUILD_DIR)       $CARD_BASE/src/ip
set CARD_ARCHGRP(PCIE_ENDPOINT_MODE) $PCIE_ENDPOINT_MODE
set CARD_ARCHGRP(NET_MOD_ARCH)       $NET_MOD_ARCH

# select fpga name
set CARD_FPGA                        "1SD280PT2F55E1VG"
set CARD_ARCHGRP(FPGA)               $CARD_FPGA

# make lists from associative arrays
set CARD_ARCHGRP_L [array get CARD_ARCHGRP]
set CORE_ARCHGRP_L [array get CORE_ARCHGRP]

# concatenate lists to be handed as a part of the ARCHGRP to the TOPLEVEL
set ARCHGRP_ALL [concat $CARD_ARCHGRP_L $CORE_ARCHGRP_L]

# Main component
lappend HIERARCHY(COMPONENTS) \
    [list "TOPLEVEL" $CARD_BASE/src $ARCHGRP_ALL]

# Design parameters
set SYNTH_FLAGS(MODULE) "APP_BRISKI_TOP"
set SYNTH_FLAGS(FPGA)   $CARD_FPGA

# QSF constraints for specific parts of the design
set SYNTH_FLAGS(CONSTR) ""
# set SYNTH_FLAGS(CONSTR) "$SYNTH_FLAGS(CONSTR) $CARD_BASE/constr/pcie0.qsf"
#set SYNTH_FLAGS(CONSTR) "$SYNTH_FLAGS(CONSTR) $CARD_BASE/constr/pcie1.qsf"
# set SYNTH_FLAGS(CONSTR) "$SYNTH_FLAGS(CONSTR) $CARD_BASE/constr/qsfp.qsf"
# set SYNTH_FLAGS(CONSTR) "$SYNTH_FLAGS(CONSTR) $CARD_BASE/constr/ddr4_sodimm.qsf"
set SYNTH_FLAGS(CONSTR) "$SYNTH_FLAGS(CONSTR) $CARD_BASE/constr/general.qsf"
set SYNTH_FLAGS(CONSTR) "$SYNTH_FLAGS(CONSTR) $CARD_BASE/constr/timing.sdc"
