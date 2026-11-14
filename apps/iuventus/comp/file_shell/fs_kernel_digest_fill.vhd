-- fs_kernel_digest_fill.vhd: kernel 1, an order-independent input digest after a fill pattern
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-W-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.math_pack.all;
use work.type_pack.all;
use work.fs_pkg.all;

-- Each input word position (lane, word) owns a 64-bit sum accumulator, so no adder tree is needed
-- at line rate; after IN_END the accumulators fold into one by shifting down the chain.
entity FS_KERNEL_DIGEST_FILL is
    generic (
        LANES : natural := 2
    );
    port (
        CLK   : in    std_logic;
        RESET : in    std_logic;
        CLEAR : in    std_logic;
        START : in    std_logic;

        -- ==============================
        -- Arguments: 0x00 FILL_BYTES lo, 0x04 FILL_BYTES hi, 0x08 SEED
        -- ==============================
        S_AXIL_AWADDR  : in    std_logic_vector(FS_ARGS_ADDR_W-1 downto 0);
        S_AXIL_AWVALID : in    std_logic;
        S_AXIL_AWREADY : out   std_logic;
        S_AXIL_WDATA   : in    std_logic_vector(31 downto 0);
        S_AXIL_WSTRB   : in    std_logic_vector(3 downto 0);
        S_AXIL_WVALID  : in    std_logic;
        S_AXIL_WREADY  : out   std_logic;
        S_AXIL_BRESP   : out   std_logic_vector(1 downto 0);
        S_AXIL_BVALID  : out   std_logic;
        S_AXIL_BREADY  : in    std_logic;
        S_AXIL_ARADDR  : in    std_logic_vector(FS_ARGS_ADDR_W-1 downto 0);
        S_AXIL_ARVALID : in    std_logic;
        S_AXIL_ARREADY : out   std_logic;
        S_AXIL_RDATA   : out   std_logic_vector(31 downto 0);
        S_AXIL_RRESP   : out   std_logic_vector(1 downto 0);
        S_AXIL_RVALID  : out   std_logic;
        S_AXIL_RREADY  : in    std_logic;

        -- ==============================
        -- Input lanes, beats in any order
        -- ==============================
        IN_VLD   : in    std_logic_vector(LANES-1 downto 0);
        IN_RDY   : out   std_logic_vector(LANES-1 downto 0);
        IN_DATA  : in    slv_array_t(LANES-1 downto 0)(FS_DATA_W-1 downto 0);
        IN_BYTES : in    slv_array_t(LANES-1 downto 0)(FS_BYTES_W-1 downto 0);
        IN_FIDX  : in    slv_array_t(LANES-1 downto 0)(FS_INDEX_W-1 downto 0);
        IN_FOFS  : in    slv_array_t(LANES-1 downto 0)(FS_FOFS_W-1 downto 0);
        IN_COFS  : in    slv_array_t(LANES-1 downto 0)(FS_COFS_W-1 downto 0);
        IN_END   : in    std_logic;
        IN_FILES : in    std_logic_vector(31 downto 0);

        -- ==============================
        -- Output
        -- ==============================
        OUT_VLD   : out   std_logic;
        OUT_RDY   : in    std_logic;
        OUT_DATA  : out   std_logic_vector(FS_DATA_W-1 downto 0);
        OUT_BYTES : out   std_logic_vector(FS_BYTES_W-1 downto 0);
        OUT_LAST  : out   std_logic;

        -- Invalid job arguments (FILL_BYTES not a multiple of 64), valid from the cycle after START.
        ARG_ERR : out   std_logic
    );
end entity;

