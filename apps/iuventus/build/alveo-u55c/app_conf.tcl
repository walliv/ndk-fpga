# app_conf.tcl: User parameters for AMD Alveo U55C Card
# Copyright 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

# ---- PCIe parameters, overridable from the Makefile ----
# Supported (PCIE_GEN, PCIE_ENDPOINT_MODE) for this card: Gen3 x16 = (3,0) default; Gen4 x8x8 =
# (4,1); Gen3 x8 = (3,2);
set PCIE_CONF "1xGen3x16"
if { [info exist env(PCIE_CONF)] } {
    set PCIE_CONF $env(PCIE_CONF)
}

# Parsing PCIE_CONF string to list of parameters
set pcie_conf_list [ParsePcieConf $PCIE_CONF]

# PCIe Generation:
# 3 = PCIe Gen3
# 4 = PCIe Gen4
set PCIE_GEN           [lindex $pcie_conf_list 1]
# PCIe endpoints:
# 1 = 1 PCIe endpints
# 2 = 2 PCIe endpints
set PCIE_ENDPOINTS     [lindex $pcie_conf_list 0]
# PCIe endpoint mode:
# 0 = 1x16 lanes
# 1 = 2x8  lanes (bifurcation)
# 2 = 1x8  lanes
set PCIE_ENDPOINT_MODE [lindex $pcie_conf_list 2]

# ---- Other parameters ----
# The user-core architecture is read before PROJECT_NAME because the name carries it: nfb-info
# reports that name and the flash procedure identifies a card by it, so two architectures must
# not answer to the same name.
set USR_CORE_ARCH $env(USR_CORE_ARCH)

set PROJECT_NAME "IUVENTUS_$USR_CORE_ARCH"
set PROJECT_VARIANT "$PCIE_CONF"
set PROJECT_VERSION [exec cat ../../../../VERSION]

# Enables debug probes and counters in the PCIe Module (PCIe Core arch: USP and P-Tile and PCIe Ctrl)
set PCIE_DEBUG_ENABLE false

# ------------------------------------------------------------------------------
# Constant parameters (do not change)
# ------------------------------------------------------------------------------
set DMA_TYPE 5

set CARD_NAME "ALVEO_U55C"
# Achitecture of Clock generator
set CLOCK_GEN_ARCH "USP"
# Achitecture of PCIe module
set PCIE_MOD_ARCH "USP_PCIE4C"
# Achitecture of SDM/SYSMON module
set SDM_SYSMON_ARCH "USP_IDCOMP"
# Boot controller type
set BOOT_TYPE 1

# Build identification (generated automatically by default)
set BUILD_TIME [format "%d" [clock seconds]]
set BUILD_UID  [format "%d" [exec id -u]]

set PCIE_LANES 16
if {$PCIE_ENDPOINT_MODE == 2} {
    set PCIE_LANES 8
} elseif {$PCIE_ENDPOINT_MODE == 3} {
    set PCIE_LANES 4
}

# ------------------------------------------------------------------------------
# Checking of parameter compatibility
# ------------------------------------------------------------------------------

if {!(($PCIE_ENDPOINTS == 1 && $PCIE_GEN == 3 && $PCIE_ENDPOINT_MODE == 0) ||
      ($PCIE_ENDPOINTS == 1 && $PCIE_GEN == 3 && $PCIE_ENDPOINT_MODE == 2) ||
      ($PCIE_ENDPOINTS == 1 && $PCIE_GEN == 4 && $PCIE_ENDPOINT_MODE == 2) ||
      ($PCIE_ENDPOINTS == 2 && $PCIE_GEN == 4 && $PCIE_ENDPOINT_MODE == 1)) } {
    error "Incompatible PCIe configuration: PCIE_ENDPOINTS = $PCIE_ENDPOINTS, PCIE_GEN = $PCIE_GEN, PCIE_ENDPOINT_MODE = $PCIE_ENDPOINT_MODE!
Allowed PCIe configurations:
- 1xGen3x16  -- PCIE_GEN=3, PCIE_ENDPOINTS=1, PCIE_ENDPOINT_MODE=0
- 1xGen3x8LL -- PCIE_GEN=3, PCIE_ENDPOINTS=1, PCIE_ENDPOINT_MODE=2
- 2xGen4x8x8 -- PCIE_GEN=4, PCIE_ENDPOINTS=2, PCIE_ENDPOINT_MODE=1"
}

VhdlPkgProjectText $PROJECT_NAME

VhdlPkgStr PCIE_MOD_ARCH            $PCIE_MOD_ARCH
VhdlPkgInt PCIE_LANES               $PCIE_LANES
VhdlPkgInt PCIE_GEN                 $PCIE_GEN
VhdlPkgInt PCIE_ENDPOINTS           $PCIE_ENDPOINTS
VhdlPkgInt PCIE_ENDPOINT_MODE       $PCIE_ENDPOINT_MODE
VhdlPkgBool PCIE_CORE_DEBUG_ENABLE  $PCIE_DEBUG_ENABLE
VhdlPkgBool PCIE_CTRL_DEBUG_ENABLE  $PCIE_DEBUG_ENABLE