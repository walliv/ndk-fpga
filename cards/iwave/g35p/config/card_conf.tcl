# card_conf.tcl: Default parameters for iWave G35P
# Copyright (C) 2024 BrnoLogic, Ltd.
# Author(s): David Beneš <benes@brnologic.com>
#
# SPDX-License-Identifier: BSD-3-Clause


# NOTE: For the detailed description of this file, visit the Parametrization section
# in the documentation of the NDK-CORE repository.

set PROJECT_NAME ""

# ------------------------------------------------------------------------------
# ETH parameters:
# ------------------------------------------------------------------------------
# Number of Ethernet ports, must match number of items in list ETH_PORTS_SPEED!
# (with two QSFP). Set the correct number of ETH ports according to your card.
set ETH_PORTS         $env(ETH_PORTS)
# Speed for each one of the ETH_PORTS (allowed values: 100)
# ETH_PORT_SPEED is an array where each index represents given ETH_PORT and
# each index has associated a required port speed.
# NOTE: at this moment, all ports must have same speed !
set ETH_PORT_SPEED(0) $env(ETH_PORT_SPEED)
set ETH_PORT_SPEED(1) $env(ETH_PORT_SPEED)

# Number of channels for each one of the ETH_PORTS (allowed values: 1 for ETH_PORT_SPEED=100, 4 for ETH_PORT_SPEED<100)
# ETH_PORT_CHAN is an array where each index represents given ETH_PORT and
# each index has associated a required number of channels this port has.
# NOTE: at this moment, all ports must have same number of channels !
set ETH_PORT_CHAN(0) $env(ETH_PORT_CHAN)
set ETH_PORT_CHAN(1) $env(ETH_PORT_CHAN)

# Number of lanes for each one of the ETH_PORTS
# Typical values: 4 (QSFP), 8 (QSFP-DD)
set ETH_PORT_LANES(0) 8
set ETH_PORT_LANES(1) 8

# ------------------------------------------------------------------------------
# PCIe parameters (not all combinations work):
# ------------------------------------------------------------------------------
# Supported combinations for this card:
# 1x PCIe Gen3 x16  -- PCIE_ENDPOINT_MODE=0 (Note: default configuration)
# ------------------------------------------------------------------------------

# Set default PCIe configuration
set PCIE_CONF "1xGen3x16"
if { [info exist env(PCIE_CONF)] } {
    set PCIE_CONF $env(PCIE_CONF)
}

# Parsing PCIE_CONF string to list of parameters
set pcie_conf_list [ParsePcieConf $PCIE_CONF]

# PCIe Generation:
# 3 = PCIe Gen3
set PCIE_GEN           [lindex $pcie_conf_list 1]
# PCIe endpoints:
# 1 = 1x PCIe x16 in one slot
set PCIE_ENDPOINTS     [lindex $pcie_conf_list 0]
# PCIe endpoint mode:
# 0 = 1x16 lanes
set PCIE_ENDPOINT_MODE [lindex $pcie_conf_list 2]

# ------------------------------------------------------------------------------
# DMA parameters:
# ------------------------------------------------------------------------------
# This variable can be set in COREs *.mk file or as a parameter when launching the make
set DMA_TYPE             $env(DMA_TYPE)
# The minimum number of RX/TX DMA channels for this card is 16.
set DMA_RX_CHANNELS      16
set DMA_TX_CHANNELS      16
# In blocking mode, packets are dropped only when the RX DMA channel is off.
# In non-blocking mode, packets are dropped whenever they cannot be sent.
set DMA_RX_BLOCKING_MODE true

# ------------------------------------------------------------------------------
# Other parameters:
# ------------------------------------------------------------------------------
set TSU_ENABLE true

# ------------------------------------------------------------------------------
# DDR4 parameters:
# ------------------------------------------------------------------------------
# External DDR4 memory settings.
set MEM_PORTS 0
