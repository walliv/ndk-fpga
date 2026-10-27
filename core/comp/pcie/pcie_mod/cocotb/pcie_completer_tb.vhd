-- pcie_completer_tb.vhd: Cocotb top of the path from the CQ and CC interfaces of an AMD PCIe IP to the MI32 bus
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-W-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.math_pack.all;
use work.type_pack.all;
use work.pcie_meta_pack.all;
use work.pcie_axi_meta_pack.all;

-- The benches of PCIE_ADAPTER and PCIE_CTRL without the PTC, with a RAM as the MI32 slave that accepts a request in about three quarters of the cycles.
entity PCIE_COMPLETER_TB is
    generic (
        MFB_REGIONS      : natural := 2;
        MFB_REGION_SIZE  : natural := 1;
        MFB_BLOCK_SIZE   : natural := 8;
        MFB_ITEM_WIDTH   : natural := 32;
        AXI_DATA_WIDTH   : natural := MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH;
        AXI_CQUSER_WIDTH : natural := AXI_CQ512_USER_W;
        AXI_CCUSER_WIDTH : natural := AXI_CC512_USER_W;
        AXI_RQUSER_WIDTH : natural := AXI_RQ512_USER_W;
        AXI_RCUSER_WIDTH : natural := AXI_RC512_USER_W;
        AXI_STRADDLING   : boolean := true;
        RAM_ITEMS        : natural := 1024
    );
    port (
        CLK              : in  std_logic;
        RESET            : in  std_logic;

        CQ_AXI_DATA      : in  std_logic_vector(AXI_DATA_WIDTH-1 downto 0);
        CQ_AXI_USER      : in  std_logic_vector(AXI_CQUSER_WIDTH-1 downto 0);
        CQ_AXI_LAST      : in  std_logic;
        CQ_AXI_KEEP      : in  std_logic_vector(AXI_DATA_WIDTH/32-1 downto 0);
        CQ_AXI_VALID     : in  std_logic;
        CQ_AXI_READY     : out std_logic;

        CC_AXI_DATA      : out std_logic_vector(AXI_DATA_WIDTH-1 downto 0);
        CC_AXI_USER      : out std_logic_vector(AXI_CCUSER_WIDTH-1 downto 0);
        CC_AXI_LAST      : out std_logic;
        CC_AXI_KEEP      : out std_logic_vector(AXI_DATA_WIDTH/32-1 downto 0);
        CC_AXI_VALID     : out std_logic;
        CC_AXI_READY     : in  std_logic
    );
end entity;

architecture FULL of PCIE_COMPLETER_TB is

    constant MFB_SOF_W  : natural := MFB_REGIONS*max(1,log2(MFB_REGION_SIZE));
    constant MFB_EOF_W  : natural := MFB_REGIONS*max(1,log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE));
    constant MFB_DATA_W : natural := MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH;

    type ram_t is array (0 to RAM_ITEMS-1) of std_logic_vector(31 downto 0);

    signal cq_mfb_data  : std_logic_vector(MFB_DATA_W-1 downto 0);
    signal cq_mfb_meta  : std_logic_vector(MFB_REGIONS*PCIE_CQ_META_WIDTH-1 downto 0);
    signal cq_mfb_sof   : std_logic_vector(MFB_REGIONS-1 downto 0);
    signal cq_mfb_eof   : std_logic_vector(MFB_REGIONS-1 downto 0);
    signal cq_mfb_sof_p : std_logic_vector(MFB_SOF_W-1 downto 0);
    signal cq_mfb_eof_p : std_logic_vector(MFB_EOF_W-1 downto 0);
    signal cq_mfb_src   : std_logic;
    signal cq_mfb_dst   : std_logic;

    signal cc_mfb_data  : std_logic_vector(MFB_DATA_W-1 downto 0);
    signal cc_mfb_meta  : std_logic_vector(MFB_REGIONS*PCIE_CC_META_WIDTH-1 downto 0);
    signal cc_mfb_sof   : std_logic_vector(MFB_REGIONS-1 downto 0);
    signal cc_mfb_eof   : std_logic_vector(MFB_REGIONS-1 downto 0);
    signal cc_mfb_sof_p : std_logic_vector(MFB_SOF_W-1 downto 0);
    signal cc_mfb_eof_p : std_logic_vector(MFB_EOF_W-1 downto 0);
    signal cc_mfb_src   : std_logic;
    signal cc_mfb_dst   : std_logic;

    signal mi_dwr       : std_logic_vector(31 downto 0);
    signal mi_addr      : std_logic_vector(31 downto 0);
    signal mi_be        : std_logic_vector(3 downto 0);
    signal mi_rd        : std_logic;
    signal mi_wr        : std_logic;
    signal mi_drd       : std_logic_vector(31 downto 0);
    signal mi_ardy      : std_logic;
    signal mi_drdy      : std_logic;

    signal lfsr         : std_logic_vector(15 downto 0);
    signal ram          : ram_t := (others => (others => '0'));

