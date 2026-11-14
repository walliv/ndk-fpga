-- fs_pkg.vhd: constants and field accessors shared by the file shell's components
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-W-2.0

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.math_pack.all;

package fs_pkg is

    constant FS_MAX_STREAMS : natural := 8;
    constant FS_STREAM_W    : natural := 3;

    -- =============================================================================================
    -- MI register map (byte offsets within the shell's window; the shell decodes the low 25 bits)
    -- =============================================================================================
    constant FS_MI_DECODE_W : natural := 25;

    constant FS_REG_CTRL        : natural := 16#00#;
    constant FS_REG_STATUS      : natural := 16#04#;
    constant FS_REG_STREAM_MASK : natural := 16#08#;
    constant FS_REG_VERSION     : natural := 16#0C#;
    constant FS_REG_RING_DEPTHS : natural := 16#10#;
    constant FS_REG_KERNEL_ID   : natural := 16#14#;
    constant FS_REG_STRIPE      : natural := 16#18#;

    constant FS_CTRL_START_BIT : natural := 0;
    constant FS_CTRL_ABORT_BIT : natural := 1;
    constant FS_CTRL_CLEAR_BIT : natural := 2;

    constant FS_STATUS_BUSY_BIT       : natural := 0;
    constant FS_STATUS_DONE_BIT       : natural := 1;
    constant FS_STATUS_ERR_BIT        : natural := 2;
    constant FS_STATUS_NEED_SPACE_BIT : natural := 3;

    constant FS_LAYOUT_VERSION : natural := 1;

    constant FS_STREAM_REGS_BASE   : natural := 16#100#;
    constant FS_STREAM_REGS_STRIDE : natural := 16#40#;

    constant FS_SREG_IN_FILES      : natural := 16#00#;
    constant FS_SREG_IN_TAIL       : natural := 16#08#;
    constant FS_SREG_IN_HEAD       : natural := 16#0C#;
    constant FS_SREG_OUT_TAIL      : natural := 16#10#;
    constant FS_SREG_OUT_HEAD      : natural := 16#14#;
    constant FS_SREG_OUT_BYTES_LO  : natural := 16#18#;
    constant FS_SREG_OUT_BYTES_HI  : natural := 16#1C#;
    constant FS_SREG_STREAM_STATUS : natural := 16#20#;
    constant FS_SREG_ERR_INFO      : natural := 16#24#;
    constant FS_SREG_IN_BYTES_LO   : natural := 16#28#;
    constant FS_SREG_IN_BYTES_HI   : natural := 16#2C#;

    constant FS_SSTAT_IN_DONE_BIT    : natural := 0;
    constant FS_SSTAT_OUT_DONE_BIT   : natural := 1;
    constant FS_SSTAT_NEED_SPACE_BIT : natural := 2;
    constant FS_SSTAT_ERR_BIT        : natural := 3;

    -- Kernel arguments: stream s owns FS_ARGS_BASE + s*FS_ARGS_STRIDE, forwarded over AXI4-Lite.
    constant FS_ARGS_BASE   : natural := 16#1000#;
    constant FS_ARGS_ADDR_W : natural := 9;
    constant FS_ARGS_STRIDE : natural := 2**FS_ARGS_ADDR_W;
    -- Address bits of the whole window: the stream index above one stream's own bits.
    constant FS_ARGS_WIN_W  : natural := FS_ARGS_ADDR_W + FS_STREAM_W;

    -- Ring windows. HBM byte address = MI offset - FS_RING_MI_BASE, so both windows map into the
    -- first 16 MiB of the shell's pseudo-channel.
    constant FS_RING_MI_BASE     : natural := 16#080_0000#;
    constant FS_OUT_RING_MI_BASE : natural := 16#080_0000#;
    constant FS_IN_RING_MI_BASE  : natural := 16#100_0000#;
    constant FS_RING_HBM_ADDR_W  : natural := 24;
    -- Read bursts one ring fetcher keeps in flight; FS_HBM_PORT sizes its outstanding count by it.
    constant FS_FETCH_MAX_OUT    : natural := 8;

    -- =============================================================================================
    -- Ring entry: 16 B, word k = bits 32k+31..32k, as the host writes them over MI
    -- =============================================================================================
    constant FS_ENTRY_W         : natural := 128;
    constant FS_ENT_TYPE_W      : natural := 2;
    constant FS_ENT_TYPE_EXTENT : std_logic_vector(FS_ENT_TYPE_W-1 downto 0) := "00";
    constant FS_ENT_TYPE_FILE   : std_logic_vector(FS_ENT_TYPE_W-1 downto 0) := "01";

    constant FS_LBA_W   : natural := 48;
    constant FS_COUNT_W : natural := 32;
    constant FS_SIZE_W  : natural := 64;
    constant FS_INDEX_W : natural := 32;

    -- Ring depths per stream and the address strides they make.
    constant FS_IN_RING_LOG2    : natural := 16;
    constant FS_OUT_RING_LOG2   : natural := 14;
    constant FS_IN_RING_STRIDE  : natural := FS_ENTRY_W / 8 * 2**FS_IN_RING_LOG2;
    constant FS_OUT_RING_STRIDE : natural := FS_ENTRY_W / 8 * 2**FS_OUT_RING_LOG2;

    function fs_ent_type_f (ent : std_logic_vector(FS_ENTRY_W-1 downto 0)) return std_logic_vector;
    function fs_ent_last_f (ent : std_logic_vector(FS_ENTRY_W-1 downto 0)) return std_logic;
    -- Bits 126:98 must read 0; anything else marks the entry malformed.
    function fs_ent_rsvd_ok_f (ent : std_logic_vector(FS_ENTRY_W-1 downto 0)) return boolean;
    function fs_ent_lba_f (ent : std_logic_vector(FS_ENTRY_W-1 downto 0)) return std_logic_vector;
    -- The LBA word's upper bits; an EXTENT must read 0 there.
    function fs_ent_lba_hi_f (ent : std_logic_vector(FS_ENTRY_W-1 downto 0)) return std_logic_vector;
    function fs_ent_count_f (ent : std_logic_vector(FS_ENTRY_W-1 downto 0)) return std_logic_vector;
    function fs_ent_index_f (ent : std_logic_vector(FS_ENTRY_W-1 downto 0)) return std_logic_vector;

    -- =============================================================================================
    -- Read context: what the shell must know about a chunk when its frame arrives
    -- =============================================================================================
    constant FS_FOFS_W   : natural := 48;
    constant FS_COFS_W   : natural := 64;
    -- Bytes of a chunk that lie inside its file: 1 .. 128 KiB.
    constant FS_VBYTES_W : natural := 18;
    -- Files of one stream with reads still outstanding; a FILE entry waits for a free slot.
    constant FS_FSLOT_W  : natural := 6;
    -- The DMA's per-queue tag pool holds 64 CIDs, so the low bits of a read's CID index it.
    constant FS_TAG_W    : natural := 6;

    constant FS_CTX_W : natural := FS_STREAM_W + FS_FSLOT_W + FS_INDEX_W + FS_FOFS_W + FS_COFS_W + FS_VBYTES_W;

    function fs_ctx_pack_f (stream : std_logic_vector(FS_STREAM_W-1 downto 0);
        fslot  : std_logic_vector(FS_FSLOT_W-1 downto 0);
        fidx   : std_logic_vector(FS_INDEX_W-1 downto 0);
        fofs   : std_logic_vector(FS_FOFS_W-1 downto 0);
        cofs   : std_logic_vector(FS_COFS_W-1 downto 0);
        vbytes : std_logic_vector(FS_VBYTES_W-1 downto 0)) return std_logic_vector;
    function fs_ctx_stream_f (ctx : std_logic_vector(FS_CTX_W-1 downto 0)) return std_logic_vector;
    function fs_ctx_fslot_f (ctx : std_logic_vector(FS_CTX_W-1 downto 0)) return std_logic_vector;
    function fs_ctx_fidx_f (ctx : std_logic_vector(FS_CTX_W-1 downto 0)) return std_logic_vector;
    function fs_ctx_fofs_f (ctx : std_logic_vector(FS_CTX_W-1 downto 0)) return std_logic_vector;
    function fs_ctx_cofs_f (ctx : std_logic_vector(FS_CTX_W-1 downto 0)) return std_logic_vector;
    function fs_ctx_vbytes_f (ctx : std_logic_vector(FS_CTX_W-1 downto 0)) return std_logic_vector;

    -- =============================================================================================
    -- Stripe mapping of a logical LBA (2**log2_drives drives, 2**log2_chunk LBAs per chunk)
    -- =============================================================================================
    -- log2_chunk is at most 8: a chunk never exceeds the DMA's 256-LBA read and write limit.
    constant FS_STRIPE_LOG2_W    : natural := 4;
    constant FS_MAX_LOG2_CHUNK   : natural := 8;
    constant FS_MAX_LOG2_DRIVES  : natural := 2;

    -- More drives than queues would map a drive onto no queue.
    function fs_max_log2_drives_f (num_queues : natural) return natural;

    function fs_stripe_drive_f (lba         : std_logic_vector(FS_LBA_W-1 downto 0);
        log2_drives : natural;
        log2_chunk  : natural) return natural;
    function fs_stripe_drive_lba_f (lba         : std_logic_vector(FS_LBA_W-1 downto 0);
        log2_drives : natural;
        log2_chunk  : natural) return std_logic_vector;

    -- =============================================================================================
    -- DMA operation status codes (OP_STAT_CODE)
    -- =============================================================================================
    constant FS_OP_CODE_OK   : std_logic_vector(1 downto 0) := "00";
    constant FS_OP_CODE_FAIL : std_logic_vector(1 downto 0) := "01";
    -- An LBA out of range: the status carries no command identity.
    constant FS_OP_CODE_OOR  : std_logic_vector(1 downto 0) := "10";

    -- =============================================================================================
    -- ERR_INFO
    -- =============================================================================================
    constant FS_ERR_SRC_NVME   : natural := 0;
    constant FS_ERR_SRC_FORMAT : natural := 1;
    constant FS_ERR_SRC_ABORT  : natural := 2;
    -- A non-OKAY response on the ring port: the job read or wrote ring entries that may be wrong.
    constant FS_ERR_SRC_HBM    : natural := 3;

    function fs_err_info_f (src     : natural;
        code    : std_logic_vector(1 downto 0);
        is_read : std_logic;
        drive   : std_logic_vector(3 downto 0);
        cid     : std_logic_vector(15 downto 0)) return std_logic_vector;

    -- =============================================================================================
    -- Arbitration
    -- =============================================================================================
    -- Round-robin pick: the first eligible index from ptr upward (wrapping), ptr when none is.
    function fs_rr_pick_f (eligible : std_logic_vector; ptr : natural) return natural;

    -- =============================================================================================
    -- Kernel interface
    -- =============================================================================================
    constant FS_DATA_W  : natural := 512;
    -- Valid bytes of a beat, counted from byte 0: 1 .. 64 (0 only on an empty output's last beat).
    constant FS_BYTES_W : natural := 7;

    constant FS_KERNEL_DIGEST_FILL : natural := 1;
    constant FS_DIGEST_MAGIC       : std_logic_vector(31 downto 0) := X"31474944";

end package;

package body fs_pkg is

    function fs_ent_type_f (ent : std_logic_vector(FS_ENTRY_W-1 downto 0)) return std_logic_vector is
    begin
        return ent(97 downto 96);
    end function;

    function fs_ent_last_f (ent : std_logic_vector(FS_ENTRY_W-1 downto 0)) return std_logic is
    begin
        return ent(127);
    end function;

    function fs_ent_rsvd_ok_f (ent : std_logic_vector(FS_ENTRY_W-1 downto 0)) return boolean is
    begin
        return unsigned(ent(126 downto 98)) = 0;
    end function;

    function fs_ent_lba_f (ent : std_logic_vector(FS_ENTRY_W-1 downto 0)) return std_logic_vector is
    begin
        return ent(FS_LBA_W-1 downto 0);
    end function;

    function fs_ent_lba_hi_f (ent : std_logic_vector(FS_ENTRY_W-1 downto 0)) return std_logic_vector is
    begin
        return ent(63 downto FS_LBA_W);
    end function;

    function fs_ent_count_f (ent : std_logic_vector(FS_ENTRY_W-1 downto 0)) return std_logic_vector is
    begin
        return ent(95 downto 64);
    end function;

    function fs_ent_index_f (ent : std_logic_vector(FS_ENTRY_W-1 downto 0)) return std_logic_vector is
    begin
        return ent(95 downto 64);
    end function;

    function fs_ctx_pack_f (stream : std_logic_vector(FS_STREAM_W-1 downto 0);
        fslot  : std_logic_vector(FS_FSLOT_W-1 downto 0);
        fidx   : std_logic_vector(FS_INDEX_W-1 downto 0);
        fofs   : std_logic_vector(FS_FOFS_W-1 downto 0);
        cofs   : std_logic_vector(FS_COFS_W-1 downto 0);
        vbytes : std_logic_vector(FS_VBYTES_W-1 downto 0)) return std_logic_vector is
    begin
        return stream & fslot & fidx & fofs & cofs & vbytes;
    end function;

    function fs_ctx_vbytes_f (ctx : std_logic_vector(FS_CTX_W-1 downto 0)) return std_logic_vector is
    begin
        return ctx(FS_VBYTES_W-1 downto 0);
    end function;

    function fs_ctx_cofs_f (ctx : std_logic_vector(FS_CTX_W-1 downto 0)) return std_logic_vector is
        constant LO : natural := FS_VBYTES_W;
    begin
        return ctx(LO+FS_COFS_W-1 downto LO);
    end function;

    function fs_ctx_fofs_f (ctx : std_logic_vector(FS_CTX_W-1 downto 0)) return std_logic_vector is
        constant LO : natural := FS_VBYTES_W + FS_COFS_W;
    begin
        return ctx(LO+FS_FOFS_W-1 downto LO);
    end function;

    function fs_ctx_fidx_f (ctx : std_logic_vector(FS_CTX_W-1 downto 0)) return std_logic_vector is
        constant LO : natural := FS_VBYTES_W + FS_COFS_W + FS_FOFS_W;
    begin
        return ctx(LO+FS_INDEX_W-1 downto LO);
    end function;

    function fs_ctx_fslot_f (ctx : std_logic_vector(FS_CTX_W-1 downto 0)) return std_logic_vector is
        constant LO : natural := FS_VBYTES_W + FS_COFS_W + FS_FOFS_W + FS_INDEX_W;
    begin
        return ctx(LO+FS_FSLOT_W-1 downto LO);
    end function;

    function fs_ctx_stream_f (ctx : std_logic_vector(FS_CTX_W-1 downto 0)) return std_logic_vector is
        constant LO : natural := FS_VBYTES_W + FS_COFS_W + FS_FOFS_W + FS_INDEX_W + FS_FSLOT_W;
    begin
        return ctx(LO+FS_STREAM_W-1 downto LO);
    end function;

    function fs_max_log2_drives_f (num_queues : natural) return natural is
        variable v : natural := num_queues;
        variable r : natural := 0;
    begin
        while (v > 1) loop
            v := v / 2;
            r := r + 1;
        end loop;
        return min(FS_MAX_LOG2_DRIVES, r);
    end function;

    function fs_stripe_drive_f (lba         : std_logic_vector(FS_LBA_W-1 downto 0);
        log2_drives : natural;
        log2_chunk  : natural) return natural is
        variable chunk : unsigned(FS_LBA_W-1 downto 0);
    begin
        chunk := shift_right(unsigned(lba), log2_chunk);
        return to_integer(chunk mod 2**log2_drives);
    end function;

    function fs_stripe_drive_lba_f (lba         : std_logic_vector(FS_LBA_W-1 downto 0);
        log2_drives : natural;
        log2_chunk  : natural) return std_logic_vector is
        variable chunk : unsigned(FS_LBA_W-1 downto 0);
        variable row   : unsigned(FS_LBA_W-1 downto 0);
    begin
        chunk := shift_right(unsigned(lba), log2_chunk);
        row   := shift_right(chunk, log2_drives);
        return std_logic_vector(shift_left(row, log2_chunk) or (unsigned(lba) mod 2**log2_chunk));
    end function;

    function fs_err_info_f (src     : natural;
        code    : std_logic_vector(1 downto 0);
        is_read : std_logic;
        drive   : std_logic_vector(3 downto 0);
        cid     : std_logic_vector(15 downto 0)) return std_logic_vector is
        variable info : std_logic_vector(31 downto 0) := (others => '0');
    begin
        info(1 downto 0)   := code;
        info(2)            := is_read;
        info(7 downto 4)   := drive;
        info(11 downto 8)  := std_logic_vector(to_unsigned(src, 4));
        info(31 downto 16) := cid;
        return info;
    end function;

    function fs_rr_pick_f (eligible : std_logic_vector; ptr : natural) return natural is
        alias    elig : std_logic_vector(eligible'length-1 downto 0) is eligible;
        variable idx  : natural := ptr;
    begin
        -- Downward, so the index nearest the pointer is the last assignment and wins.
        for k in elig'length-1 downto 0 loop
            if (elig((ptr + k) mod elig'length) = '1') then
                idx := (ptr + k) mod elig'length;
            end if;
        end loop;
        return idx;
    end function;

end package body;
