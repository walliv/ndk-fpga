# card.mk: Makefile include of the AMD Alveo V80
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

# Optional parameters (can be changed in user Makefile)

# Name for output files (rootname)
# This value is set as default in SYNTH_FLAGS(OUTPUT)
OUTPUT_NAME ?= alveo-v80

# The card supports one PCIe configuration only, see config/card_const.tcl
PCIE_CONF ?= 1xGen5x8x8

USER_ENV ?=

# Private parameters (do not change these values in user Makefile)

# Get directory of this Makefile.inc
CARD_BASE_LOCAL := $(dir $(lastword $(MAKEFILE_LIST)))
# An application with its own top level sets CARD_BASE to its build directory before including this file
CARD_BASE ?= $(CARD_BASE_LOCAL)/..
CORE_BASE ?= $(COMBO_BASE)/core

# Load correct paths to build system
include $(CORE_BASE)/ndk_paths.mk

NETCOPE_ENV = \
	OFM_PATH=$(OFM_PATH)\
	COMBO_BASE=$(COMBO_BASE)\
	FIRMWARE_BASE=$(FIRMWARE_BASE)\
	CARD_BASE=$(CARD_BASE) \
	CORE_BASE=$(CORE_BASE) \
	APP_CONF=$(APP_CONF) \
	OUTPUT_NAME=$(OUTPUT_NAME) \
	PCIE_CONF=$(PCIE_CONF) \
	DMA_TYPE=$(DMA_TYPE) \
	$(USER_ENV)

# core.mk includes the Vivado make rules
include $(CORE_BASE)/core.mk
