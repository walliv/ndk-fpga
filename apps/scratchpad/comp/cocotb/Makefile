# Makefile: cocotb integration bench of the scratchpad CORE_LOGIC (CPM5 PCIe module, PCIE_BAR2AXI, MI) on nvc
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

TOP_LEVEL_ENT=CORE_LOGIC
# A local Modules.tcl adds the stand-ins of the block designs and NMUs to ../Modules.tcl
TOP_LEVEL_PATH=.
TARGET=nvc-sim
NVC_PLATFORM_TAGS := xilinx

# nvc needs libpython to load the cocotb VHPI bridge; only the nvc run step gets it.
PYTHON_LIBDIR := $(shell python3 -c 'import sysconfig; print(sysconfig.get_config_var("LIBDIR"))' 2>/dev/null)
ifneq ($(PYTHON_LIBDIR),)
NVC_RUN_ENV := LD_LIBRARY_PATH=$(PYTHON_LIBDIR):$$LD_LIBRARY_PATH
endif

# Where gen_devtree.tcl writes DevTree.vhd (dtb_pkg) and DevTree.dtb
NETCOPE_TEMP ?= $(CURDIR)/netcope_tmp/
export NETCOPE_TEMP

# TLPs per endpoint in the random tests
SPAD_TLPS ?= 1500
export SPAD_TLPS

# The bench imports the bar2axi bench's AXI memory model
export PYTHONPATH := $(CURDIR)/../../../../comp/pcie/bar2axi/cocotb:$(PYTHONPATH)

.PHONY: all devtree test clean_devtree

all: test

devtree:
	mkdir -p $(NETCOPE_TEMP)
	tclsh gen_devtree.tcl $(NETCOPE_TEMP)DevTree.vhd

test: devtree
	$(MAKE) "SYNTHFILES=$(OFM_PATH)/build/targets/comp_vivado.tcl" nvc-sim

clean_devtree:
	$(RM) -r $(NETCOPE_TEMP)

CLEAN_DEPENDS += clean_devtree

include ../../../../build/Makefile
