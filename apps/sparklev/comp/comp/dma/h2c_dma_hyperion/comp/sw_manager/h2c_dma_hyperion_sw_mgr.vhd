-- h2c_dma_hyperion_sw_mgr.vhd: Component initializing a register file with C/S registers
-- Copyright (c) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-P-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- Note:

use work.math_pack.all;
use work.type_pack.all;

entity H2C_DMA_HYPERION_SW_MGR is
    generic (
        MI_WIDTH : natural := 32
    );
    port (
        CLK   : in std_logic;
        RESET : in std_logic;

        MI_ADDR : in  std_logic_vector(MI_WIDTH -1 downto 0);
        MI_DWR  : in  std_logic_vector(MI_WIDTH -1 downto 0);
        MI_BE   : in  std_logic_vector(MI_WIDTH/8 -1 downto 0);
        MI_RD   : in  std_logic;
        MI_WR   : in  std_logic;
        MI_DRD  : out std_logic_vector(MI_WIDTH -1 downto 0);
        MI_ARDY : out std_logic;
        MI_DRDY : out std_logic;

        PCIE_REQ_TOTAL_BYTES   : in std_logic_vector(12 downto 0);
        PCIE_RD_REQ_TOTAL_INCR : in std_logic;
        PCIE_WR_REQ_TOTAL_INCR : in std_logic;

        PCIE_CQ_MFB_SRC_RDY : in std_logic;
        PCIE_CQ_MFB_DST_RDY : in std_logic;
        PCIE_CQ_DROP_INCR  : in std_logic;
        PCIE_CQ_DROP_BYTES : in std_logic_vector(12 downto 0);

        HBM_AXI_AWVALID : in std_logic;
        HBM_AXI_AWREADY : in std_logic;

        HBM_AXI_WSTRB  : in std_logic_vector(31 downto 0);
        HBM_AXI_WVALID : in std_logic;
        HBM_AXI_WREADY : in std_logic
    );
end entity;

