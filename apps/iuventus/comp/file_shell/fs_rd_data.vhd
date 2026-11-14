-- fs_rd_data.vhd: delivers one endpoint's read frames to the kernel lanes of their streams
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-W-2.0

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.math_pack.all;
use work.type_pack.all;
use work.fs_pkg.all;

entity FS_RD_DATA is
    generic (
        STREAMS         : natural := 8;
        NUM_QUEUES      : natural := 4;
        CID_W           : natural := 16;
        -- The app's read MFB: one region of one 64-item block.
        MFB_REGION_SIZE : natural := 1;
        MFB_BLOCK_SIZE  : natural := 64
    );
    port (
        CLK   : in std_logic;
        RESET : in std_logic;
        CLEAR : in std_logic;
        -- Accept and discard every frame, deliver and report nothing.
        SINK  : in std_logic;

        -- =========================================================================================
        -- The endpoint's read stream, engine side of USER_CORE_IF_PIPE; META = {CID, QID}
        -- =========================================================================================
        RX_MFB_DATA    : in  std_logic_vector(FS_DATA_W-1 downto 0);
        RX_MFB_META    : in  std_logic_vector(max(1, log2(NUM_QUEUES))+CID_W-1 downto 0);
        RX_MFB_SOF     : in  std_logic_vector(0 downto 0);
        RX_MFB_EOF     : in  std_logic_vector(0 downto 0);
        RX_MFB_SOF_POS : in  std_logic_vector(max(1, log2(MFB_REGION_SIZE))-1 downto 0);
        RX_MFB_EOF_POS : in  std_logic_vector(log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE)-1 downto 0);
        RX_MFB_SRC_RDY : in  std_logic;
        RX_MFB_DST_RDY : out std_logic;

        -- =========================================================================================
        -- Frame contexts from FS_RD_ISSUE in frame order: {qid, cid(5:0), ctx}
        -- =========================================================================================
        XCTX_VLD  : in  std_logic;
        XCTX_DATA : in  std_logic_vector(max(1, log2(NUM_QUEUES))+FS_TAG_W+FS_CTX_W-1 downto 0);
        XCTX_RD   : out std_logic;

        -- =========================================================================================
        -- Kernel lanes of this endpoint, one per stream, sharing the payload
        -- =========================================================================================
        KIN_VLD   : out std_logic_vector(STREAMS-1 downto 0);
        KIN_RDY   : in  std_logic_vector(STREAMS-1 downto 0);
        KIN_DATA  : out std_logic_vector(FS_DATA_W-1 downto 0);
        KIN_BYTES : out std_logic_vector(FS_BYTES_W-1 downto 0);
        KIN_FIDX  : out std_logic_vector(FS_INDEX_W-1 downto 0);
        KIN_FOFS  : out std_logic_vector(FS_FOFS_W-1 downto 0);
        KIN_COFS  : out std_logic_vector(FS_COFS_W-1 downto 0);

        -- A chunk's frame is delivered: after its last beat's handshake.
        CDONE_VLD   : out std_logic_vector(STREAMS-1 downto 0);
        CDONE_FSLOT : out std_logic_vector(FS_FSLOT_W-1 downto 0);
        -- Bytes handed to a stream's kernel this cycle, for IN_BYTES.
        BYTES_VLD   : out std_logic_vector(STREAMS-1 downto 0);
        BYTES_N     : out std_logic_vector(FS_BYTES_W-1 downto 0);

        -- No frame is in progress and nothing waits for a kernel.
        IDLE : out std_logic
    );
end entity;

