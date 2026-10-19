-- v80_hbm_wrapper_sim.vhd: simulation stand-in for the HBM block design wrapper (v80_hbm_wrapper)
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-W-2.0

library IEEE;
use IEEE.std_logic_1164.all;

-- The HBM is reached through the NoC only, which the bench models behind the xpm_nmu_mm stand-ins.
entity V80_HBM_WRAPPER is
    port (
        HBM_REF_CLK_0_CLK_N : in std_logic_vector(0 to 0);
        HBM_REF_CLK_0_CLK_P : in std_logic_vector(0 to 0)
    );
end entity;

architecture SIM of V80_HBM_WRAPPER is
begin
end architecture;
