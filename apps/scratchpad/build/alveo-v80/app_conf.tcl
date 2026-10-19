# app_conf.tcl: User parameters of the scratchpad application on the AMD Alveo V80
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

set V80_CARD_BASE $COMBO_BASE/cards/amd/alveo-v80

# PCIe configuration (PCIE_CONF, PCIE_GEN, PCIE_ENDPOINTS, PCIE_ENDPOINT_MODE) and DMA_TYPE
source $V80_CARD_BASE/config/card_conf.tcl

# ---- Other parameters ----
set PROJECT_NAME "SCRATCHPAD"
set PROJECT_VARIANT "$PCIE_CONF"
set PROJECT_VERSION [exec cat ../../../../VERSION]

# Enables debug probes and counters in the PCIe Module (PCIe Core and PCIe Ctrl)
set PCIE_DEBUG_ENABLE false

# Card constants (CARD_NAME, PCIE_MOD_ARCH, FPGA_PART, ...) and the card's compatibility checks
source $V80_CARD_BASE/config/card_const.tcl

# Build identification (generated automatically by default)
set BUILD_TIME [format "%d" [clock seconds]]
set BUILD_UID  [format "%d" [exec id -u]]

set PCIE_LANES 16

VhdlPkgProjectText $PROJECT_NAME

VhdlPkgStr PCIE_MOD_ARCH            $PCIE_MOD_ARCH
VhdlPkgInt PCIE_LANES               $PCIE_LANES
VhdlPkgInt PCIE_GEN                 $PCIE_GEN
VhdlPkgInt PCIE_ENDPOINTS           $PCIE_ENDPOINTS
VhdlPkgInt PCIE_ENDPOINT_MODE       $PCIE_ENDPOINT_MODE
VhdlPkgBool PCIE_CORE_DEBUG_ENABLE  $PCIE_DEBUG_ENABLE
VhdlPkgBool PCIE_CTRL_DEBUG_ENABLE  $PCIE_DEBUG_ENABLE
