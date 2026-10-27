-- pcie_ctrl_cq_tb.vhd: Cocotb top of PCIE_CTRL for the routing of CQ requests
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

-- Flat view of the CQ, CC, DMA-BAR CQ and MI32 ports of PCIE_CTRL without the PTC, driven from a single clock.
entity PCIE_CTRL_CQ_TB is
    generic (
        MFB_REGIONS     : natural := 2;
        MFB_REGION_SIZE : natural := 1;
        MFB_BLOCK_SIZE  : natural := 8;
        MFB_ITEM_WIDTH  : natural := 32;
        DMA_BAR_ENABLE  : boolean := true;
        -- TRUE: an accepted read is answered with its address. FALSE: MI_SLV_DRD and MI_SLV_DRDY answer it.
        MI_ECHO_EN      : boolean := true;
        DEVICE          : string  := "ULTRASCALE";
        ENDPOINT_TYPE   : string  := "USP"
    );
    port (
        CLK              : in  std_logic;
        RESET            : in  std_logic;

        CQ_MFB_DATA      : in  std_logic_vector(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
        CQ_MFB_META      : in  std_logic_vector(MFB_REGIONS*PCIE_CQ_META_WIDTH-1 downto 0);
        CQ_MFB_SOF       : in  std_logic_vector(MFB_REGIONS-1 downto 0);
        CQ_MFB_EOF       : in  std_logic_vector(MFB_REGIONS-1 downto 0);
        CQ_MFB_SOF_POS   : in  std_logic_vector(MFB_REGIONS*max(1,log2(MFB_REGION_SIZE))-1 downto 0);
        CQ_MFB_EOF_POS   : in  std_logic_vector(MFB_REGIONS*max(1,log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE))-1 downto 0);
        CQ_MFB_SRC_RDY   : in  std_logic;
        CQ_MFB_DST_RDY   : out std_logic;

        DCQ_MFB_DATA     : out std_logic_vector(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
        DCQ_MFB_META     : out std_logic_vector(MFB_REGIONS*PCIE_CQ_META_WIDTH-1 downto 0);
        DCQ_MFB_SOF      : out std_logic_vector(MFB_REGIONS-1 downto 0);
        DCQ_MFB_EOF      : out std_logic_vector(MFB_REGIONS-1 downto 0);
        DCQ_MFB_SOF_POS  : out std_logic_vector(MFB_REGIONS*max(1,log2(MFB_REGION_SIZE))-1 downto 0);
        DCQ_MFB_EOF_POS  : out std_logic_vector(MFB_REGIONS*max(1,log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE))-1 downto 0);
        DCQ_MFB_SRC_RDY  : out std_logic;
        DCQ_MFB_DST_RDY  : in  std_logic;

        CC_MFB_DATA      : out std_logic_vector(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
        CC_MFB_META      : out std_logic_vector(MFB_REGIONS*PCIE_CC_META_WIDTH-1 downto 0);
        CC_MFB_SOF       : out std_logic_vector(MFB_REGIONS-1 downto 0);
        CC_MFB_EOF       : out std_logic_vector(MFB_REGIONS-1 downto 0);
        CC_MFB_SOF_POS   : out std_logic_vector(MFB_REGIONS*max(1,log2(MFB_REGION_SIZE))-1 downto 0);
        CC_MFB_EOF_POS   : out std_logic_vector(MFB_REGIONS*max(1,log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE))-1 downto 0);
        CC_MFB_SRC_RDY   : out std_logic;
        CC_MFB_DST_RDY   : in  std_logic;

        MI_DWR           : out std_logic_vector(31 downto 0);
        MI_ADDR          : out std_logic_vector(31 downto 0);
        MI_BE            : out std_logic_vector(3 downto 0);
        MI_RD            : out std_logic;
        MI_WR            : out std_logic;
        MI_DRD           : out std_logic_vector(31 downto 0);
        MI_ARDY          : in  std_logic;
        MI_DRDY          : out std_logic;

        MI_SLV_DRD       : in  std_logic_vector(31 downto 0) := (others => '0');
        MI_SLV_DRDY      : in  std_logic := '0'
    );
end entity;

architecture FULL of PCIE_CTRL_CQ_TB is

    signal reset_vec     : std_logic_vector(5-1 downto 0);
    signal mi_dwr_sig    : std_logic_vector(31 downto 0);
    signal mi_addr_sig   : std_logic_vector(31 downto 0);
    signal mi_be_sig     : std_logic_vector(3 downto 0);
    signal mi_rd_sig     : std_logic;
    signal mi_wr_sig     : std_logic;
    signal mi_drd_sig    : std_logic_vector(31 downto 0);
    signal mi_drdy_sig   : std_logic;
    signal dma_cq_data   : slv_array_t(1-1 downto 0)(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
    signal dma_cq_meta   : slv_array_t(1-1 downto 0)(MFB_REGIONS*PCIE_CQ_META_WIDTH-1 downto 0);
    signal dma_cq_sof    : slv_array_t(1-1 downto 0)(MFB_REGIONS-1 downto 0);
    signal dma_cq_eof    : slv_array_t(1-1 downto 0)(MFB_REGIONS-1 downto 0);
    signal dma_cq_sof_p  : slv_array_t(1-1 downto 0)(MFB_REGIONS*max(1,log2(MFB_REGION_SIZE))-1 downto 0);
    signal dma_cq_eof_p  : slv_array_t(1-1 downto 0)(MFB_REGIONS*max(1,log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE))-1 downto 0);
    signal dma_cq_src    : std_logic_vector(1-1 downto 0);
    signal dma_cq_dst    : std_logic_vector(1-1 downto 0);
    signal dma_cc_dst    : std_logic_vector(1-1 downto 0);