architecture FULL of H2C_DMA_HYPERION_SW_MGR is
    constant ADDR_LENGTH : positive := 7;
    constant CNTR_WIDTH  : positive := 64;

    constant R_CONTROL                  : natural := 0;
    constant R_STATUS                   : natural := 1;
    constant R_PCIE_WR_REQS_CNTR_L      : natural := 2;
    constant R_PCIE_WR_REQS_CNTR_H      : natural := 3;
    constant R_PCIE_WR_REQ_BYTES_CNTR_L : natural := 4;
    constant R_PCIE_WR_REQ_BYTES_CNTR_H : natural := 5;
    constant R_PCIE_RD_REQS_CNTR_L      : natural := 6;
    constant R_PCIE_RD_REQS_CNTR_H      : natural := 7;
    constant R_PCIE_RD_REQ_BYTES_CNTR_L : natural := 8;
    constant R_PCIE_RD_REQ_BYTES_CNTR_H : natural := 9;
    constant R_HBM_WR_TRS_CNTR_L        : natural := 10;
    constant R_HBM_WR_TRS_CNTR_H        : natural := 11;
    constant R_HBM_WR_BYTES_CNTR_L      : natural := 12;
    constant R_HBM_WR_BYTES_CNTR_H      : natural := 13;
    constant R_PCIE_MFB_BLOCK_CNTR_L    : natural := 14;
    constant R_PCIE_MFB_BLOCK_CNTR_H    : natural := 15;
    constant R_HBM_W_BLOCK_CNTR_L       : natural := 16;
    constant R_HBM_W_BLOCK_CNTR_H       : natural := 17;
    constant R_HBM_AW_BLOCK_CNTR_L      : natural := 18;
    constant R_HBM_AW_BLOCK_CNTR_H      : natural := 19;
    constant R_PCIE_DROP_CNTR_L         : natural := 20;
    constant R_PCIE_DROP_CNTR_H         : natural := 21;
    constant R_PCIE_DROP_BYTES_CNTR_L   : natural := 22;
    constant R_PCIE_DROP_BYTES_CNTR_H   : natural := 23;

    constant REGS : natural := 24;

    constant R_ADDRS : n_array_t(REGS-1 downto 0) := (
        R_CONTROL                       => 16#00#,
        R_STATUS                        => 16#04#,
        R_PCIE_WR_REQS_CNTR_L           => 16#08#,
        R_PCIE_WR_REQS_CNTR_H           => 16#0C#,
        R_PCIE_WR_REQ_BYTES_CNTR_L      => 16#10#,
        R_PCIE_WR_REQ_BYTES_CNTR_H      => 16#14#,
        R_PCIE_RD_REQS_CNTR_L           => 16#18#,
        R_PCIE_RD_REQS_CNTR_H           => 16#1C#,
        R_PCIE_RD_REQ_BYTES_CNTR_L      => 16#20#,
        R_PCIE_RD_REQ_BYTES_CNTR_H      => 16#24#,
        R_HBM_WR_TRS_CNTR_L             => 16#28#,
        R_HBM_WR_TRS_CNTR_H             => 16#2C#,
        R_HBM_WR_BYTES_CNTR_L           => 16#30#,
        R_HBM_WR_BYTES_CNTR_H           => 16#34#,
        R_PCIE_MFB_BLOCK_CNTR_L         => 16#38#,
        R_PCIE_MFB_BLOCK_CNTR_H         => 16#3C#,
        R_HBM_W_BLOCK_CNTR_L            => 16#40#,
        R_HBM_W_BLOCK_CNTR_H            => 16#44#,
        R_HBM_AW_BLOCK_CNTR_L           => 16#48#,
        R_HBM_AW_BLOCK_CNTR_H           => 16#4C#,
        R_PCIE_DROP_CNTR_L              => 16#50#,
        R_PCIE_DROP_CNTR_H              => 16#54#,
        R_PCIE_DROP_BYTES_CNTR_L        => 16#58#,
        R_PCIE_DROP_BYTES_CNTR_H        => 16#5C#
    );

    -- Write enable (set to False for read-only registers)
    -- Must be set to True, when the coresponding index in STROBE_EN is True
    constant WR_EN : b_array_t(REGS-1 downto 0) := (
        R_CONTROL                       => TRUE,
        R_STATUS                        => FALSE,
        R_PCIE_WR_REQS_CNTR_L           => FALSE,
        R_PCIE_WR_REQS_CNTR_H           => FALSE,
        R_PCIE_WR_REQ_BYTES_CNTR_L      => FALSE,
        R_PCIE_WR_REQ_BYTES_CNTR_H      => FALSE,
        R_PCIE_RD_REQS_CNTR_L           => FALSE,
        R_PCIE_RD_REQS_CNTR_H           => FALSE,
        R_PCIE_RD_REQ_BYTES_CNTR_L      => FALSE,
        R_PCIE_RD_REQ_BYTES_CNTR_H      => FALSE,
        R_HBM_WR_TRS_CNTR_L             => FALSE,
        R_HBM_WR_TRS_CNTR_H             => FALSE,
        R_HBM_WR_BYTES_CNTR_L           => FALSE,
        R_HBM_WR_BYTES_CNTR_H           => FALSE,
        R_PCIE_MFB_BLOCK_CNTR_L         => FALSE,
        R_PCIE_MFB_BLOCK_CNTR_H         => FALSE,
        R_HBM_W_BLOCK_CNTR_L            => FALSE,
        R_HBM_W_BLOCK_CNTR_H            => FALSE,
        R_HBM_AW_BLOCK_CNTR_L           => FALSE,
        R_HBM_AW_BLOCK_CNTR_H           => FALSE,
        R_PCIE_DROP_CNTR_L              => FALSE,
        R_PCIE_DROP_CNTR_H              => FALSE,
        R_PCIE_DROP_BYTES_CNTR_L        => FALSE,
        R_PCIE_DROP_BYTES_CNTR_H        => FALSE
    );

    constant STROBE_EN : b_array_t(REGS-1 downto 0) := (
        R_CONTROL                       => FALSE,
        R_STATUS                        => FALSE,
        R_PCIE_WR_REQS_CNTR_L           => TRUE,
        R_PCIE_WR_REQS_CNTR_H           => TRUE,
        R_PCIE_WR_REQ_BYTES_CNTR_L      => TRUE,
        R_PCIE_WR_REQ_BYTES_CNTR_H      => TRUE,
        R_PCIE_RD_REQS_CNTR_L           => TRUE,
        R_PCIE_RD_REQS_CNTR_H           => TRUE,
        R_PCIE_RD_REQ_BYTES_CNTR_L      => TRUE,
        R_PCIE_RD_REQ_BYTES_CNTR_H      => TRUE,
        R_HBM_WR_TRS_CNTR_L             => TRUE,
        R_HBM_WR_TRS_CNTR_H             => TRUE,
        R_HBM_WR_BYTES_CNTR_L           => TRUE,
        R_HBM_WR_BYTES_CNTR_H           => TRUE,
        R_PCIE_MFB_BLOCK_CNTR_L         => TRUE,
        R_PCIE_MFB_BLOCK_CNTR_H         => TRUE,
        R_HBM_W_BLOCK_CNTR_L            => TRUE,
        R_HBM_W_BLOCK_CNTR_H            => TRUE,
        R_HBM_AW_BLOCK_CNTR_L           => TRUE,
        R_HBM_AW_BLOCK_CNTR_H           => TRUE,
        R_PCIE_DROP_CNTR_L              => TRUE,
        R_PCIE_DROP_CNTR_H              => TRUE,
        R_PCIE_DROP_BYTES_CNTR_L        => TRUE,
        R_PCIE_DROP_BYTES_CNTR_H        => TRUE
    );

    constant REG_IS_CNTR : b_array_t(REGS-1 downto 0) := (
        R_CONTROL                       => FALSE,
        R_STATUS                        => FALSE,
        R_PCIE_WR_REQS_CNTR_L           => TRUE,
        R_PCIE_WR_REQS_CNTR_H           => FALSE,
        R_PCIE_WR_REQ_BYTES_CNTR_L      => TRUE,
        R_PCIE_WR_REQ_BYTES_CNTR_H      => FALSE,
        R_PCIE_RD_REQS_CNTR_L           => TRUE,
        R_PCIE_RD_REQS_CNTR_H           => FALSE,
        R_PCIE_RD_REQ_BYTES_CNTR_L      => TRUE,
        R_PCIE_RD_REQ_BYTES_CNTR_H      => FALSE,
        R_HBM_WR_TRS_CNTR_L             => TRUE,
        R_HBM_WR_TRS_CNTR_H             => FALSE,
        R_HBM_WR_BYTES_CNTR_L           => TRUE,
        R_HBM_WR_BYTES_CNTR_H           => FALSE,
        R_PCIE_MFB_BLOCK_CNTR_L         => TRUE,
        R_PCIE_MFB_BLOCK_CNTR_H         => FALSE,
        R_HBM_W_BLOCK_CNTR_L            => TRUE,
        R_HBM_W_BLOCK_CNTR_H            => FALSE,
        R_HBM_AW_BLOCK_CNTR_L           => TRUE,
        R_HBM_AW_BLOCK_CNTR_H           => FALSE,
        R_PCIE_DROP_CNTR_L              => TRUE,
        R_PCIE_DROP_CNTR_H              => FALSE,
        R_PCIE_DROP_BYTES_CNTR_L        => TRUE,
        R_PCIE_DROP_BYTES_CNTR_H        => FALSE
    );

    constant REG_WIDTH : n_array_t(REGS-1 downto 0) := (
        R_CONTROL                       => 2,
        R_STATUS                        => 3,
        R_PCIE_WR_REQS_CNTR_L           => 32,
        R_PCIE_WR_REQS_CNTR_H           => 32,
        R_PCIE_WR_REQ_BYTES_CNTR_L      => 32,
        R_PCIE_WR_REQ_BYTES_CNTR_H      => 32,
        R_PCIE_RD_REQS_CNTR_L           => 32,
        R_PCIE_RD_REQS_CNTR_H           => 32,
        R_PCIE_RD_REQ_BYTES_CNTR_L      => 32,
        R_PCIE_RD_REQ_BYTES_CNTR_H      => 32,
        R_HBM_WR_TRS_CNTR_L             => 32,
        R_HBM_WR_TRS_CNTR_H             => 32,
        R_HBM_WR_BYTES_CNTR_L           => 32,
        R_HBM_WR_BYTES_CNTR_H           => 32,
        R_PCIE_MFB_BLOCK_CNTR_L         => 32,
        R_PCIE_MFB_BLOCK_CNTR_H         => 32,
        R_HBM_W_BLOCK_CNTR_L            => 32,
        R_HBM_W_BLOCK_CNTR_H            => 32,
        R_HBM_AW_BLOCK_CNTR_L           => 32,
        R_HBM_AW_BLOCK_CNTR_H           => 32,
        R_PCIE_DROP_CNTR_L              => 32,
        R_PCIE_DROP_CNTR_H              => 32,
        R_PCIE_DROP_BYTES_CNTR_L        => 32,
        R_PCIE_DROP_BYTES_CNTR_H        => 32
    );

    -- =============================================================================================
    -- Control register fields
    -- =============================================================================================
    constant CTRL_SAMPLE_CNTRS   : natural := 0;
    constant CTRL_RST_CNTRS      : natural := 1;

    -- ============================================================================================
    -- Status register fields
    -- =============================================================================================
    constant STAT_PCIE_BLOCK    : natural := 0;
    constant STAT_HBM_W_BLOCK   : natural := 1;
    constant STAT_HBM_AW_BLOCK  : natural := 2;

    -- =============================================================================================
    -- Register array declaratiions
    -- =============================================================================================
    signal regs_arr : slv_array_t(REGS-1 downto 0)(MI_WIDTH -1 downto 0);
    signal sample_regs_ins : slv_array_t(REGS-1 downto 0)(MI_WIDTH -1 downto 0);
    signal cntr_incrs   : std_logic_vector(REGS-1 downto 0);
    signal cntr_incrs_sizes : slv_array_t(REGS-1 downto 0)(CNTR_WIDTH -1 downto 0);
    signal cntr_outs   : slv_array_t(REGS-1 downto 0)(CNTR_WIDTH -1 downto 0);

    -- =============================================================================================
    -- Miscellaneous
    -- =============================================================================================
    signal hbm_axi_wbytes     : std_logic_vector(log2(HBM_AXI_WSTRB'length+1) -1 downto 0);
    signal hbm_axi_wbytes_vld : std_logic;

    signal pcie_block   : std_logic;
    signal axi_aw_block : std_logic;
    signal axi_w_block  : std_logic;
    signal dlogger_sw_rst : std_logic;
begin
    dlogger_sw_rst <= '0';
    MI_ARDY <= MI_RD or MI_WR;

    regs_g : for reg_idx in 0 to (REGS-1) generate
        wr_en_g : if (WR_EN(reg_idx) and not REG_IS_CNTR(reg_idx)) generate
            reg_type_g : if (reg_idx = R_CONTROL) generate
                ctrl_reg_wr_p : process (CLK)
                begin
                    if (rising_edge(CLK)) then
                        if (RESET = '1' or dlogger_sw_rst = '1') then
                            regs_arr(reg_idx) <= (others => '0');
                        else
                            regs_arr(reg_idx)(CTRL_SAMPLE_CNTRS)   <= '0';
                            regs_arr(reg_idx)(CTRL_RST_CNTRS)      <= '0';

                            if (MI_ADDR(ADDR_LENGTH -1 downto 0) = std_logic_vector(to_unsigned(R_ADDRS(reg_idx), ADDR_LENGTH)) and MI_WR = '1') then
                                regs_arr(reg_idx)(REG_WIDTH(reg_idx) -1 downto 0) <= MI_DWR(REG_WIDTH(reg_idx)-1 downto 0);
                            end if;
                        end if;
                    end if;
                end process;

            else generate
                generic_reg_wr_p : process (CLK)
                begin
                    if (rising_edge(CLK)) then
                        if (RESET = '1') then
                            regs_arr(reg_idx) <= (others => '0');
                        elsif (MI_ADDR(ADDR_LENGTH -1 downto 0) = std_logic_vector(to_unsigned(R_ADDRS(reg_idx), ADDR_LENGTH)) and MI_WR = '1') then
                            regs_arr(reg_idx)(REG_WIDTH(reg_idx) -1 downto 0) <= MI_DWR(REG_WIDTH(reg_idx)-1 downto 0);
                        end if;
                    end if;
                end process;
            end generate;
        end generate;

        sample_reg_g : if (STROBE_EN(reg_idx)) generate
            cntr_sample_reg_p : process (CLK)
            begin
                if (rising_edge(CLK)) then
                    if (RESET = '1' or regs_arr(R_CONTROL)(CTRL_RST_CNTRS) = '1') then
                        regs_arr(reg_idx) <= (others => '0');
                    elsif (regs_arr(R_CONTROL)(CTRL_SAMPLE_CNTRS) = '1') then
                        regs_arr(reg_idx) <= sample_regs_ins(reg_idx);
                    end if;
                end if;
            end process;
        end generate;

        cntr_g : if (REG_IS_CNTR(reg_idx)) generate
            -- As set by REG_IS_CNTR constant, initialize only that many counters that are needed which
            -- is not the total amount of counter registers
            cntr_i : entity work.STAT_CNTR
            generic map (CNTR_WIDTH => CNTR_WIDTH)
            port map (CLK => CLK, RST => RESET or regs_arr(R_CONTROL)(CTRL_RST_CNTRS),
                CE        => cntr_incrs(reg_idx),
                INCR_VAL  => cntr_incrs_sizes(reg_idx),
                OUT_COUNT => cntr_outs(reg_idx));
        end generate;
    end generate;

    -- =============================================================================================
    -- Connecting status inputs to registers
    -- =============================================================================================
    pcie_block <= PCIE_CQ_MFB_SRC_RDY and not PCIE_CQ_MFB_DST_RDY;
    axi_aw_block <= HBM_AXI_AWVALID and not HBM_AXI_AWREADY;
    axi_w_block <= HBM_AXI_WVALID and not HBM_AXI_WREADY;

    regs_arr(R_STATUS) <= (
        STAT_PCIE_BLOCK    => pcie_block,
        STAT_HBM_AW_BLOCK  => axi_aw_block,
        STAT_HBM_W_BLOCK   => axi_w_block,
        others             => '0');

    sum_one_i : entity work.SUM_ONE
    generic map (
        INPUT_WIDTH => HBM_AXI_WSTRB'length,
        OUTPUT_WIDTH => log2(HBM_AXI_WSTRB'length+1),
        OUTPUT_REG => true
    )
    port map (
        CLK         => CLK,
        RESET       => RESET,

        DIN         => HBM_AXI_WSTRB,
        DIN_MASK    => (others => '1'),
        DIN_VLD     => HBM_AXI_WVALID and HBM_AXI_WREADY,

        DOUT        => hbm_axi_wbytes,
        DOUT_VLD    => hbm_axi_wbytes_vld
    );

    -- =============================================================================================
    -- Connecting counter increment inputs to system inputs
    -- =============================================================================================
    cntr_incrs(R_PCIE_WR_REQS_CNTR_L)               <= PCIE_WR_REQ_TOTAL_INCR;
    cntr_incrs_sizes(R_PCIE_WR_REQS_CNTR_L)         <= std_logic_vector(to_unsigned(1, CNTR_WIDTH));
    cntr_incrs(R_PCIE_WR_REQ_BYTES_CNTR_L)          <= PCIE_WR_REQ_TOTAL_INCR;
    cntr_incrs_sizes(R_PCIE_WR_REQ_BYTES_CNTR_L)    <= std_logic_vector(resize(unsigned(PCIE_REQ_TOTAL_BYTES), CNTR_WIDTH));
    cntr_incrs(R_PCIE_RD_REQS_CNTR_L)               <= PCIE_RD_REQ_TOTAL_INCR;
    cntr_incrs_sizes(R_PCIE_RD_REQS_CNTR_L)         <= std_logic_vector(to_unsigned(1, CNTR_WIDTH));
    cntr_incrs(R_PCIE_RD_REQ_BYTES_CNTR_L)          <= PCIE_RD_REQ_TOTAL_INCR;
    cntr_incrs_sizes(R_PCIE_RD_REQ_BYTES_CNTR_L)    <= std_logic_vector(resize(unsigned(PCIE_REQ_TOTAL_BYTES), CNTR_WIDTH));
    cntr_incrs(R_HBM_WR_TRS_CNTR_L)                 <= HBM_AXI_WVALID and HBM_AXI_WREADY;
    cntr_incrs_sizes(R_HBM_WR_TRS_CNTR_L)           <= std_logic_vector(to_unsigned(1, CNTR_WIDTH));
    cntr_incrs(R_HBM_WR_BYTES_CNTR_L)               <= hbm_axi_wbytes_vld;
    cntr_incrs_sizes(R_HBM_WR_BYTES_CNTR_L)         <= std_logic_vector(resize(unsigned(hbm_axi_wbytes), CNTR_WIDTH));
    cntr_incrs(R_PCIE_MFB_BLOCK_CNTR_L)             <= pcie_block;
    cntr_incrs_sizes(R_PCIE_MFB_BLOCK_CNTR_L)       <= std_logic_vector(to_unsigned(1, CNTR_WIDTH));
    cntr_incrs(R_HBM_W_BLOCK_CNTR_L)                <= axi_w_block;
    cntr_incrs_sizes(R_HBM_W_BLOCK_CNTR_L)          <= std_logic_vector(to_unsigned(1, CNTR_WIDTH));
    cntr_incrs(R_HBM_AW_BLOCK_CNTR_L)               <= axi_aw_block;
    cntr_incrs_sizes(R_HBM_AW_BLOCK_CNTR_L)         <= std_logic_vector(to_unsigned(1, CNTR_WIDTH));
    cntr_incrs(R_PCIE_DROP_CNTR_L)                  <= PCIE_CQ_DROP_INCR;
    cntr_incrs_sizes(R_PCIE_DROP_CNTR_L)            <= std_logic_vector(to_unsigned(1, CNTR_WIDTH));
    cntr_incrs(R_PCIE_DROP_BYTES_CNTR_L)            <= PCIE_CQ_DROP_INCR;
    cntr_incrs_sizes(R_PCIE_DROP_BYTES_CNTR_L)      <= std_logic_vector(resize(unsigned(PCIE_CQ_DROP_BYTES), CNTR_WIDTH));

    -- =============================================================================================
    -- Connecting sample register input to system inputs
    -- =============================================================================================
    (sample_regs_ins(R_PCIE_WR_REQS_CNTR_H), sample_regs_ins(R_PCIE_WR_REQS_CNTR_L))        <= cntr_outs(R_PCIE_WR_REQS_CNTR_L);
    (sample_regs_ins(R_PCIE_WR_REQ_BYTES_CNTR_H), sample_regs_ins(R_PCIE_WR_REQ_BYTES_CNTR_L)) <= cntr_outs(R_PCIE_WR_REQ_BYTES_CNTR_L);
    (sample_regs_ins(R_PCIE_RD_REQS_CNTR_H), sample_regs_ins(R_PCIE_RD_REQS_CNTR_L))        <= cntr_outs(R_PCIE_RD_REQS_CNTR_L);
    (sample_regs_ins(R_PCIE_RD_REQ_BYTES_CNTR_H), sample_regs_ins(R_PCIE_RD_REQ_BYTES_CNTR_L)) <= cntr_outs(R_PCIE_RD_REQ_BYTES_CNTR_L);
    (sample_regs_ins(R_HBM_WR_TRS_CNTR_H), sample_regs_ins(R_HBM_WR_TRS_CNTR_L))            <= cntr_outs(R_HBM_WR_TRS_CNTR_L);
    (sample_regs_ins(R_HBM_WR_BYTES_CNTR_H), sample_regs_ins(R_HBM_WR_BYTES_CNTR_L))        <= cntr_outs(R_HBM_WR_BYTES_CNTR_L);
    (sample_regs_ins(R_PCIE_MFB_BLOCK_CNTR_H), sample_regs_ins(R_PCIE_MFB_BLOCK_CNTR_L))    <= cntr_outs(R_PCIE_MFB_BLOCK_CNTR_L);
    (sample_regs_ins(R_HBM_W_BLOCK_CNTR_H), sample_regs_ins(R_HBM_W_BLOCK_CNTR_L))          <= cntr_outs(R_HBM_W_BLOCK_CNTR_L);
    (sample_regs_ins(R_HBM_AW_BLOCK_CNTR_H), sample_regs_ins(R_HBM_AW_BLOCK_CNTR_L))        <= cntr_outs(R_HBM_AW_BLOCK_CNTR_L);
    (sample_regs_ins(R_PCIE_DROP_CNTR_H), sample_regs_ins(R_PCIE_DROP_CNTR_L))                   <= cntr_outs(R_PCIE_DROP_CNTR_L);
    (sample_regs_ins(R_PCIE_DROP_BYTES_CNTR_H), sample_regs_ins(R_PCIE_DROP_BYTES_CNTR_L)) <= cntr_outs(R_PCIE_DROP_BYTES_CNTR_L);

    -- =============================================================================================
    -- Selecting registers to READ
    -- =============================================================================================
    read_from_regs_p : process (CLK)
        variable reg_sel_addr : std_logic_vector(ADDR_LENGTH - 1 downto 0);
    begin
        if (rising_edge(CLK)) then
            MI_DRD <= (others => '0');

            reg_sel_addr := MI_ADDR(ADDR_LENGTH - 1 downto 0);

            for reg_idx in 0 to (REGS-1) loop
                if (reg_sel_addr = std_logic_vector(to_unsigned(R_ADDRS(reg_idx), ADDR_LENGTH))) then
                    MI_DRD(REG_WIDTH(reg_idx)-1 downto 0) <= regs_arr(reg_idx)(REG_WIDTH(reg_idx)-1 downto 0);
                end if;
            end loop;
        end if;
    end process;

    drdy_reg_p : process (CLK)
    begin
        if (rising_edge(CLK)) then
            if (RESET = '1') then
                MI_DRDY <= '0';
            else
                MI_DRDY <= MI_RD;
            end if;
        end if;
    end process;
end architecture;