architecture FULL of FS_RD_DATA is

    constant QID_W    : natural := max(1, log2(NUM_QUEUES));
    constant BEAT_W   : natural := 11;
    constant EOFPOS_W : natural := log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE);

    signal xctx     : std_logic_vector(FS_CTX_W-1 downto 0);
    signal xctx_qid : std_logic_vector(QID_W-1 downto 0);
    signal xctx_tag : std_logic_vector(FS_TAG_W-1 downto 0);

    signal in_frame : std_logic;
    signal rx_rdy   : std_logic;
    signal rx_hs    : std_logic;

    -- The frame being received; the *_cur values name its next beat.
    signal cur_strm  : std_logic_vector(FS_STREAM_W-1 downto 0);
    signal cur_fslot : std_logic_vector(FS_FSLOT_W-1 downto 0);
    signal cur_fidx  : std_logic_vector(FS_INDEX_W-1 downto 0);
    signal cur_fofs  : unsigned(FS_FOFS_W-1 downto 0);
    signal cur_cofs  : unsigned(FS_COFS_W-1 downto 0);
    signal cur_rem   : unsigned(FS_VBYTES_W-1 downto 0);
    signal cur_beat  : unsigned(BEAT_W-1 downto 0);
    signal cur_last  : unsigned(BEAT_W-1 downto 0);

    -- This beat's values: from the context at SOF, from the running registers after.
    signal b_strm   : std_logic_vector(FS_STREAM_W-1 downto 0);
    signal b_fslot  : std_logic_vector(FS_FSLOT_W-1 downto 0);
    signal b_fidx   : std_logic_vector(FS_INDEX_W-1 downto 0);
    signal b_fofs   : unsigned(FS_FOFS_W-1 downto 0);
    signal b_cofs   : unsigned(FS_COFS_W-1 downto 0);
    signal b_rem    : unsigned(FS_VBYTES_W-1 downto 0);
    signal b_beat   : unsigned(BEAT_W-1 downto 0);
    signal b_last   : unsigned(BEAT_W-1 downto 0);
    signal b_has    : std_logic;
    signal b_eof    : std_logic;
    signal b_bytes  : unsigned(FS_BYTES_W-1 downto 0);
    signal ctx_last : unsigned(BEAT_W-1 downto 0);

    -- Output stage: one beat, or a bare end of frame when the frame's tail lies past VBYTES
    signal out_vld   : std_logic;
    signal out_has   : std_logic;
    signal out_eof   : std_logic;
    signal out_strm  : std_logic_vector(FS_STREAM_W-1 downto 0);
    signal out_fslot : std_logic_vector(FS_FSLOT_W-1 downto 0);
    signal out_bytes : std_logic_vector(FS_BYTES_W-1 downto 0);
    signal out_leave : std_logic;
    signal out_free  : std_logic;
    signal out_kin   : std_logic;

    signal meta_err : std_logic;
    signal sof_err  : std_logic;
    signal pos_err  : std_logic;
    signal len_err  : std_logic;
    signal xctx_err : std_logic;

