# Makefile: builds the scratchpad application for the AMD Alveo V80
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

# NOTE: Usage of the configuration parameters in this file is described
# in the Parametrization section of the NDK-CORE documentation.

# Set path to top-level of NDK-FPGA repository
CORE_BASE=../../../../core
# The application has its own top level (src/card_top.vhd), so CARD_BASE is this directory
CARD_BASE:=$(dir $(lastword $(MAKEFILE_LIST)))
APP_CONF=app_conf.tcl

# The only configuration the card supports: two Gen5 x8 endpoints on the bifurcated edge connector
PCIE_CONF=1xGen5x8x8
DMA_TYPE=0

USER_ENV?=

OUTPUT_NAME=alveo-v80-scratchpad-pcie$(PCIE_CONF)

.PHONY: all

all: build

include ../../../../cards/amd/alveo-v80/src/card.mk
