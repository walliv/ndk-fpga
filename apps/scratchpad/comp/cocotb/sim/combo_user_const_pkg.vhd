-- combo_user_const_pkg.vhd: simulation stand-in for the combo_user_const package the firmware build generates
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-W-2.0

-- Values of apps/scratchpad/build/alveo-v80/app_conf.tcl that the PCIe module reads.
package combo_user_const is

    constant PCIE_CORE_DEBUG_ENABLE : boolean := false;
    constant PCIE_CTRL_DEBUG_ENABLE : boolean := false;

end package;