begin

    xctx     <= XCTX_DATA(FS_CTX_W-1 downto 0);
    xctx_tag <= XCTX_DATA(FS_CTX_W+FS_TAG_W-1 downto FS_CTX_W);
    xctx_qid <= XCTX_DATA(FS_CTX_W+FS_TAG_W+QID_W-1 downto FS_CTX_W+FS_TAG_W);

    -- Index of the frame's last beat: a frame is ceil(VBYTES/512) whole LBAs.
    ctx_last <= resize(shift_left(shift_right(resize(unsigned(fs_ctx_vbytes_f(xctx)), BEAT_W+9) - 1, 9), 3), BEAT_W) + 7;

    -- =============================================================================================
    -- Input: a frame waits at its SOF only for its context, which its success status queued first
    -- =============================================================================================
    out_kin   <= KIN_RDY(to_integer(unsigned(out_strm)) mod STREAMS);
    out_leave <= out_vld and (SINK or not out_has or out_kin);
    out_free  <= not out_vld or out_leave;
    rx_rdy    <= out_free and (in_frame or XCTX_VLD);
    rx_hs     <= RX_MFB_SRC_RDY and rx_rdy;

    RX_MFB_DST_RDY <= rx_rdy;
    XCTX_RD        <= rx_hs and not in_frame;

    b_strm  <= cur_strm when (in_frame = '1') else fs_ctx_stream_f(xctx);
    b_fslot <= cur_fslot when (in_frame = '1') else fs_ctx_fslot_f(xctx);
    b_fidx  <= cur_fidx when (in_frame = '1') else fs_ctx_fidx_f(xctx);
    b_fofs  <= cur_fofs when (in_frame = '1') else unsigned(fs_ctx_fofs_f(xctx));
    b_cofs  <= cur_cofs when (in_frame = '1') else unsigned(fs_ctx_cofs_f(xctx));
    b_rem   <= cur_rem when (in_frame = '1') else unsigned(fs_ctx_vbytes_f(xctx));
    b_beat  <= cur_beat when (in_frame = '1') else (others => '0');
    b_last  <= cur_last when (in_frame = '1') else ctx_last;
    b_eof   <= RX_MFB_EOF(0);
    b_has   <= '1' when (b_rem /= 0) else '0';
    b_bytes <= to_unsigned(64, FS_BYTES_W) when (b_rem >= 64) else resize(b_rem, FS_BYTES_W);

    frame_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (rx_hs = '1') then
                in_frame  <= not b_eof;
                cur_strm  <= b_strm;
                cur_fslot <= b_fslot;
                cur_fidx  <= b_fidx;
                cur_fofs  <= b_fofs + 64;
                cur_cofs  <= b_cofs + 64;
                cur_rem   <= (others => '0');
                if (b_rem > 64) then
                    cur_rem <= b_rem - 64;
                end if;
                cur_beat <= b_beat + 1;
                cur_last <= b_last;
            end if;
            if (RESET = '1' or CLEAR = '1') then
                in_frame <= '0';
            end if;
        end if;
    end process;

    -- =============================================================================================
    -- Output stage: a stalled kernel holds this endpoint, nothing is dropped
    -- =============================================================================================
    out_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (out_leave = '1') then
                out_vld <= '0';
            end if;
            if (rx_hs = '1' and (b_has = '1' or b_eof = '1')) then
                out_vld   <= '1';
                out_has   <= b_has;
                out_eof   <= b_eof;
                out_strm  <= b_strm;
                out_fslot <= b_fslot;
                out_bytes <= std_logic_vector(b_bytes);
                KIN_DATA  <= RX_MFB_DATA;
                KIN_FIDX  <= b_fidx;
                KIN_FOFS  <= std_logic_vector(b_fofs);
                KIN_COFS  <= std_logic_vector(b_cofs);
            end if;
            if (RESET = '1' or CLEAR = '1') then
                out_vld <= '0';
            end if;
        end if;
    end process;

    KIN_BYTES <= out_bytes;

    kin_vld_g : for s in 0 to STREAMS-1 generate
        KIN_VLD(s) <= '1' when (out_vld = '1' and out_has = '1' and SINK = '0'
                                and to_integer(unsigned(out_strm)) mod STREAMS = s) else
                      '0';
    end generate;

    report_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            CDONE_VLD   <= (others => '0');
            BYTES_VLD   <= (others => '0');
            CDONE_FSLOT <= out_fslot;
            BYTES_N     <= out_bytes;
            if (out_leave = '1' and SINK = '0') then
                CDONE_VLD(to_integer(unsigned(out_strm)) mod STREAMS) <= out_eof;
                BYTES_VLD(to_integer(unsigned(out_strm)) mod STREAMS) <= out_has;
            end if;
            if (RESET = '1' or CLEAR = '1') then
                CDONE_VLD <= (others => '0');
                BYTES_VLD <= (others => '0');
            end if;
        end if;
    end process;

    IDLE <= not in_frame and not out_vld;

    -- =============================================================================================
    -- Assertions
    -- =============================================================================================
    meta_err <= '1' when (rx_hs = '1' and in_frame = '0'
                          and (RX_MFB_META(QID_W-1 downto 0) /= xctx_qid
                               or RX_MFB_META(QID_W+FS_TAG_W-1 downto QID_W) /= xctx_tag
                               or unsigned(RX_MFB_META(QID_W+CID_W-1 downto QID_W+FS_TAG_W)) /= 0)) else
                '0';
    sof_err  <= '1' when (rx_hs = '1' and RX_MFB_SOF(0) = in_frame) else '0';
    pos_err  <= '1' when (rx_hs = '1'
                          and ((RX_MFB_SOF(0) = '1' and unsigned(RX_MFB_SOF_POS) /= 0)
                               or (RX_MFB_EOF(0) = '1' and RX_MFB_EOF_POS /= (EOFPOS_W-1 downto 0 => '1')))) else
                '0';
    len_err  <= '1' when (rx_hs = '1' and (b_eof = '1') /= (b_beat = b_last)) else '0';
    xctx_err <= '1' when (rx_hs = '1' and in_frame = '0' and XCTX_VLD = '0') else '0';

    -- psl default clock is rising_edge(CLK);

    -- psl fs_rd_data_meta_matches_ctx : assert always (RESET = '0' -> meta_err = '0')
    --     report "FS_RD_DATA: a frame's META does not name the read its context belongs to";
    -- psl fs_rd_data_sof_at_frame_start : assert always (RESET = '0' -> sof_err = '0')
    --     report "FS_RD_DATA: SOF missing at a frame start or set inside a frame";
    -- psl fs_rd_data_whole_words : assert always (RESET = '0' -> pos_err = '0')
    --     report "FS_RD_DATA: a read frame does not start at SOF_POS 0 or end at the last EOF_POS";
    -- psl fs_rd_data_frame_length : assert always (RESET = '0' -> len_err = '0')
    --     report "FS_RD_DATA: a read frame is not ceil(VBYTES/512) LBAs long";
    -- psl fs_rd_data_ctx_present : assert always (RESET = '0' -> xctx_err = '0')
    --     report "FS_RD_DATA: a frame started without its context";

end architecture;
