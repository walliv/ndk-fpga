-- pcie_cpm5_tx_cond.vhd: Conditions any legal MFB stream into the TLP stream the straddled CPM5 CC/RQ interfaces accept
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-W-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.math_pack.all;
use work.type_pack.all;

-- Takes any legal MFB (SRC_RDY gaps inside frames, SOF in any region) and emits every frame from region 0
-- of a fresh word, in one burst. PG346 requires both on CPM5 CC/RQ; one TLP per word trades straddling away.
entity PCIE_CPM5_TX_COND is
    generic (
        -- =======================================================================
        -- MFB BUS CONFIGURATION:
        --
        -- Supported configuration is: (4,1,8,32)
        -- =======================================================================
        MFB_REGIONS     : natural := 4;
        MFB_REGION_SIZE : natural := 1;
        MFB_BLOCK_SIZE  : natural := 8;
        MFB_ITEM_WIDTH  : natural := 32;
        -- Meta of each region, valid with SOF
        MFB_META_WIDTH  : natural := 0;
        -- Largest frame (TLP descriptor and payload) in bytes; the buffer holds two of them
        MAX_TLP_BYTES   : natural := 1024+16;
        DEVICE          : string  := "VERSAL"
    );
    port (
        CLK            : in  std_logic;
        RESET          : in  std_logic;

        RX_MFB_DATA    : in  std_logic_vector(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
        RX_MFB_META    : in  std_logic_vector(MFB_REGIONS*MFB_META_WIDTH-1 downto 0);
        RX_MFB_SOF     : in  std_logic_vector(MFB_REGIONS-1 downto 0);
        RX_MFB_EOF     : in  std_logic_vector(MFB_REGIONS-1 downto 0);
        RX_MFB_SOF_POS : in  std_logic_vector(MFB_REGIONS*max(1,log2(MFB_REGION_SIZE))-1 downto 0);
        RX_MFB_EOF_POS : in  std_logic_vector(MFB_REGIONS*max(1,log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE))-1 downto 0);
        RX_MFB_SRC_RDY : in  std_logic;
        RX_MFB_DST_RDY : out std_logic;

        -- One frame per word, starting in region 0; meta of the frame is copied to every region
        TX_MFB_DATA    : out std_logic_vector(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
        TX_MFB_META    : out std_logic_vector(MFB_REGIONS*MFB_META_WIDTH-1 downto 0);
        TX_MFB_SOF     : out std_logic_vector(MFB_REGIONS-1 downto 0);
        TX_MFB_EOF     : out std_logic_vector(MFB_REGIONS-1 downto 0);
        TX_MFB_SOF_POS : out std_logic_vector(MFB_REGIONS*max(1,log2(MFB_REGION_SIZE))-1 downto 0);
        TX_MFB_EOF_POS : out std_logic_vector(MFB_REGIONS*max(1,log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE))-1 downto 0);
        TX_MFB_SRC_RDY : out std_logic;
        TX_MFB_DST_RDY : in  std_logic
    );
end entity;

