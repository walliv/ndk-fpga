-- cqe_error_tracker.vhd: this outputs a mask of the captured errors
-- Copyright (C) 2025 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-P-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- Note:

use work.nvme_meta_pack.ALL;

entity CQE_ERROR_TRACKER is
    Port (
        CLK         : in  std_logic;
        CLR         : in  std_logic;
        SCT         : in  std_logic_vector(2 downto 0);
        SC          : in  std_logic_vector(7 downto 0);
        -- The output error mask is larger than the overall amount of possible errors. This is in
        -- order to align it to the nearest power of 2
        ERROR_MASK  : out std_logic_vector(ERR_MASK_W -1 downto 0)
    );
end entity;

architecture FULL of CQE_ERROR_TRACKER is
    signal latched_mask : std_logic_vector(ERR_MASK_W -1 downto 0);
begin

    err_latch_i : process(CLK)
    begin
        if rising_edge(CLK) then
            if CLR = '1' then
                latched_mask <= (others => '0');
            else
                for i in 0 to (NUM_ERROR_CODES-1) loop
                    if SCT = ERROR_CODES(i).SCT and SC = ERROR_CODES(i).SC then
                        latched_mask(i) <= '1';
                    end if;
                end loop;

                -- The last bit is set if a vendor specific message has been captured
                if (SCT = "111") then
                    latched_mask(NUM_ERROR_CODES) <= '1';
                end if;
            end if;
        end if;
    end process;

    ERROR_MASK <= latched_mask;
end architecture;