architecture FULL of FS_KERNEL_DIGEST_FILL is

    constant LANE_WORDS : natural := FS_DATA_W / 64;
    constant WORDS      : natural := LANES * LANE_WORDS;
    constant FILL_W     : natural := 64 - 6;

    type dig_state_t is (D_ACC, D_FOLD, D_DONE);

    type out_state_t is (O_IDLE, O_FILL, O_WAIT, O_REC, O_DONE);

    signal fill_lo : std_logic_vector(31 downto 0);
    signal fill_hi : std_logic_vector(31 downto 0);
    signal seed    : std_logic_vector(31 downto 0);

    signal axil_wr     : std_logic;
    signal bvalid_r    : std_logic;
    signal rvalid_r    : std_logic;
    signal rdata_r     : std_logic_vector(31 downto 0);
    signal axil_arrdy  : std_logic;

    -- Stage 1: per word c = w xor o xor (fidx << 40), zero for absent words.
    signal c_r    : u_array_t(WORDS-1 downto 0)(63 downto 0);
    signal bsum_r : unsigned(FS_BYTES_W downto 0);

    -- Stage 2: accumulators.
    signal acc_r   : u_array_t(WORDS-1 downto 0)(63 downto 0);
    signal xor_r   : unsigned(63 downto 0);
    signal total_r : unsigned(63 downto 0);
    signal files_r : std_logic_vector(31 downto 0);

    signal end_s1   : std_logic;
    signal end_s2   : std_logic;
    signal ended_r  : std_logic;
    signal dstate   : dig_state_t;
    signal fold_cnt : natural range 0 to WORDS-1;

    signal ostate     : out_state_t;
    signal fill_beats : std_logic_vector(FILL_W-1 downto 0);
    signal fill_left  : unsigned(FILL_W-1 downto 0);
    signal arg_err_r  : std_logic;
    signal jbase      : unsigned(31 downto 0);

    signal pattern   : std_logic_vector(FS_DATA_W-1 downto 0);
    signal rec_word  : std_logic_vector(FS_DATA_W-1 downto 0);
    signal out_vld_i : std_logic;

    -- Assertion helpers.
    signal in_bad        : std_logic;
    signal in_after_end  : std_logic;
    signal out_stall_r   : std_logic;
    signal out_data_r    : std_logic_vector(FS_DATA_W-1 downto 0);
    signal out_unstable  : std_logic;

