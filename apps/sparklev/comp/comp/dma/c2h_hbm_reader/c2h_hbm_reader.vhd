-- c2h_hbm_reader.vhd: HBM AXI read engine feeding RX_DMA_CALYPTE
-- Copyright (c) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-P-2.0

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.math_pack.all;
use work.type_pack.all;

entity C2H_HBM_READER is
    generic (
        MI_WIDTH : natural := 32;

        -- HBM AXI parameters
        HBM_DATA_WIDTH  : natural := 256;
        HBM_ADDR_WIDTH  : natural := 34;
        HBM_BURST_WIDTH : natural := 2;
        HBM_ID_WIDTH    : natural := 6;
        HBM_LEN_WIDTH   : natural := 4;
        HBM_SIZE_WIDTH  : natural := 3;
        HBM_RESP_WIDTH  : natural := 2;

        -- MFB parameters (user-side)
        MFB_REGIONS     : natural := 1;
        MFB_REGION_SIZE : natural := 4;
        MFB_BLOCK_SIZE  : natural := 8;
        MFB_ITEM_WIDTH  : natural := 8;

        HDR_META_WIDTH : natural := 12;
        CHANNELS       : natural := 64;

        -- Target device for the output MFB FIFO (passed to MFB_FIFOX)
        DEVICE : string := "ULTRASCALE"
    );
    port (
        CLK   : in std_logic;
        RESET : in std_logic;

        -- =========================================================================================
        -- MI interface
        -- =========================================================================================
        MI_ADDR : in  std_logic_vector(MI_WIDTH -1 downto 0);
        MI_DWR  : in  std_logic_vector(MI_WIDTH -1 downto 0);
        MI_BE   : in  std_logic_vector(MI_WIDTH/8 -1 downto 0);
        MI_RD   : in  std_logic;
        MI_WR   : in  std_logic;
        MI_DRD  : out std_logic_vector(MI_WIDTH -1 downto 0);
        MI_ARDY : out std_logic;
        MI_DRDY : out std_logic;

        -- =========================================================================================
        -- HBM AXI read interface
        -- =========================================================================================
        HBM_AXI_ARID    : out std_logic_vector(HBM_ID_WIDTH-1 downto 0);
        HBM_AXI_ARADDR  : out std_logic_vector(HBM_ADDR_WIDTH-1 downto 0);
        HBM_AXI_ARLEN   : out std_logic_vector(HBM_LEN_WIDTH-1 downto 0);
        HBM_AXI_ARSIZE  : out std_logic_vector(HBM_SIZE_WIDTH-1 downto 0);
        HBM_AXI_ARBURST : out std_logic_vector(HBM_BURST_WIDTH-1 downto 0);
        HBM_AXI_ARVALID : out std_logic;
        HBM_AXI_ARREADY : in  std_logic;

        HBM_AXI_RID          : in  std_logic_vector(HBM_ID_WIDTH-1 downto 0);
        HBM_AXI_RDATA        : in  std_logic_vector(HBM_DATA_WIDTH-1 downto 0);
        HBM_AXI_RDATA_PARITY : in  std_logic_vector((HBM_DATA_WIDTH/8)-1 downto 0);
        HBM_AXI_RRESP        : in  std_logic_vector(HBM_RESP_WIDTH-1 downto 0);
        HBM_AXI_RLAST        : in  std_logic;
        HBM_AXI_RVALID       : in  std_logic;
        HBM_AXI_RREADY       : out std_logic;

        -- =========================================================================================
        -- USER RX MFB output
        -- =========================================================================================
        -- USER_RX_MFB_META layout:
        --   bits [log2(CHANNELS)-1 : 0]                             = CHAN (= RID low bits = top HBM addr bits)
        --   bits [HDR_META_WIDTH+log2(CHANNELS)-1 : log2(CHANNELS)] = HDR_META (= 0)
        USER_RX_MFB_META : out std_logic_vector(HDR_META_WIDTH + log2(CHANNELS) - 1 downto 0);

        USER_RX_MFB_DATA    : out std_logic_vector(MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH-1 downto 0);
        USER_RX_MFB_SOF     : out std_logic_vector(MFB_REGIONS -1 downto 0);
        USER_RX_MFB_EOF     : out std_logic_vector(MFB_REGIONS -1 downto 0);
        USER_RX_MFB_SOF_POS : out std_logic_vector(MFB_REGIONS*max(1, log2(MFB_REGION_SIZE)) -1 downto 0);
        USER_RX_MFB_EOF_POS : out std_logic_vector(MFB_REGIONS*max(1, log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE)) -1 downto 0);
        USER_RX_MFB_SRC_RDY : out std_logic;
        USER_RX_MFB_DST_RDY : in  std_logic
    );
