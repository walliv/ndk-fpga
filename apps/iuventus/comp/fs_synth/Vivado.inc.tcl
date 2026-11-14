# Vivado.inc.tcl: FILE_SHELL as USER_CORE(FILES) builds it on the U55C, both PCIe endpoints
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

set SYNTH_FLAGS(FPGA) "xcu55c-fsvh2892-2L-e"
lappend SYNTH_FLAGS(USER_GENERICS) [list PCIE_ENDPOINTS 2]
set CONSTR_TEXT "create_clock -period 4.000 \[get_ports DMA_CLK\]\n"
append CONSTR_TEXT "create_clock -period 10.000 \[get_ports MI_CLK\]\n"
append CONSTR_TEXT "set_clock_groups -asynchronous -group \[get_clocks DMA_CLK\] -group \[get_clocks MI_CLK\]\n"