architecture FULL of PCIE_CPM5_TX_COND is

    constant WORD_BYTES    : natural := MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH/8;
    constant TLP_WORDS     : natural := (MAX_TLP_BYTES + WORD_BYTES-1)/WORD_BYTES;
    constant FIFO_DEPTH    : natural := 2**log2(2*TLP_WORDS);
    -- The whole word as one region of MFB_REGIONS blocks
    constant WORD_BLOCKS   : natural := MFB_REGIONS*MFB_REGION_SIZE;
    constant SOF_POS_W     : natural := log2(WORD_BLOCKS);
    constant EOF_POS_W     : natural := log2(WORD_BLOCKS*MFB_BLOCK_SIZE);
    constant RGN_EOF_POS_W : natural := max(1,log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE));
    -- MFB_FIFOX on LUT RAM shows a written word on TX up to 3 cycles later; a frame counts as complete
    -- only after that, so RAM_TYPE stays fixed, as AUTO could pick a memory with another latency
    constant RELEASE_DELAY : natural := 4;

    signal word_data      : std_logic_vector(TX_MFB_DATA'range);
    signal word_meta      : std_logic_vector(MFB_META_WIDTH-1 downto 0);
    signal word_sof       : std_logic_vector(0 downto 0);
    signal word_eof       : std_logic_vector(0 downto 0);
    signal word_sof_pos   : std_logic_vector(SOF_POS_W-1 downto 0);
    signal word_eof_pos   : std_logic_vector(EOF_POS_W-1 downto 0);
    signal word_src_rdy   : std_logic;
    signal word_dst_rdy   : std_logic;

    signal fifo_data      : std_logic_vector(TX_MFB_DATA'range);
    signal fifo_meta      : std_logic_vector(MFB_META_WIDTH-1 downto 0);
    signal fifo_sof       : std_logic_vector(0 downto 0);
    signal fifo_eof       : std_logic_vector(0 downto 0);
    signal fifo_sof_pos   : std_logic_vector(SOF_POS_W-1 downto 0);
    signal fifo_eof_pos   : std_logic_vector(EOF_POS_W-1 downto 0);
    signal fifo_src_rdy   : std_logic;
    signal fifo_dst_rdy   : std_logic;

    -- Frames whose EOF is in the FIFO; the head frame may leave only when it is complete
    signal frames            : unsigned(log2(FIFO_DEPTH) downto 0);
    signal frame_in          : std_logic;
    signal frame_in_dly      : std_logic_vector(RELEASE_DELAY-1 downto 0);
    signal frame_out         : std_logic;
    signal head_ready        : std_logic;

    signal aligned_sof_err : std_logic;
    signal tx_frame_open   : std_logic;
    signal tx_gap_err      : std_logic;
    signal oversize_err    : std_logic;

begin

    assert (MFB_REGION_SIZE = 1 and MFB_REGIONS > 1 and FIFO_DEPTH > TLP_WORDS)
        report "PCIE_CPM5_TX_COND: Unsupported configuration, MFB_REGION_SIZE must be 1 and MFB_REGIONS > 1"
        severity FAILURE;

    -- Merging all regions into one makes the reconfigurator align every frame to the start of a word
    align_i : entity work.MFB_RECONFIGURATOR
    generic map (
        RX_REGIONS            => MFB_REGIONS,
        RX_REGION_SIZE        => MFB_REGION_SIZE,
        RX_BLOCK_SIZE         => MFB_BLOCK_SIZE,
        RX_ITEM_WIDTH         => MFB_ITEM_WIDTH,
        TX_REGIONS            => 1,
        TX_REGION_SIZE        => WORD_BLOCKS,
        TX_BLOCK_SIZE         => MFB_BLOCK_SIZE,
        TX_ITEM_WIDTH         => MFB_ITEM_WIDTH,
        META_WIDTH            => MFB_META_WIDTH,
        META_MODE             => 0,
        FIFO_SIZE             => 32,
        FRAMES_OVER_TX_BLOCK  => 0,
        FRAMES_OVER_TX_REGION => 0,
        DEVICE                => DEVICE
    )
    port map (
        CLK        => CLK,
        RESET      => RESET,

        RX_DATA    => RX_MFB_DATA,
        RX_META    => RX_MFB_META,
        RX_SOF     => RX_MFB_SOF,
        RX_EOF     => RX_MFB_EOF,
        RX_SOF_POS => RX_MFB_SOF_POS,
        RX_EOF_POS => RX_MFB_EOF_POS,
        RX_SRC_RDY => RX_MFB_SRC_RDY,
        RX_DST_RDY => RX_MFB_DST_RDY,

        TX_DATA    => word_data,
        TX_META    => word_meta,
        TX_SOF     => word_sof,
        TX_EOF     => word_eof,
        TX_SOF_POS => word_sof_pos,
        TX_EOF_POS => word_eof_pos,
        TX_SRC_RDY => word_src_rdy,
        TX_DST_RDY => word_dst_rdy
    );

    buffer_i : entity work.MFB_FIFOX
    generic map (
        REGIONS             => 1,
        REGION_SIZE         => WORD_BLOCKS,
        BLOCK_SIZE          => MFB_BLOCK_SIZE,
        ITEM_WIDTH          => MFB_ITEM_WIDTH,
        META_WIDTH          => MFB_META_WIDTH,
        FIFO_DEPTH          => FIFO_DEPTH,
        RAM_TYPE            => "LUT",
        DEVICE              => DEVICE,
        ALMOST_FULL_OFFSET  => 1,
        ALMOST_EMPTY_OFFSET => 1
    )
    port map (
        CLK         => CLK,
        RST         => RESET,

        RX_DATA     => word_data,
        RX_META     => word_meta,
        RX_SOF_POS  => word_sof_pos,
        RX_EOF_POS  => word_eof_pos,
        RX_SOF      => word_sof,
        RX_EOF      => word_eof,
        RX_SRC_RDY  => word_src_rdy,
        RX_DST_RDY  => word_dst_rdy,

        TX_DATA     => fifo_data,
        TX_META     => fifo_meta,
        TX_SOF_POS  => fifo_sof_pos,
        TX_EOF_POS  => fifo_eof_pos,
        TX_SOF      => fifo_sof,
        TX_EOF      => fifo_eof,
        TX_SRC_RDY  => fifo_src_rdy,
        TX_DST_RDY  => fifo_dst_rdy,

        FIFO_STATUS => open,
        FIFO_AFULL  => open,
        FIFO_AEMPTY => open
    );

    frame_in  <= word_src_rdy and word_dst_rdy and word_eof(0);
    frame_out <= fifo_src_rdy and fifo_dst_rdy and fifo_eof(0);

    frames_p : process (CLK)
    begin
        if (rising_edge(CLK)) then
            frame_in_dly <= frame_in_dly(RELEASE_DELAY-2 downto 0) & frame_in;

            if (frame_in_dly(RELEASE_DELAY-1) = '1' and frame_out = '0') then
                frames <= frames + 1;
            elsif (frame_in_dly(RELEASE_DELAY-1) = '0' and frame_out = '1') then
                frames <= frames - 1;
            end if;

            if (RESET = '1') then
                frame_in_dly <= (others => '0');
                frames       <= (others => '0');
            end if;
        end if;
    end process;

    head_ready      <= '1' when (frames /= 0) else '0';
    fifo_dst_rdy    <= TX_MFB_DST_RDY and head_ready;

    -- Back to MFB_REGIONS regions: the frame starts in region 0 and ends in the region its EOF_POS names
    tx_map_g : for r in 0 to MFB_REGIONS-1 generate
        TX_MFB_EOF(r)                                                <= fifo_eof(0) when (to_integer(unsigned(fifo_eof_pos(EOF_POS_W-1 downto RGN_EOF_POS_W))) = r) else '0';
        TX_MFB_EOF_POS((r+1)*RGN_EOF_POS_W-1 downto r*RGN_EOF_POS_W) <= fifo_eof_pos(RGN_EOF_POS_W-1 downto 0);
        TX_MFB_META((r+1)*MFB_META_WIDTH-1 downto r*MFB_META_WIDTH)  <= fifo_meta;
    end generate;

    TX_MFB_DATA    <= fifo_data;
    TX_MFB_SOF     <= (0 => fifo_sof(0), others => '0');
    TX_MFB_SOF_POS <= (others => '0');
    TX_MFB_SRC_RDY <= fifo_src_rdy and head_ready;

    aligned_sof_err <= word_src_rdy and word_sof(0) and (or word_sof_pos);

    tx_frame_open_p : process (CLK)
    begin
        if (rising_edge(CLK)) then
            if (fifo_src_rdy = '1' and fifo_dst_rdy = '1') then
                tx_frame_open <= not fifo_eof(0);
            end if;
            if (RESET = '1') then
                tx_frame_open <= '0';
            end if;
        end if;
    end process;

    tx_gap_err <= tx_frame_open and not (fifo_src_rdy and head_ready);

    -- A full buffer with no complete frame, counted or on its way, can only hold a frame above MAX_TLP_BYTES: a deadlock
    oversize_err <= word_src_rdy and not word_dst_rdy and not head_ready and not (or frame_in_dly);

    -- psl default clock is rising_edge(CLK);

    -- psl tx_cond_sof_aligned :
    --      assert always (RESET = '0' -> aligned_sof_err = '0')
    --      report "PCIE_CPM5_TX_COND: reconfigurator output frame does not start at the beginning of a word";

    -- psl tx_cond_no_gap :
    --      assert always (RESET = '0' -> tx_gap_err = '0')
    --      report "PCIE_CPM5_TX_COND: output paused inside a frame";

    -- psl tx_cond_oversize :
    --      assert always (RESET = '0' -> oversize_err = '0')
    --      report "PCIE_CPM5_TX_COND: frame longer than MAX_TLP_BYTES fills the buffer, the conditioner is deadlocked";

end architecture;