begin

    pcie_adapter_i : entity work.PCIE_ADAPTER_TB
    generic map (
        MFB_REGIONS      => MFB_REGIONS,
        MFB_REGION_SIZE  => MFB_REGION_SIZE,
        MFB_BLOCK_SIZE   => MFB_BLOCK_SIZE,
        MFB_ITEM_WIDTH   => MFB_ITEM_WIDTH,
        AXI_DATA_WIDTH   => AXI_DATA_WIDTH,
        AXI_CQUSER_WIDTH => AXI_CQUSER_WIDTH,
        AXI_CCUSER_WIDTH => AXI_CCUSER_WIDTH,
        AXI_RQUSER_WIDTH => AXI_RQUSER_WIDTH,
        AXI_RCUSER_WIDTH => AXI_RCUSER_WIDTH,
        AXI_STRADDLING   => AXI_STRADDLING
    )
    port map (
        CLK            => CLK,
        RESET          => RESET,

        CQ_AXI_DATA    => CQ_AXI_DATA,
        CQ_AXI_USER    => CQ_AXI_USER,
        CQ_AXI_LAST    => CQ_AXI_LAST,
        CQ_AXI_KEEP    => CQ_AXI_KEEP,
        CQ_AXI_VALID   => CQ_AXI_VALID,
        CQ_AXI_READY   => CQ_AXI_READY,

        CQ_MFB_DATA    => cq_mfb_data,
        CQ_MFB_META    => cq_mfb_meta,
        CQ_MFB_SOF     => cq_mfb_sof,
        CQ_MFB_EOF     => cq_mfb_eof,
        CQ_MFB_SOF_POS => cq_mfb_sof_p,
        CQ_MFB_EOF_POS => cq_mfb_eof_p,
        CQ_MFB_SRC_RDY => cq_mfb_src,
        CQ_MFB_DST_RDY => cq_mfb_dst,

        CC_MFB_DATA    => cc_mfb_data,
        CC_MFB_META    => cc_mfb_meta,
        CC_MFB_SOF     => cc_mfb_sof,
        CC_MFB_EOF     => cc_mfb_eof,
        CC_MFB_SOF_POS => cc_mfb_sof_p,
        CC_MFB_EOF_POS => cc_mfb_eof_p,
        CC_MFB_SRC_RDY => cc_mfb_src,
        CC_MFB_DST_RDY => cc_mfb_dst,

        CC_AXI_DATA    => CC_AXI_DATA,
        CC_AXI_USER    => CC_AXI_USER,
        CC_AXI_LAST    => CC_AXI_LAST,
        CC_AXI_KEEP    => CC_AXI_KEEP,
        CC_AXI_VALID   => CC_AXI_VALID,
        CC_AXI_READY   => CC_AXI_READY
    );

    pcie_ctrl_i : entity work.PCIE_CTRL_CQ_TB
    generic map (
        MFB_REGIONS     => MFB_REGIONS,
        MFB_REGION_SIZE => MFB_REGION_SIZE,
        MFB_BLOCK_SIZE  => MFB_BLOCK_SIZE,
        MFB_ITEM_WIDTH  => MFB_ITEM_WIDTH,
        DMA_BAR_ENABLE  => false,
        MI_ECHO_EN      => false,
        DEVICE          => "ULTRASCALE",
        ENDPOINT_TYPE   => "USP"
    )
    port map (
        CLK             => CLK,
        RESET           => RESET,

        CQ_MFB_DATA     => cq_mfb_data,
        CQ_MFB_META     => cq_mfb_meta,
        CQ_MFB_SOF      => cq_mfb_sof,
        CQ_MFB_EOF      => cq_mfb_eof,
        CQ_MFB_SOF_POS  => cq_mfb_sof_p,
        CQ_MFB_EOF_POS  => cq_mfb_eof_p,
        CQ_MFB_SRC_RDY  => cq_mfb_src,
        CQ_MFB_DST_RDY  => cq_mfb_dst,

        DCQ_MFB_DATA    => open,
        DCQ_MFB_META    => open,
        DCQ_MFB_SOF     => open,
        DCQ_MFB_EOF     => open,
        DCQ_MFB_SOF_POS => open,
        DCQ_MFB_EOF_POS => open,
        DCQ_MFB_SRC_RDY => open,
        DCQ_MFB_DST_RDY => '1',

        CC_MFB_DATA     => cc_mfb_data,
        CC_MFB_META     => cc_mfb_meta,
        CC_MFB_SOF      => cc_mfb_sof,
        CC_MFB_EOF      => cc_mfb_eof,
        CC_MFB_SOF_POS  => cc_mfb_sof_p,
        CC_MFB_EOF_POS  => cc_mfb_eof_p,
        CC_MFB_SRC_RDY  => cc_mfb_src,
        CC_MFB_DST_RDY  => cc_mfb_dst,

        MI_DWR          => mi_dwr,
        MI_ADDR         => mi_addr,
        MI_BE           => mi_be,
        MI_RD           => mi_rd,
        MI_WR           => mi_wr,
        MI_DRD          => open,
        MI_ARDY         => mi_ardy,
        MI_DRDY         => open,

        MI_SLV_DRD      => mi_drd,
        MI_SLV_DRDY     => mi_drdy
    );

    ardy_lfsr_i : entity work.LFSR_SIMPLE_RANDOM_GEN
    generic map (
        DATA_WIDTH => 16,
        RESET_SEED => X"ACE1"
    )
    port map (
        CLK    => CLK,
        RESET  => RESET,
        ENABLE => '1',
        DATA   => lfsr
    );

    mi_ardy <= lfsr(0) or lfsr(5);

    -- The RAM is addressed by the Dword of the MI32 address, the base of the BAR is not decoded.
    mi_slave_p : process (CLK)
        variable idx : natural range 0 to RAM_ITEMS-1;
    begin
        if (rising_edge(CLK)) then
            mi_drdy <= '0';
            idx     := to_integer(unsigned(mi_addr(log2(RAM_ITEMS)+1 downto 2)));

            if (RESET = '0' and mi_ardy = '1') then
                if (mi_wr = '1') then
                    for i in 0 to 3 loop
                        if (mi_be(i) = '1') then
                            ram(idx)(8*i+7 downto 8*i) <= mi_dwr(8*i+7 downto 8*i);
                        end if;
                    end loop;
                end if;

                if (mi_rd = '1') then
                    mi_drd  <= ram(idx);
                    mi_drdy <= '1';
                end if;
            end if;
        end if;
    end process;

end architecture;
