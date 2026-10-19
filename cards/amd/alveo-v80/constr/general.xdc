# general.xdc: board pins of the Alveo V80 used by the platform BD
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

# HBM stack 0 reference clock, 200 MHz LVDS on the dedicated bank 800 pads (AVED impl.pins.xdc). The device fixes the CPM5 GT lanes, GT refclks and PERST# pins.
set_property PACKAGE_PIN N18 [get_ports HBM_REFCLK0_P]
set_property PACKAGE_PIN N19 [get_ports HBM_REFCLK0_N]
