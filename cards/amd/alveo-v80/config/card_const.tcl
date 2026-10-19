# card_const.tcl: Card specific parameters of the AMD Alveo V80 (development only)
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

# WARNING: Do not change these parameters; the Parametrization section of the NDK-CORE
# documentation describes them.

set CARD_NAME "ALVEO_V80"
# FPGA part (the only V80 part Vivado knows)
set FPGA_PART "xcv80-lsva4737-2MHP-e-S"
# Achitecture of Clock generator: none, the design runs on the CPM5 user clocks and the CIPS PL0 clock
set CLOCK_GEN_ARCH "EMPTY"
# Achitecture of PCIe module
set PCIE_MOD_ARCH "CPM5"
# Achitecture of SDM/SYSMON module: none
set SDM_SYSMON_ARCH "EMPTY"
# Boot controller type: none, the PDI is loaded over JTAG
set BOOT_TYPE 0
# Achitecture of Network module: none
set NET_MOD_ARCH "EMPTY"
# Total number of DMA modules/streams in FW
set DMA_MODULES $PCIE_ENDPOINTS

# No QSFP cages, DDR or memory ports are used
set QSFP_CAGES 0
set MEM_PORTS  0
set HBM_PORTS  0

# ------------------------------------------------------------------------------
# Checking of parameter compatibility
# ------------------------------------------------------------------------------

if {!($PCIE_ENDPOINTS == 2 && $PCIE_GEN == 5 && $PCIE_ENDPOINT_MODE == 1)} {
    error "Incompatible PCIe configuration: PCIE_ENDPOINTS = $PCIE_ENDPOINTS, PCIE_GEN = $PCIE_GEN, PCIE_ENDPOINT_MODE = $PCIE_ENDPOINT_MODE!
Allowed PCIe configurations:
- 1xGen5x8x8 -- PCIE_GEN=5, PCIE_ENDPOINTS=2, PCIE_ENDPOINT_MODE=1"
}

if {$DMA_TYPE != 0} {
    error "Incompatible DMA configuration: DMA_TYPE = $DMA_TYPE! The Alveo V80 supports DMA_TYPE=0 only."
}
