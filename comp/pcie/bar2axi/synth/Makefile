# Makefile: out-of-context Vivado synthesis of PCIE_BAR2AXI
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

TOP_LEVEL_ENT=PCIE_BAR2AXI
TOP_LEVEL_PATH=..

SYNTH=vivado

# DEVICE=VERSAL selects xcv80-lsva4737-2MHP-e-S in build/targets/comp_vivado.tcl; 250 MHz
export DEVICE=VERSAL
export CLK_PERIOD=4.0

.PHONY: all
all: comp

include ../../../../build/Makefile