begin

    assert (LANES >= 1 and LANES <= 2)
        report "FS_KERNEL_DIGEST_FILL: LANES must be 1 or 2."
        severity FAILURE;

    IN_RDY <= (others => '1');

    -- =============================================================================================
    -- AXI4-Lite argument registers
    -- =============================================================================================
    axil_wr        <= S_AXIL_AWVALID and S_AXIL_WVALID and not bvalid_r;
    axil_arrdy     <= not rvalid_r;
    S_AXIL_AWREADY <= axil_wr;
    S_AXIL_WREADY  <= axil_wr;
    S_AXIL_BRESP   <= "00";
    S_AXIL_BVALID  <= bvalid_r;
    S_AXIL_ARREADY <= axil_arrdy;
    S_AXIL_RDATA   <= rdata_r;
    S_AXIL_RRESP   <= "00";
    S_AXIL_RVALID  <= rvalid_r;

    axil_p : process (CLK) is
        variable reg_v : std_logic_vector(31 downto 0);
        variable sel_v : natural range 0 to 2**(FS_ARGS_ADDR_W-2)-1;
    begin
        if (rising_edge(CLK)) then
            if (bvalid_r = '1' and S_AXIL_BREADY = '1') then
                bvalid_r <= '0';
            end if;
            if (axil_wr = '1') then
                bvalid_r <= '1';
                sel_v    := to_integer(unsigned(S_AXIL_AWADDR(FS_ARGS_ADDR_W-1 downto 2)));
                case sel_v is
                    when 0      => reg_v := fill_lo;
                    when 1      => reg_v := fill_hi;
                    when 2      => reg_v := seed;
                    when others => reg_v := (others => '0');
                end case;
                for b in 0 to 3 loop
                    if (S_AXIL_WSTRB(b) = '1') then
                        reg_v(8*b+7 downto 8*b) := S_AXIL_WDATA(8*b+7 downto 8*b);
                    end if;
                end loop;
                case sel_v is
                    when 0      => fill_lo <= reg_v;
                    when 1      => fill_hi <= reg_v;
                    when 2      => seed    <= reg_v;
                    when others => null;
                end case;
            end if;

            if (rvalid_r = '1' and S_AXIL_RREADY = '1') then
                rvalid_r <= '0';
            end if;
            if (S_AXIL_ARVALID = '1' and axil_arrdy = '1') then
                rvalid_r <= '1';
                case to_integer(unsigned(S_AXIL_ARADDR(FS_ARGS_ADDR_W-1 downto 2))) is
                    when 0      => rdata_r <= fill_lo;
                    when 1      => rdata_r <= fill_hi;
                    when 2      => rdata_r <= seed;
                    when others => rdata_r <= (others => '0');
                end case;
            end if;

            if (RESET = '1') then
                bvalid_r <= '0';
                rvalid_r <= '0';
                rdata_r  <= (others => '0');
                fill_lo  <= (others => '0');
                fill_hi  <= (others => '0');
                seed     <= (others => '0');
            end if;
        end if;
    end process;

    -- =============================================================================================
    -- Digest
    -- =============================================================================================
    stage1_p : process (CLK) is
        variable nbytes_v : natural range 0 to 127;
        variable w_v      : unsigned(63 downto 0);
        variable o_v      : unsigned(63 downto 0);
        variable f_v      : unsigned(63 downto 0);
        variable bsum_v   : unsigned(FS_BYTES_W downto 0);
    begin
        if (rising_edge(CLK)) then
            bsum_v := (others => '0');
            for l in 0 to LANES-1 loop
                nbytes_v := to_integer(unsigned(IN_BYTES(l)));
                if (IN_VLD(l) = '1') then
                    bsum_v := bsum_v + unsigned(IN_BYTES(l));
                end if;
                for k in 0 to LANE_WORDS-1 loop
                    w_v := unsigned(IN_DATA(l)(64*k+63 downto 64*k));
                    for b in 0 to 7 loop
                        if (8*k + b >= nbytes_v) then
                            w_v(8*b+7 downto 8*b) := (others => '0');
                        end if;
                    end loop;
                    -- IN_FOFS is a multiple of 64, so the word offset is a concatenation, not a sum.
                    o_v := resize(unsigned(IN_FOFS(l)(FS_FOFS_W-1 downto 6)) & to_unsigned(8*k, 6), 64);
                    f_v := shift_left(resize(unsigned(IN_FIDX(l)), 64), 40);
                    if (IN_VLD(l) = '1' and 8*k < nbytes_v) then
                        c_r(l*LANE_WORDS+k) <= w_v xor o_v xor f_v;
                    else
                        c_r(l*LANE_WORDS+k) <= (others => '0');
                    end if;
                end loop;
            end loop;
            bsum_r <= bsum_v;
            end_s1 <= IN_END;
            end_s2 <= end_s1;

            if (IN_END = '1') then
                files_r <= IN_FILES;
            end if;

            if (RESET = '1') then
                end_s1 <= '0';
                end_s2 <= '0';
            end if;
        end if;
    end process;

    stage2_p : process (CLK) is
        variable x_v : unsigned(63 downto 0);
    begin
        if (rising_edge(CLK)) then
            if (dstate = D_FOLD) then
                acc_r(0) <= acc_r(0) + acc_r(1);
                for k in 1 to WORDS-2 loop
                    acc_r(k) <= acc_r(k+1);
                end loop;
                acc_r(WORDS-1) <= (others => '0');
            else
                for k in 0 to WORDS-1 loop
                    acc_r(k) <= acc_r(k) + c_r(k);
                end loop;
            end if;

            x_v := xor_r;
            for k in 0 to WORDS-1 loop
                x_v := x_v xor c_r(k);
            end loop;
            xor_r   <= x_v;
            total_r <= total_r + bsum_r;

            case dstate is
                when D_ACC =>
                    if (end_s2 = '1') then
                        dstate   <= D_FOLD;
                        fold_cnt <= WORDS-1;
                    end if;
                when D_FOLD =>
                    fold_cnt <= fold_cnt - 1;
                    if (fold_cnt = 1) then
                        dstate <= D_DONE;
                    end if;
                when D_DONE =>
                    null;
            end case;

            if (RESET = '1' or CLEAR = '1' or START = '1') then
                acc_r    <= (others => (others => '0'));
                xor_r    <= (others => '0');
                total_r  <= (others => '0');
                dstate   <= D_ACC;
                fold_cnt <= 0;
            end if;
        end if;
    end process;

    -- =============================================================================================
    -- Output: FILL_BYTES of pattern, then the 32 B record
    -- =============================================================================================
    out_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            case ostate is
                when O_IDLE =>
                    null;
                when O_FILL =>
                    if (OUT_RDY = '1') then
                        fill_left <= fill_left - 1;
                        jbase     <= jbase + LANE_WORDS;
                        if (fill_left = 1) then
                            ostate <= O_WAIT;
                        end if;
                    end if;
                when O_WAIT =>
                    if (dstate = D_DONE) then
                        ostate <= O_REC;
                    end if;
                when O_REC =>
                    if (OUT_RDY = '1') then
                        ostate <= O_DONE;
                    end if;
                when O_DONE =>
                    null;
            end case;

            -- With invalid arguments only the record is sent, after IN_END, so the shell can drain.
            if (START = '1') then
                fill_left <= unsigned(fill_beats);
                jbase     <= (others => '0');
                arg_err_r <= '0';
                if (unsigned(fill_lo(5 downto 0)) /= 0) then
                    arg_err_r <= '1';
                    ostate    <= O_WAIT;
                elsif (unsigned(fill_beats) /= 0) then
                    ostate <= O_FILL;
                else
                    ostate <= O_WAIT;
                end if;
            end if;

            if (RESET = '1' or CLEAR = '1') then
                arg_err_r <= '0';
                ostate    <= O_IDLE;
                fill_left <= (others => '0');
                jbase     <= (others => '0');
            end if;
        end if;
    end process;

    fill_beats <= fill_hi & fill_lo(31 downto 6);

    -- jbase is a multiple of 8, so word j = jbase + k needs no adder.
    pattern_g : for k in 0 to LANE_WORDS-1 generate
        constant K_V      : std_logic_vector(2 downto 0) := std_logic_vector(to_unsigned(k, 3));
        signal   j_word   : std_logic_vector(31 downto 0);
    begin
        j_word                             <= std_logic_vector(jbase(31 downto 3)) & K_V;
        pattern(64*k+31 downto 64*k)       <= j_word;
        pattern(64*k+63 downto 64*k+32)    <= j_word xor seed;
    end generate;

    rec_word(63 downto 0)            <= std_logic_vector(total_r);
    rec_word(127 downto 64)          <= std_logic_vector(acc_r(0));
    rec_word(191 downto 128)         <= std_logic_vector(xor_r);
    rec_word(223 downto 192)         <= files_r;
    rec_word(255 downto 224)         <= FS_DIGEST_MAGIC;
    rec_word(FS_DATA_W-1 downto 256) <= (others => '0');

    out_vld_i <= '1' when (ostate = O_FILL or ostate = O_REC) else '0';

    OUT_VLD   <= out_vld_i;
    OUT_DATA  <= rec_word when (ostate = O_REC) else pattern;
    OUT_BYTES <= std_logic_vector(to_unsigned(32, FS_BYTES_W)) when (ostate = O_REC) else
                 std_logic_vector(to_unsigned(64, FS_BYTES_W));
    OUT_LAST  <= '1' when (ostate = O_REC) else '0';
    ARG_ERR   <= arg_err_r;

    -- =============================================================================================
    -- Assertions
    -- =============================================================================================
    in_check_p : process (all) is
        variable bad_v : std_logic;
        variable vld_v : std_logic;
    begin
        bad_v := '0';
        vld_v := '0';
        for l in 0 to LANES-1 loop
            if (IN_VLD(l) = '1') then
                vld_v := '1';
                if (unsigned(IN_BYTES(l)) = 0 or unsigned(IN_BYTES(l)) > 64 or unsigned(IN_FOFS(l)(5 downto 0)) /= 0) then
                    bad_v := '1';
                end if;
            end if;
        end loop;
        in_bad       <= bad_v;
        in_after_end <= vld_v and ended_r;
    end process;

    check_p : process (CLK) is
    begin
        if (rising_edge(CLK)) then
            if (IN_END = '1') then
                ended_r <= '1';
            end if;
            out_stall_r <= out_vld_i and not OUT_RDY;
            out_data_r  <= OUT_DATA;
            if (RESET = '1' or CLEAR = '1' or START = '1') then
                ended_r     <= '0';
                out_stall_r <= '0';
            end if;
        end if;
    end process;

    out_unstable <= '1' when (out_stall_r = '1' and (out_vld_i = '0' or out_data_r /= OUT_DATA)) else '0';

    -- psl default clock is rising_edge(CLK);

    -- psl fs_digest_in_ok : assert always
    --     ((RESET = '0') -> (in_bad = '0'))
    --     report "FS_KERNEL_DIGEST_FILL: input beat with 0 or >64 bytes or an unaligned FOFS!";

    -- psl fs_digest_in_after_end : assert always
    --     ((RESET = '0') -> (in_after_end = '0'))
    --     report "FS_KERNEL_DIGEST_FILL: input beat after IN_END!";

    -- psl fs_digest_out_stable : assert always
    --     ((RESET = '0') -> (out_unstable = '0'))
    --     report "FS_KERNEL_DIGEST_FILL: output beat changed or vanished while stalled!";

end architecture;
