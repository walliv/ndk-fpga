-- axi_pipe.vhd: per-channel AXI3 register-slice pipeline (timing-only, no CDC)
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-W-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

-- Built from the generic PIPE, one chain per AXI3 channel. PIPE_TYPE=SHREG chaining is safe:
-- OUT_DST_RDY never combinationally reaches IN_DST_RDY, so no ready/valid loop forms; added
-- latency is fine, a dropped or duplicated beat is not.
entity AXI_PIPE is
    generic (
        AXI_ADDR_WIDTH  : natural := 34;
        AXI_DATA_WIDTH  : natural := 256;
        AXI_ID_WIDTH    : natural := 6;
        AXI_LEN_WIDTH   : natural := 4;
        AXI_SIZE_WIDTH  : natural := 3;
        AXI_BURST_WIDTH : natural := 2;
        AXI_RESP_WIDTH  : natural := 2;

        -- Role selection: generate only the channels a given instance actually needs.
        WRITE_EN : boolean := true;
        READ_EN  : boolean := true;

        -- Pipe stages per channel, realized as a chain of STAGES cascaded PIPE instances (safe,
        -- see the entity-level comment on PIPE's DST_RDY above). STAGES = 0 degenerates to a
        -- direct wire-through (no PIPE instantiated).
        STAGES : natural := 1;

        DEVICE : string := "ULTRASCALE"
    );
    port (
        CLK   : in std_logic;
        RESET : in std_logic;

        -- =========================================================================================
        -- M_AXI -- faces the AXI master (upstream).
        -- =========================================================================================
        M_AXI_AWADDR  : in  std_logic_vector(AXI_ADDR_WIDTH-1 downto 0)  := (others => '0');
        M_AXI_AWID    : in  std_logic_vector(AXI_ID_WIDTH-1 downto 0)    := (others => '0');
        M_AXI_AWLEN   : in  std_logic_vector(AXI_LEN_WIDTH-1 downto 0)   := (others => '0');
        M_AXI_AWSIZE  : in  std_logic_vector(AXI_SIZE_WIDTH-1 downto 0)  := (others => '0');
        M_AXI_AWBURST : in  std_logic_vector(AXI_BURST_WIDTH-1 downto 0) := (others => '0');
        M_AXI_AWVALID : in  std_logic := '0';
        M_AXI_AWREADY : out std_logic;

        M_AXI_WDATA  : in  std_logic_vector(AXI_DATA_WIDTH-1 downto 0)   := (others => '0');
        M_AXI_WSTRB  : in  std_logic_vector((AXI_DATA_WIDTH/8)-1 downto 0) := (others => '0');
        M_AXI_WLAST  : in  std_logic := '0';
        M_AXI_WVALID : in  std_logic := '0';
        M_AXI_WREADY : out std_logic;

        M_AXI_BID    : out std_logic_vector(AXI_ID_WIDTH-1 downto 0);
        M_AXI_BRESP  : out std_logic_vector(AXI_RESP_WIDTH-1 downto 0);
        M_AXI_BVALID : out std_logic;
        M_AXI_BREADY : in  std_logic := '0';

        M_AXI_ARADDR  : in  std_logic_vector(AXI_ADDR_WIDTH-1 downto 0)  := (others => '0');
        M_AXI_ARID    : in  std_logic_vector(AXI_ID_WIDTH-1 downto 0)    := (others => '0');
        M_AXI_ARLEN   : in  std_logic_vector(AXI_LEN_WIDTH-1 downto 0)   := (others => '0');
        M_AXI_ARSIZE  : in  std_logic_vector(AXI_SIZE_WIDTH-1 downto 0)  := (others => '0');
        M_AXI_ARBURST : in  std_logic_vector(AXI_BURST_WIDTH-1 downto 0) := (others => '0');
        M_AXI_ARVALID : in  std_logic := '0';
        M_AXI_ARREADY : out std_logic;

        M_AXI_RDATA  : out std_logic_vector(AXI_DATA_WIDTH-1 downto 0);
        M_AXI_RID    : out std_logic_vector(AXI_ID_WIDTH-1 downto 0);
        M_AXI_RRESP  : out std_logic_vector(AXI_RESP_WIDTH-1 downto 0);
        M_AXI_RLAST  : out std_logic;
        M_AXI_RVALID : out std_logic;
        M_AXI_RREADY : in  std_logic := '0';

        -- =========================================================================================
        -- S_AXI -- faces the AXI slave (downstream).
        -- =========================================================================================
        S_AXI_AWADDR  : out std_logic_vector(AXI_ADDR_WIDTH-1 downto 0);
        S_AXI_AWID    : out std_logic_vector(AXI_ID_WIDTH-1 downto 0);
        S_AXI_AWLEN   : out std_logic_vector(AXI_LEN_WIDTH-1 downto 0);
        S_AXI_AWSIZE  : out std_logic_vector(AXI_SIZE_WIDTH-1 downto 0);
        S_AXI_AWBURST : out std_logic_vector(AXI_BURST_WIDTH-1 downto 0);
        S_AXI_AWVALID : out std_logic;
        S_AXI_AWREADY : in  std_logic := '0';

        S_AXI_WDATA  : out std_logic_vector(AXI_DATA_WIDTH-1 downto 0);
        S_AXI_WSTRB  : out std_logic_vector((AXI_DATA_WIDTH/8)-1 downto 0);
        S_AXI_WLAST  : out std_logic;
        S_AXI_WVALID : out std_logic;
        S_AXI_WREADY : in  std_logic := '0';

        S_AXI_BID    : in  std_logic_vector(AXI_ID_WIDTH-1 downto 0)   := (others => '0');
        S_AXI_BRESP  : in  std_logic_vector(AXI_RESP_WIDTH-1 downto 0) := (others => '0');
        S_AXI_BVALID : in  std_logic := '0';
        S_AXI_BREADY : out std_logic;

        S_AXI_ARADDR  : out std_logic_vector(AXI_ADDR_WIDTH-1 downto 0);
        S_AXI_ARID    : out std_logic_vector(AXI_ID_WIDTH-1 downto 0);
        S_AXI_ARLEN   : out std_logic_vector(AXI_LEN_WIDTH-1 downto 0);
        S_AXI_ARSIZE  : out std_logic_vector(AXI_SIZE_WIDTH-1 downto 0);
        S_AXI_ARBURST : out std_logic_vector(AXI_BURST_WIDTH-1 downto 0);
        S_AXI_ARVALID : out std_logic;
        S_AXI_ARREADY : in  std_logic := '0';

        S_AXI_RDATA  : in  std_logic_vector(AXI_DATA_WIDTH-1 downto 0)   := (others => '0');
        S_AXI_RID    : in  std_logic_vector(AXI_ID_WIDTH-1 downto 0)    := (others => '0');
        S_AXI_RRESP  : in  std_logic_vector(AXI_RESP_WIDTH-1 downto 0)  := (others => '0');
        S_AXI_RLAST  : in  std_logic := '0';
        S_AXI_RVALID : in  std_logic := '0';
        S_AXI_RREADY : out std_logic
    );
end entity;

architecture FULL of AXI_PIPE is

    constant AW_ITEM_W : natural := AXI_ADDR_WIDTH+AXI_ID_WIDTH+AXI_LEN_WIDTH+AXI_SIZE_WIDTH+AXI_BURST_WIDTH;
    constant W_ITEM_W  : natural := AXI_DATA_WIDTH+(AXI_DATA_WIDTH/8)+1;
    constant B_ITEM_W  : natural := AXI_ID_WIDTH+AXI_RESP_WIDTH;
    constant AR_ITEM_W : natural := AW_ITEM_W;
    constant R_ITEM_W  : natural := AXI_DATA_WIDTH+AXI_ID_WIDTH+AXI_RESP_WIDTH+1;

    type aw_stage_data_t is array (natural range <>) of std_logic_vector(AW_ITEM_W-1 downto 0);
    type w_stage_data_t is array (natural range <>) of std_logic_vector(W_ITEM_W-1 downto 0);
    type b_stage_data_t is array (natural range <>) of std_logic_vector(B_ITEM_W-1 downto 0);
    type ar_stage_data_t is array (natural range <>) of std_logic_vector(AR_ITEM_W-1 downto 0);
    type r_stage_data_t is array (natural range <>) of std_logic_vector(R_ITEM_W-1 downto 0);

    signal aw_data : aw_stage_data_t(0 to STAGES);
    signal aw_vld  : std_logic_vector(0 to STAGES);
    signal aw_rdy  : std_logic_vector(0 to STAGES);

    signal w_data : w_stage_data_t(0 to STAGES);
    signal w_vld  : std_logic_vector(0 to STAGES);
    signal w_rdy  : std_logic_vector(0 to STAGES);

    signal b_data : b_stage_data_t(0 to STAGES);
    signal b_vld  : std_logic_vector(0 to STAGES);
    signal b_rdy  : std_logic_vector(0 to STAGES);

    signal ar_data : ar_stage_data_t(0 to STAGES);
    signal ar_vld  : std_logic_vector(0 to STAGES);
    signal ar_rdy  : std_logic_vector(0 to STAGES);

    signal r_data : r_stage_data_t(0 to STAGES);
    signal r_vld  : std_logic_vector(0 to STAGES);
    signal r_rdy  : std_logic_vector(0 to STAGES);

begin

    -- ==================================================
    -- Write-direction channels (AW, W: master -> slave; B: slave -> master), only when WRITE_EN.
    -- ==================================================
    write_en_g : if WRITE_EN generate
        aw_data(0)    <= M_AXI_AWADDR & M_AXI_AWID & M_AXI_AWLEN & M_AXI_AWSIZE & M_AXI_AWBURST;
        aw_vld(0)     <= M_AXI_AWVALID;
        M_AXI_AWREADY <= aw_rdy(0);

        aw_stage_g : for g in 0 to STAGES-1 generate
            aw_pipe_i : entity work.PIPE
            generic map (
                DATA_WIDTH    => AW_ITEM_W,
                FAKE_PIPE     => false,
                PIPE_TYPE     => "SHREG",
                OPT           => "SRL",
                USE_OUTREG    => true,
                RESET_BY_INIT => false,
                DEVICE        => DEVICE
            )
            port map (
                CLK         => CLK,
                RESET       => RESET,
                IN_DATA     => aw_data(g),
                IN_SRC_RDY  => aw_vld(g),
                IN_DST_RDY  => aw_rdy(g),
                OUT_DATA    => aw_data(g+1),
                OUT_SRC_RDY => aw_vld(g+1),
                OUT_DST_RDY => aw_rdy(g+1)
            );
        end generate;

        S_AXI_AWADDR   <= aw_data(STAGES)(AW_ITEM_W-1 downto AW_ITEM_W-AXI_ADDR_WIDTH);
        S_AXI_AWID     <= aw_data(STAGES)(AW_ITEM_W-AXI_ADDR_WIDTH-1 downto AW_ITEM_W-AXI_ADDR_WIDTH-AXI_ID_WIDTH);
        S_AXI_AWLEN    <= aw_data(STAGES)(AXI_BURST_WIDTH+AXI_SIZE_WIDTH+AXI_LEN_WIDTH-1 downto AXI_BURST_WIDTH+AXI_SIZE_WIDTH);
        S_AXI_AWSIZE   <= aw_data(STAGES)(AXI_BURST_WIDTH+AXI_SIZE_WIDTH-1 downto AXI_BURST_WIDTH);
        S_AXI_AWBURST  <= aw_data(STAGES)(AXI_BURST_WIDTH-1 downto 0);
        S_AXI_AWVALID  <= aw_vld(STAGES);
        aw_rdy(STAGES) <= S_AXI_AWREADY;

        w_data(0)    <= M_AXI_WDATA & M_AXI_WSTRB & M_AXI_WLAST;
        w_vld(0)     <= M_AXI_WVALID;
        M_AXI_WREADY <= w_rdy(0);

        w_stage_g : for g in 0 to STAGES-1 generate
            w_pipe_i : entity work.PIPE
            generic map (
                DATA_WIDTH    => W_ITEM_W,
                FAKE_PIPE     => false,
                PIPE_TYPE     => "SHREG",
                OPT           => "SRL",
                USE_OUTREG    => true,
                RESET_BY_INIT => false,
                DEVICE        => DEVICE
            )
            port map (
                CLK         => CLK,
                RESET       => RESET,
                IN_DATA     => w_data(g),
                IN_SRC_RDY  => w_vld(g),
                IN_DST_RDY  => w_rdy(g),
                OUT_DATA    => w_data(g+1),
                OUT_SRC_RDY => w_vld(g+1),
                OUT_DST_RDY => w_rdy(g+1)
            );
        end generate;

        S_AXI_WDATA   <= w_data(STAGES)(W_ITEM_W-1 downto W_ITEM_W-AXI_DATA_WIDTH);
        S_AXI_WSTRB   <= w_data(STAGES)((AXI_DATA_WIDTH/8) downto 1);
        S_AXI_WLAST   <= w_data(STAGES)(0);
        S_AXI_WVALID  <= w_vld(STAGES);
        w_rdy(STAGES) <= S_AXI_WREADY;

        b_data(0)    <= S_AXI_BID & S_AXI_BRESP;
        b_vld(0)     <= S_AXI_BVALID;
        S_AXI_BREADY <= b_rdy(0);

        b_stage_g : for g in 0 to STAGES-1 generate
            b_pipe_i : entity work.PIPE
            generic map (
                DATA_WIDTH    => B_ITEM_W,
                FAKE_PIPE     => false,
                PIPE_TYPE     => "SHREG",
                OPT           => "SRL",
                USE_OUTREG    => true,
                RESET_BY_INIT => false,
                DEVICE        => DEVICE
            )
            port map (
                CLK         => CLK,
                RESET       => RESET,
                IN_DATA     => b_data(g),
                IN_SRC_RDY  => b_vld(g),
                IN_DST_RDY  => b_rdy(g),
                OUT_DATA    => b_data(g+1),
                OUT_SRC_RDY => b_vld(g+1),
                OUT_DST_RDY => b_rdy(g+1)
            );
        end generate;

        M_AXI_BID     <= b_data(STAGES)(B_ITEM_W-1 downto AXI_RESP_WIDTH);
        M_AXI_BRESP   <= b_data(STAGES)(AXI_RESP_WIDTH-1 downto 0);
        M_AXI_BVALID  <= b_vld(STAGES);
        b_rdy(STAGES) <= M_AXI_BREADY;
    end generate;

    write_dis_g : if not WRITE_EN generate
        M_AXI_AWREADY <= '1';
        M_AXI_WREADY  <= '1';
        M_AXI_BID     <= (others => '0');
        M_AXI_BRESP   <= (others => '0');
        M_AXI_BVALID  <= '0';

        S_AXI_AWADDR  <= (others => '0');
        S_AXI_AWID    <= (others => '0');
        S_AXI_AWLEN   <= (others => '0');
        S_AXI_AWSIZE  <= (others => '0');
        S_AXI_AWBURST <= (others => '0');
        S_AXI_AWVALID <= '0';
        S_AXI_WDATA   <= (others => '0');
        S_AXI_WSTRB   <= (others => '0');
        S_AXI_WLAST   <= '0';
        S_AXI_WVALID  <= '0';
        S_AXI_BREADY  <= '1';
    end generate;

    -- ==================================================
    -- Read-direction channels (AR: master -> slave; R: slave -> master), only when READ_EN.
    -- ==================================================
    read_en_g : if READ_EN generate
        ar_data(0)    <= M_AXI_ARADDR & M_AXI_ARID & M_AXI_ARLEN & M_AXI_ARSIZE & M_AXI_ARBURST;
        ar_vld(0)     <= M_AXI_ARVALID;
        M_AXI_ARREADY <= ar_rdy(0);

        ar_stage_g : for g in 0 to STAGES-1 generate
            ar_pipe_i : entity work.PIPE
            generic map (
                DATA_WIDTH    => AR_ITEM_W,
                FAKE_PIPE     => false,
                PIPE_TYPE     => "SHREG",
                OPT           => "SRL",
                USE_OUTREG    => true,
                RESET_BY_INIT => false,
                DEVICE        => DEVICE
            )
            port map (
                CLK         => CLK,
                RESET       => RESET,
                IN_DATA     => ar_data(g),
                IN_SRC_RDY  => ar_vld(g),
                IN_DST_RDY  => ar_rdy(g),
                OUT_DATA    => ar_data(g+1),
                OUT_SRC_RDY => ar_vld(g+1),
                OUT_DST_RDY => ar_rdy(g+1)
            );
        end generate;

        S_AXI_ARADDR   <= ar_data(STAGES)(AR_ITEM_W-1 downto AR_ITEM_W-AXI_ADDR_WIDTH);
        S_AXI_ARID     <= ar_data(STAGES)(AR_ITEM_W-AXI_ADDR_WIDTH-1 downto AR_ITEM_W-AXI_ADDR_WIDTH-AXI_ID_WIDTH);
        S_AXI_ARLEN    <= ar_data(STAGES)(AXI_BURST_WIDTH+AXI_SIZE_WIDTH+AXI_LEN_WIDTH-1 downto AXI_BURST_WIDTH+AXI_SIZE_WIDTH);
        S_AXI_ARSIZE   <= ar_data(STAGES)(AXI_BURST_WIDTH+AXI_SIZE_WIDTH-1 downto AXI_BURST_WIDTH);
        S_AXI_ARBURST  <= ar_data(STAGES)(AXI_BURST_WIDTH-1 downto 0);
        S_AXI_ARVALID  <= ar_vld(STAGES);
        ar_rdy(STAGES) <= S_AXI_ARREADY;

        r_data(0)    <= S_AXI_RDATA & S_AXI_RID & S_AXI_RRESP & S_AXI_RLAST;
        r_vld(0)     <= S_AXI_RVALID;
        S_AXI_RREADY <= r_rdy(0);

        r_stage_g : for g in 0 to STAGES-1 generate
            r_pipe_i : entity work.PIPE
            generic map (
                DATA_WIDTH    => R_ITEM_W,
                FAKE_PIPE     => false,
                PIPE_TYPE     => "SHREG",
                OPT           => "SRL",
                USE_OUTREG    => true,
                RESET_BY_INIT => false,
                DEVICE        => DEVICE
            )
            port map (
                CLK         => CLK,
                RESET       => RESET,
                IN_DATA     => r_data(g),
                IN_SRC_RDY  => r_vld(g),
                IN_DST_RDY  => r_rdy(g),
                OUT_DATA    => r_data(g+1),
                OUT_SRC_RDY => r_vld(g+1),
                OUT_DST_RDY => r_rdy(g+1)
            );
        end generate;

        M_AXI_RDATA   <= r_data(STAGES)(R_ITEM_W-1 downto R_ITEM_W-AXI_DATA_WIDTH);
        M_AXI_RID     <= r_data(STAGES)(AXI_RESP_WIDTH+AXI_ID_WIDTH downto AXI_RESP_WIDTH+1);
        M_AXI_RRESP   <= r_data(STAGES)(AXI_RESP_WIDTH downto 1);
        M_AXI_RLAST   <= r_data(STAGES)(0);
        M_AXI_RVALID  <= r_vld(STAGES);
        r_rdy(STAGES) <= M_AXI_RREADY;
    end generate;

    read_dis_g : if not READ_EN generate
        M_AXI_ARREADY <= '1';
        M_AXI_RDATA   <= (others => '0');
        M_AXI_RID     <= (others => '0');
        M_AXI_RRESP   <= (others => '0');
        M_AXI_RLAST   <= '0';
        M_AXI_RVALID  <= '0';

        S_AXI_ARADDR  <= (others => '0');
        S_AXI_ARID    <= (others => '0');
        S_AXI_ARLEN   <= (others => '0');
        S_AXI_ARSIZE  <= (others => '0');
        S_AXI_ARBURST <= (others => '0');
        S_AXI_ARVALID <= '0';
        S_AXI_RREADY  <= '1';
    end generate;

end architecture;
