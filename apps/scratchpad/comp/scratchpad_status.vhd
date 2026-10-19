-- scratchpad_status.vhd: MI-readable status registers of one scratchpad endpoint
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-W-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- Read-only registers in the endpoint's clock: 0x00 CNT_WR, 0x04 CNT_RD, 0x08 CNT_UR, 0x0C CNT_DROP, 0x10 CNT_ERR, 0x14 INFO ([0] link up, [7:4] endpoint), 0x18 ID. Writes are accepted and ignored, address bits above 4 are not decoded.
entity SCRATCHPAD_STATUS is
    generic (
        -- Endpoint index reported in INFO
        EP_INDEX  : natural := 0;
        -- Width of the PCIE_BAR2AXI status counters
        CNT_WIDTH : natural := 32
    );
    port (
        CLK      : in  std_logic;
        RESET    : in  std_logic;

        MI_DWR   : in  std_logic_vector(32-1 downto 0);
        MI_ADDR  : in  std_logic_vector(32-1 downto 0);
        MI_BE    : in  std_logic_vector(4-1 downto 0);
        MI_RD    : in  std_logic;
        MI_WR    : in  std_logic;
        MI_DRD   : out std_logic_vector(32-1 downto 0);
        MI_ARDY  : out std_logic;
        MI_DRDY  : out std_logic;

        CNT_WR   : in  std_logic_vector(CNT_WIDTH-1 downto 0);
        CNT_RD   : in  std_logic_vector(CNT_WIDTH-1 downto 0);
        CNT_UR   : in  std_logic_vector(CNT_WIDTH-1 downto 0);
        CNT_DROP : in  std_logic_vector(CNT_WIDTH-1 downto 0);
        CNT_ERR  : in  std_logic_vector(CNT_WIDTH-1 downto 0);
        LINK_UP  : in  std_logic
    );
end entity;

architecture FULL of SCRATCHPAD_STATUS is

    -- "SPAD"
    constant STATUS_ID : std_logic_vector(32-1 downto 0) := X"53504144";

    signal reg_addr : unsigned(4 downto 2);

begin

    assert (CNT_WIDTH <= 32)
        report "SCRATCHPAD_STATUS: CNT_WIDTH must not exceed 32!"
        severity failure;

    reg_addr <= unsigned(MI_ADDR(4 downto 2));
    MI_ARDY  <= MI_RD or MI_WR;

    mi_read_p : process (CLK)
    begin
        if (rising_edge(CLK)) then
            MI_DRD <= (others => '0');
            case to_integer(reg_addr) is
                when 0      => MI_DRD(CNT_WIDTH-1 downto 0) <= CNT_WR;
                when 1      => MI_DRD(CNT_WIDTH-1 downto 0) <= CNT_RD;
                when 2      => MI_DRD(CNT_WIDTH-1 downto 0) <= CNT_UR;
                when 3      => MI_DRD(CNT_WIDTH-1 downto 0) <= CNT_DROP;
                when 4      => MI_DRD(CNT_WIDTH-1 downto 0) <= CNT_ERR;
                when 5      =>
                    MI_DRD(0)          <= LINK_UP;
                    MI_DRD(7 downto 4) <= std_logic_vector(to_unsigned(EP_INDEX, 4));
                when 6      => MI_DRD <= STATUS_ID;
                when others => null;
            end case;

            MI_DRDY <= MI_RD;
            if (RESET = '1') then
                MI_DRDY <= '0';
            end if;
        end if;
    end process;

end architecture;
