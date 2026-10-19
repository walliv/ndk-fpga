# card_conf.tcl: User changeable parameters of the AMD Alveo V80
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

# NOTE: The Parametrization section of the NDK-CORE documentation describes this file.

# PCIe parameters: only 2x Gen5 x8 (bifurcated x8x8 on the edge connector) is supported
set PCIE_CONF "1xGen5x8x8"
if { [info exist env(PCIE_CONF)] } {
    set PCIE_CONF $env(PCIE_CONF)
}

# Parsing PCIE_CONF string to list of parameters
set pcie_conf_list [ParsePcieConf $PCIE_CONF]

# PCIe Generation:
# 5 = PCIe Gen5
set PCIE_GEN           [lindex $pcie_conf_list 1]
# PCIe endpoints:
# 2 = 2x PCIe x8 on the bifurcated edge connector
set PCIE_ENDPOINTS     [lindex $pcie_conf_list 0]
# PCIe endpoint mode:
# 1 = 2x8 lanes (bifurcated)
set PCIE_ENDPOINT_MODE [lindex $pcie_conf_list 2]

# DMA parameters: no NDK DMA module is supported on this card yet (DMA_TYPE=0)
set DMA_TYPE 0
if { [info exist env(DMA_TYPE)] } {
    set DMA_TYPE $env(DMA_TYPE)
}