end entity;

architecture FULL of C2H_HBM_READER is
    constant MFB_W      : natural := MFB_REGIONS*MFB_REGION_SIZE*MFB_BLOCK_SIZE*MFB_ITEM_WIDTH;
    constant MFB_BYTE_W : natural := MFB_W / 8;
    constant HBM_BYTE_W : natural := HBM_DATA_WIDTH / 8;

    constant META_WIDTH    : natural := HDR_META_WIDTH + log2(CHANNELS);
    constant SOF_POS_WIDTH : natural := MFB_REGIONS*max(1, log2(MFB_REGION_SIZE));
    constant EOF_POS_WIDTH : natural := MFB_REGIONS*max(1, log2(MFB_REGION_SIZE*MFB_BLOCK_SIZE));

    -- Output MFB FIFO depth: must be >= max AXI burst length (2**HBM_LEN_WIDTH = 16 beats).
    constant MFB_FIFO_DEPTH : natural := 2**HBM_LEN_WIDTH;

    -- Packed FIFO word: DATA & META & SOF_POS & EOF_POS & SOF & EOF (same layout as MFB_FIFOX)
    constant FIFO_WORD_W : natural :=
        MFB_W + META_WIDTH + SOF_POS_WIDTH + EOF_POS_WIDTH + MFB_REGIONS + MFB_REGIONS;

    constant ADDR_CTRL      : std_logic_vector(7 downto 0) := X"00";
    constant ADDR_STATUS    : std_logic_vector(7 downto 0) := X"04";
    constant ADDR_ADDR_L    : std_logic_vector(7 downto 0) := X"08";
    constant ADDR_ADDR_H    : std_logic_vector(7 downto 0) := X"0C";
    constant ADDR_SIZE_L    : std_logic_vector(7 downto 0) := X"10";
    constant ADDR_SIZE_H    : std_logic_vector(7 downto 0) := X"14";
    constant ADDR_REQ_CNT_L : std_logic_vector(7 downto 0) := X"18";
    constant ADDR_REQ_CNT_H : std_logic_vector(7 downto 0) := X"1C";
    constant ADDR_REQ_BYT_L : std_logic_vector(7 downto 0) := X"20";
    constant ADDR_REQ_BYT_H : std_logic_vector(7 downto 0) := X"24";

    signal start_req : std_logic;
    signal clear_done : std_logic;

    signal addr_reg  : unsigned(HBM_ADDR_WIDTH-1 downto 0);
    signal size_reg  : unsigned(63 downto 0);

    signal busy      : std_logic;
    signal done      : std_logic;
    signal error     : std_logic;
    signal range_err : std_logic;

    signal arvalid_r  : std_logic;
    signal araddr_r   : unsigned(HBM_ADDR_WIDTH-1 downto 0);
    signal arlen_r    : unsigned(HBM_LEN_WIDTH-1 downto 0);

    signal req_cnt       : unsigned(63 downto 0);
    signal req_bytes_cnt : unsigned(63 downto 0);

    signal remaining_bytes : unsigned(63 downto 0);
    signal first_beat      : std_logic;
    signal beats_left      : unsigned(HBM_LEN_WIDTH downto 0);

    signal beat_bytes_u    : unsigned(63 downto 0);
    signal burst_beats_u   : unsigned(HBM_LEN_WIDTH downto 0);

    -- =============================================================================================
    -- Output MFB FIFO (decouples AXI R channel from the USER_RX_MFB consumer)
    -- =============================================================================================
    signal beat_accept     : std_logic;

    signal fifo_rx_data    : std_logic_vector(MFB_W-1 downto 0);
    signal fifo_rx_meta    : std_logic_vector(META_WIDTH-1 downto 0);
    signal fifo_rx_sof     : std_logic_vector(MFB_REGIONS-1 downto 0);
    signal fifo_rx_eof     : std_logic_vector(MFB_REGIONS-1 downto 0);
    signal fifo_rx_sof_pos : std_logic_vector(SOF_POS_WIDTH-1 downto 0);
    signal fifo_rx_eof_pos : std_logic_vector(EOF_POS_WIDTH-1 downto 0);
    signal fifo_rx_dst_rdy : std_logic;

    signal fifo_din   : std_logic_vector(FIFO_WORD_W-1 downto 0);
    signal fifo_dout  : std_logic_vector(FIFO_WORD_W-1 downto 0);
    signal fifo_full  : std_logic;
    signal fifo_empty : std_logic;