begin

    reset_vec <= (others => RESET);

    pcie_ctrl_i : entity work.PCIE_CTRL
    generic map (
        CQ_MFB_REGIONS     => MFB_REGIONS,
        CQ_MFB_REGION_SIZE => MFB_REGION_SIZE,
        CQ_MFB_BLOCK_SIZE  => MFB_BLOCK_SIZE,
        CQ_MFB_ITEM_WIDTH  => MFB_ITEM_WIDTH,
        RC_MFB_REGIONS     => MFB_REGIONS,
        RC_MFB_REGION_SIZE => MFB_REGION_SIZE,
        RC_MFB_BLOCK_SIZE  => MFB_BLOCK_SIZE,
        RC_MFB_ITEM_WIDTH  => MFB_ITEM_WIDTH,
        CC_MFB_REGIONS     => MFB_REGIONS,
        CC_MFB_REGION_SIZE => MFB_REGION_SIZE,
        CC_MFB_BLOCK_SIZE  => MFB_BLOCK_SIZE,
        CC_MFB_ITEM_WIDTH  => MFB_ITEM_WIDTH,
        RQ_MFB_REGIONS     => MFB_REGIONS,
        RQ_MFB_REGION_SIZE => MFB_REGION_SIZE,
        RQ_MFB_BLOCK_SIZE  => MFB_BLOCK_SIZE,
        RQ_MFB_ITEM_WIDTH  => MFB_ITEM_WIDTH,
        DBG_ENABLE         => false,
        DMA_PORTS          => 1,
        PTC_DISABLE        => true,
        DMA_BAR_ENABLE     => DMA_BAR_ENABLE,
        ENDPOINT_TYPE      => ENDPOINT_TYPE,
        DEVICE             => DEVICE
    )
    port map (
        PCIE_CLK            => CLK,
        PCIE_RESET          => reset_vec,
        DMA_CLK             => CLK,
        DMA_RESET           => RESET,
        MI_CLK              => CLK,
        MI_RESET            => RESET,

        CTL_MAX_PAYLOAD     => "001",
        CTL_BAR_APERTURE    => std_logic_vector(to_unsigned(26, 6)),
        CTL_RCB_SIZE        => '0',
        PCIE_TAG_STATUS     => open,

        PCIE_RQ_MFB_DATA    => open,
        PCIE_RQ_MFB_META    => open,
        PCIE_RQ_MFB_SOF     => open,
        PCIE_RQ_MFB_EOF     => open,
        PCIE_RQ_MFB_SOF_POS => open,
        PCIE_RQ_MFB_EOF_POS => open,
        PCIE_RQ_MFB_SRC_RDY => open,
        PCIE_RQ_MFB_DST_RDY => '1',

        DMA_RQ_MFB_DATA     => (others => (others => '0')),
        DMA_RQ_MFB_META     => (others => (others => '0')),
        DMA_RQ_MFB_SOF      => (others => (others => '0')),
        DMA_RQ_MFB_EOF      => (others => (others => '0')),
        DMA_RQ_MFB_SOF_POS  => (others => (others => '0')),
        DMA_RQ_MFB_EOF_POS  => (others => (others => '0')),
        DMA_RQ_MFB_SRC_RDY  => (others => '0'),
        DMA_RQ_MFB_DST_RDY  => open,

        DMA_RQ_MVB_DATA     => (others => (others => '0')),
        DMA_RQ_MVB_VLD      => (others => (others => '0')),
        DMA_RQ_MVB_SRC_RDY  => (others => '0'),
        DMA_RQ_MVB_DST_RDY  => open,

        PCIE_RC_MFB_DATA    => (others => '0'),
        PCIE_RC_MFB_META    => (others => '0'),
        PCIE_RC_MFB_SOF     => (others => '0'),
        PCIE_RC_MFB_EOF     => (others => '0'),
        PCIE_RC_MFB_SOF_POS => (others => '0'),
        PCIE_RC_MFB_EOF_POS => (others => '0'),
        PCIE_RC_MFB_SRC_RDY => '0',
        PCIE_RC_MFB_DST_RDY => open,

        DMA_RC_MFB_DATA     => open,
        DMA_RC_MFB_META     => open,
        DMA_RC_MFB_SOF      => open,
        DMA_RC_MFB_EOF      => open,
        DMA_RC_MFB_SOF_POS  => open,
        DMA_RC_MFB_EOF_POS  => open,
        DMA_RC_MFB_SRC_RDY  => open,
        DMA_RC_MFB_DST_RDY  => (others => '1'),

        DMA_RC_MVB_DATA     => open,
        DMA_RC_MVB_VLD      => open,
        DMA_RC_MVB_SRC_RDY  => open,
        DMA_RC_MVB_DST_RDY  => (others => '1'),

        PCIE_CQ_MFB_DATA    => CQ_MFB_DATA,
        PCIE_CQ_MFB_META    => CQ_MFB_META,
        PCIE_CQ_MFB_SOF     => CQ_MFB_SOF,
        PCIE_CQ_MFB_EOF     => CQ_MFB_EOF,
        PCIE_CQ_MFB_SOF_POS => CQ_MFB_SOF_POS,
        PCIE_CQ_MFB_EOF_POS => CQ_MFB_EOF_POS,
        PCIE_CQ_MFB_SRC_RDY => CQ_MFB_SRC_RDY,
        PCIE_CQ_MFB_DST_RDY => CQ_MFB_DST_RDY,

        DMA_CQ_MFB_DATA     => dma_cq_data,
        DMA_CQ_MFB_META     => dma_cq_meta,
        DMA_CQ_MFB_SOF      => dma_cq_sof,
        DMA_CQ_MFB_EOF      => dma_cq_eof,
        DMA_CQ_MFB_SOF_POS  => dma_cq_sof_p,
        DMA_CQ_MFB_EOF_POS  => dma_cq_eof_p,
        DMA_CQ_MFB_SRC_RDY  => dma_cq_src,
        DMA_CQ_MFB_DST_RDY  => dma_cq_dst,

        PCIE_CC_MFB_DATA    => CC_MFB_DATA,
        PCIE_CC_MFB_META    => CC_MFB_META,
        PCIE_CC_MFB_SOF     => CC_MFB_SOF,
        PCIE_CC_MFB_EOF     => CC_MFB_EOF,
        PCIE_CC_MFB_SOF_POS => CC_MFB_SOF_POS,
        PCIE_CC_MFB_EOF_POS => CC_MFB_EOF_POS,
        PCIE_CC_MFB_SRC_RDY => CC_MFB_SRC_RDY,
        PCIE_CC_MFB_DST_RDY => CC_MFB_DST_RDY,

        DMA_CC_MFB_DATA     => (others => (others => '0')),
        DMA_CC_MFB_META     => (others => (others => '0')),
        DMA_CC_MFB_SOF      => (others => (others => '0')),
        DMA_CC_MFB_EOF      => (others => (others => '0')),
        DMA_CC_MFB_SOF_POS  => (others => (others => '0')),
        DMA_CC_MFB_EOF_POS  => (others => (others => '0')),
        DMA_CC_MFB_SRC_RDY  => (others => '0'),
        DMA_CC_MFB_DST_RDY  => dma_cc_dst,

        TELEM_PTC_BRAKE     => open,
        TELEM_STFIFO_FREE   => open,
        TELEM_TAG_FREE      => open,

        MI_DWR              => mi_dwr_sig,
        MI_ADDR             => mi_addr_sig,
        MI_BE               => mi_be_sig,
        MI_RD               => mi_rd_sig,
        MI_WR               => mi_wr_sig,
        MI_DRD              => mi_drd_sig,
        MI_ARDY             => MI_ARDY,
        MI_DRDY             => mi_drdy_sig,

        MI_DBG_DWR          => (others => '0'),
        MI_DBG_ADDR         => (others => '0'),
        MI_DBG_BE           => (others => '0'),
        MI_DBG_RD           => '0',
        MI_DBG_WR           => '0',
        MI_DBG_DRD          => open,
        MI_DBG_ARDY         => open,
        MI_DBG_DRDY         => open
    );

    DCQ_MFB_DATA    <= dma_cq_data(0);
    DCQ_MFB_META    <= dma_cq_meta(0);
    DCQ_MFB_SOF     <= dma_cq_sof(0);
    DCQ_MFB_EOF     <= dma_cq_eof(0);
    DCQ_MFB_SOF_POS <= dma_cq_sof_p(0);
    DCQ_MFB_EOF_POS <= dma_cq_eof_p(0);
    DCQ_MFB_SRC_RDY <= dma_cq_src(0);
    dma_cq_dst(0)   <= DCQ_MFB_DST_RDY;

    MI_DWR  <= mi_dwr_sig;
    MI_ADDR <= mi_addr_sig;
    MI_BE   <= mi_be_sig;
    MI_RD   <= mi_rd_sig;
    MI_WR   <= mi_wr_sig;
    MI_DRD  <= mi_drd_sig;
    MI_DRDY <= mi_drdy_sig;

    mi_echo_g : if (MI_ECHO_EN) generate
        -- The MI slave answers an accepted read in the next cycle with the address it was given.
        mi_slave_p : process (CLK)
        begin
            if (rising_edge(CLK)) then
                mi_drdy_sig <= mi_rd_sig and MI_ARDY and not RESET;
                mi_drd_sig  <= mi_addr_sig;
            end if;
        end process;
    else generate
        mi_drd_sig  <= MI_SLV_DRD;
        mi_drdy_sig <= MI_SLV_DRDY;
    end generate;

end architecture;