begin
    assert (MFB_W = HBM_DATA_WIDTH)
        report "C2H_HBM_READER: MFB word width must match HBM_DATA_WIDTH."
        severity FAILURE;
    assert (MFB_REGIONS = 1)
        report "C2H_HBM_READER: only single-region MFB is supported."
        severity FAILURE;
    assert (MFB_ITEM_WIDTH = 8)
        report "C2H_HBM_READER: MFB_ITEM_WIDTH must be 8 for byte-granular EOF_POS."
        severity FAILURE;
    assert (log2(CHANNELS) <= HBM_ID_WIDTH)
        report "C2H_HBM_READER: log2(CHANNELS) must be <= HBM_ID_WIDTH."
        severity FAILURE;

    -- =============================================================================================
    -- MI slave (registered response, single-cycle ARDY) -- see H2C_DMA_HYPERION_SW_MGR
    -- =============================================================================================
    MI_ARDY <= MI_RD or MI_WR;

    start_req  <= MI_WR when MI_ADDR(7 downto 0) = ADDR_CTRL and MI_DWR(0) = '1' else '0';
    clear_done <= MI_WR when MI_ADDR(7 downto 0) = ADDR_CTRL and MI_DWR(1) = '1' else '0';

    mi_read_p : process (CLK)
    begin
        if rising_edge(CLK) then
            MI_DRD <= (others => '0');
            case MI_ADDR(7 downto 0) is
                when ADDR_CTRL =>
                    MI_DRD(0) <= busy;
                    MI_DRD(1) <= done;
                    MI_DRD(2) <= error;
                    MI_DRD(3) <= range_err;
                when ADDR_STATUS =>
                    MI_DRD(0) <= busy;
                    MI_DRD(1) <= done;
                    MI_DRD(2) <= error;
                    MI_DRD(3) <= range_err;
                when ADDR_ADDR_L =>
                    MI_DRD <= std_logic_vector(resize(addr_reg, MI_WIDTH));
                when ADDR_ADDR_H =>
                    MI_DRD(1 downto 0) <= std_logic_vector(addr_reg(HBM_ADDR_WIDTH-1 downto HBM_ADDR_WIDTH-2));
                when ADDR_SIZE_L =>
                    MI_DRD <= std_logic_vector(resize(size_reg(31 downto 0), MI_WIDTH));
                when ADDR_SIZE_H =>
                    MI_DRD <= std_logic_vector(resize(size_reg(63 downto 32), MI_WIDTH));
                when ADDR_REQ_CNT_L =>
                    MI_DRD <= std_logic_vector(req_cnt(31 downto 0));
                when ADDR_REQ_CNT_H =>
                    MI_DRD <= std_logic_vector(req_cnt(63 downto 32));
                when ADDR_REQ_BYT_L =>
                    MI_DRD <= std_logic_vector(req_bytes_cnt(31 downto 0));
                when ADDR_REQ_BYT_H =>
                    MI_DRD <= std_logic_vector(req_bytes_cnt(63 downto 32));
                when others =>
                    MI_DRD <= (others => '0');
            end case;
        end if;
    end process;

    mi_drdy_p : process (CLK)
    begin
        if rising_edge(CLK) then
            if RESET = '1' then
                MI_DRDY <= '0';
            else
                MI_DRDY <= MI_RD;
            end if;
        end if;
    end process;

    beat_bytes_u <= to_unsigned(HBM_BYTE_W, beat_bytes_u'length);

    -- A beat is accepted from AXI when: RVALID, FIFO has space, and busy.
    -- RREADY is gated identically so the AXI slave only advances when the FIFO actually writes.
    -- fifo_rx_src_rdy is tied to beat_accept so the FIFO write strobe and state-machine update
    -- are driven by exactly the same condition, keeping remaining_bytes consistent with EOF_POS.
    beat_accept <= HBM_AXI_RVALID and fifo_rx_dst_rdy when busy = '1' else '0';

    process (CLK)
        variable beats_needed     : unsigned(HBM_LEN_WIDTH downto 0);
        variable next_burst_beats : unsigned(HBM_LEN_WIDTH downto 0);
        variable rem_bytes        : unsigned(63 downto 0);
    begin
        if rising_edge(CLK) then
            if RESET = '1' then
                addr_reg        <= (others => '0');
                size_reg        <= (others => '0');
                busy            <= '0';
                done            <= '0';
                error           <= '0';
                range_err       <= '0';
                arvalid_r       <= '0';
                araddr_r        <= (others => '0');
                arlen_r         <= (others => '0');
                remaining_bytes <= (others => '0');
                first_beat      <= '0';
                beats_left      <= (others => '0');
                req_cnt         <= (others => '0');
                req_bytes_cnt   <= (others => '0');
            else
                if MI_WR = '1' then
                    case MI_ADDR(7 downto 0) is
                        when ADDR_ADDR_L =>
                            addr_reg(31 downto 0) <= unsigned(MI_DWR);
                        when ADDR_ADDR_H =>
                            addr_reg(HBM_ADDR_WIDTH-1 downto HBM_ADDR_WIDTH-2) <= unsigned(MI_DWR(1 downto 0));
                        when ADDR_SIZE_L =>
                            size_reg(31 downto 0) <= unsigned(MI_DWR);
                        when ADDR_SIZE_H =>
                            size_reg(63 downto 32) <= unsigned(MI_DWR);
                        when others =>
                            null;
                    end case;
                end if;

                if clear_done = '1' then
                    done      <= '0';
                    error     <= '0';
                    range_err <= '0';
                end if;

                if start_req = '1' and busy = '0' then
                    done      <= '0';
                    error     <= '0';
                    range_err <= '0';
                    -- Validate before issuing any read:
                    --  * non-zero size
                    --  * do not read past the end of HBM:  addr + size <= 2**HBM_ADDR_WIDTH
                    --  * do not cross the channel's 2 GB region: addr[30:0] + size <= 2**31
                    --    (ARID/CHAN follows the running address; a straddle would mis-route mid-transfer)
                    if size_reg = 0
                       or (resize(addr_reg, 65) + resize(size_reg, 65)) > shift_left(to_unsigned(1, 65), HBM_ADDR_WIDTH)
                       or (resize(addr_reg(30 downto 0), 65) + resize(size_reg, 65)) > shift_left(to_unsigned(1, 65), 31) then
                        range_err <= '1';
                        busy      <= '0';
                    else
                        remaining_bytes <= size_reg;
                        first_beat      <= '1';
                        arvalid_r       <= '0';
                        beats_left      <= (others => '0');
                        req_cnt         <= req_cnt + 1;
                        req_bytes_cnt   <= req_bytes_cnt + size_reg;
                        busy            <= '1';
                    end if;
                end if;

                if busy = '1' then
                    -- Issue a new burst only once the previous burst's data has fully drained from
                    -- the output FIFO (fifo_empty='1'); this keeps a whole burst within FIFO depth.
                    if arvalid_r = '0' and beats_left = 0 and remaining_bytes /= 0 and fifo_empty = '1' then
                        rem_bytes := remaining_bytes;
                        -- Short-circuit for full bursts: avoids overflow of the 5-bit beats_needed
                        -- when remaining_bytes exceeds 31 beats (> 992 bytes).
                        if rem_bytes >= to_unsigned(2**HBM_LEN_WIDTH * HBM_BYTE_W, rem_bytes'length) then
                            next_burst_beats := to_unsigned(2**HBM_LEN_WIDTH, next_burst_beats'length);
                        else
                            -- Partial last burst: rem_bytes < 512, fits safely in HBM_LEN_WIDTH+1 bits.
                            beats_needed := resize((rem_bytes + beat_bytes_u - 1) / beat_bytes_u, beats_needed'length);
                            if beats_needed = 0 then
                                beats_needed := to_unsigned(1, beats_needed'length);
                            end if;
                            next_burst_beats := beats_needed;
                        end if;

                        araddr_r      <= addr_reg(HBM_ADDR_WIDTH-1 downto 5) & "00000";
                        arlen_r       <= resize(next_burst_beats - 1, arlen_r'length);
                        burst_beats_u <= next_burst_beats;
                        arvalid_r     <= '1';
                    end if;

                    if arvalid_r = '1' and HBM_AXI_ARREADY = '1' then
                        arvalid_r <= '0';
                        beats_left <= burst_beats_u;
                    end if;

                    if beat_accept = '1' then
                        if HBM_AXI_RRESP /= std_logic_vector(to_unsigned(0, HBM_RESP_WIDTH)) then
                            error <= '1';
                        end if;

                        if beats_left /= 0 then
                            beats_left <= beats_left - 1;
                        end if;

                        if remaining_bytes > beat_bytes_u then
                            remaining_bytes <= remaining_bytes - beat_bytes_u;
                            addr_reg        <= addr_reg + resize(beat_bytes_u, addr_reg'length);
                            first_beat      <= '0';
                        else
                            remaining_bytes <= (others => '0');
                            addr_reg        <= addr_reg + resize(remaining_bytes, addr_reg'length);
                            busy            <= '0';
                            done            <= '1';
                            first_beat      <= '0';
                        end if;
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- Channel = top 3 HBM address bits (2 GB stride); carried in ARID[2:0], echoed as RID[2:0] -> CHAN.
    HBM_AXI_ARID    <= std_logic_vector(resize(araddr_r(HBM_ADDR_WIDTH-1 downto HBM_ADDR_WIDTH-3), HBM_ID_WIDTH));
    HBM_AXI_ARADDR  <= std_logic_vector(araddr_r);
    HBM_AXI_ARLEN   <= std_logic_vector(arlen_r);
    HBM_AXI_ARSIZE  <= std_logic_vector(to_unsigned(log2(HBM_BYTE_W), HBM_SIZE_WIDTH));
    HBM_AXI_ARBURST <= std_logic_vector(to_unsigned(1, HBM_BURST_WIDTH));
    HBM_AXI_ARVALID <= arvalid_r;

    -- RREADY follows only the FIFO's free space (never the MFB consumer); held during a transfer.
    HBM_AXI_RREADY <= fifo_rx_dst_rdy when busy = '1' else '0';

    -- =============================================================================================
    -- Build the MFB word for the returned beat and push it into the output FIFO
    -- =============================================================================================
    fifo_rx_data <= HBM_AXI_RDATA;

    fifo_rx_meta(log2(CHANNELS)-1 downto 0)            <= HBM_AXI_RID(log2(CHANNELS)-1 downto 0);
    fifo_rx_meta(META_WIDTH-1 downto log2(CHANNELS))   <= (others => '0');

    fifo_rx_sof(0) <= first_beat;
    fifo_rx_eof(0) <= '1' when remaining_bytes <= beat_bytes_u else '0';

    fifo_rx_sof_pos <= (others => '0');

    -- Concurrent assignment avoids process(all) sensitivity issues in nvc 1.21.0
    -- when variable widths are derived from entity generics (EOF_POS_WIDTH).
    fifo_rx_eof_pos <=
        (others => '0') when remaining_bytes = to_unsigned(0, remaining_bytes'length) else
        std_logic_vector(resize(remaining_bytes - 1, EOF_POS_WIDTH)) when remaining_bytes <= beat_bytes_u else
        std_logic_vector(to_unsigned(MFB_BYTE_W - 1, EOF_POS_WIDTH));

    -- Packing: DATA(MSB) & META & SOF_POS & EOF_POS & SOF & EOF(LSB)
    fifo_din <= fifo_rx_data & fifo_rx_meta & fifo_rx_sof_pos & fifo_rx_eof_pos
                & fifo_rx_sof & fifo_rx_eof;

    fifo_rx_dst_rdy <= not fifo_full;

    beat_fifo_i : entity work.C2H_BEAT_FIFO
    generic map (
        WORD_WIDTH => FIFO_WORD_W,
        DEPTH      => MFB_FIFO_DEPTH
    )
    port map (
        CLK   => CLK,
        RESET => RESET,
        DIN   => fifo_din,
        WR    => beat_accept,
        FULL  => fifo_full,
        DOUT  => fifo_dout,
        RD    => USER_RX_MFB_DST_RDY,
        EMPTY => fifo_empty
    );

    -- Unpacking (reversed from packing order)
    USER_RX_MFB_EOF     <= fifo_dout(MFB_REGIONS - 1 downto 0);
    USER_RX_MFB_SOF     <= fifo_dout(2*MFB_REGIONS - 1 downto MFB_REGIONS);
    USER_RX_MFB_EOF_POS <= fifo_dout(2*MFB_REGIONS + EOF_POS_WIDTH - 1 downto 2*MFB_REGIONS);
    USER_RX_MFB_SOF_POS <= fifo_dout(2*MFB_REGIONS + EOF_POS_WIDTH + SOF_POS_WIDTH - 1 downto
                                      2*MFB_REGIONS + EOF_POS_WIDTH);
    USER_RX_MFB_META    <= fifo_dout(2*MFB_REGIONS + EOF_POS_WIDTH + SOF_POS_WIDTH + META_WIDTH - 1 downto
                                      2*MFB_REGIONS + EOF_POS_WIDTH + SOF_POS_WIDTH);
    USER_RX_MFB_DATA    <= fifo_dout(FIFO_WORD_W - 1 downto
                                      2*MFB_REGIONS + EOF_POS_WIDTH + SOF_POS_WIDTH + META_WIDTH);

    USER_RX_MFB_SRC_RDY <= not fifo_empty;
end architecture;
