-- user_core_file_arch.vhd: USER_CORE architecture hosting the file shell
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-W-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.math_pack.all;
use work.type_pack.all;
use work.nvme_meta_pack.all;
use work.fs_pkg.all;

-- Selected by USR_CORE_ARCH=FILE; FILE itself is a reserved word, so the architecture is FILES. The
-- shell is the whole architecture; it owns the MI window and the HBM port.
architecture FILES of USER_CORE is

    constant FS_STREAMS : natural := FS_MAX_STREAMS;

begin

    assert (DMA_MFB_REGIONS = 1 and DMA_STREAMS = PCIE_ENDPOINTS)
        report "USER_CORE(FILES): needs one MFB region and one read stream per endpoint."
        severity FAILURE;
    assert (HBM_ADDR_WIDTH = 34 and HBM_DATA_WIDTH = 256 and HBM_ID_WIDTH = 6 and HBM_LEN_WIDTH = 4)
        report "USER_CORE(FILES): FS_HBM_PORT is built for the U55C HBM port geometry."
        severity FAILURE;

    file_shell_i : entity work.FILE_SHELL
    generic map (
        STREAMS           => FS_STREAMS,
        NUM_QUEUES        => NUM_QUEUES,
        PCIE_ENDPOINTS    => PCIE_ENDPOINTS,
        KERNEL_ID         => FS_KERNEL_DIGEST_FILL,
        MI_WIDTH          => MI_WIDTH,
        MFB_REGION_SIZE   => DMA_MFB_REGION_SIZE,
        MFB_BLOCK_SIZE    => DMA_MFB_BLOCK_SIZE,
        MFB_ITEM_WIDTH    => DMA_MFB_ITEM_WIDTH,
        CID_W             => CQ_ENTRY_CMD_ID_W,
        IF_PIPE_STAGES    => 6,
        IF_PIPE_REQ_ITEMS => 16,
        STAGE_LOG2_BEATS  => 12,
        DONE_QUIET        => 1024,
        HBM_BASE          => (others => '0'),
        DEVICE            => DEVICE
    )
    port map (
        DMA_CLK => DMA_CLK,
        DMA_RST => DMA_RST,

        MI_CLK  => MI_CLK,
        MI_RST  => MI_RST,
        MI_DWR  => MI_DWR,
        MI_ADDR => MI_ADDR,
        MI_BE   => MI_BE,
        MI_RD   => MI_RD,
        MI_WR   => MI_WR,
        MI_ARDY => MI_ARDY,
        MI_DRD  => MI_DRD,
        MI_DRDY => MI_DRDY,

        NVME_RD_REQ_LBA_NUM    => NVME_RD_REQ_LBA_NUM,
        NVME_RD_REQ_NPAGES_ALL => NVME_RD_REQ_NPAGES_ALL,
        NVME_RD_REQ_LBA_PTR    => NVME_RD_REQ_LBA_PTR,
        NVME_RD_REQ_VLD        => NVME_RD_REQ_VLD,
        NVME_RD_REQ_RDY        => NVME_RD_REQ_RDY,
        NVME_RD_REQ_QID        => NVME_RD_REQ_QID,
        NVME_RD_REQ_CID        => NVME_RD_REQ_CID,
        NVME_RD_REQ_CID_VLD    => NVME_RD_REQ_CID_VLD,

        NVME_OP_STAT_TYPE => NVME_OP_STAT_TYPE,
        NVME_OP_STAT_QID  => NVME_OP_STAT_QID,
        NVME_OP_STAT_CID  => NVME_OP_STAT_CID,
        NVME_OP_STAT_CODE => NVME_OP_STAT_CODE,
        NVME_OP_STAT_VLD  => NVME_OP_STAT_VLD,

        NVME_RD_MFB_DATA    => NVME_RD_MFB_DATA,
        NVME_RD_MFB_META    => NVME_RD_MFB_META,
        NVME_RD_MFB_SOF     => NVME_RD_MFB_SOF,
        NVME_RD_MFB_EOF     => NVME_RD_MFB_EOF,
        NVME_RD_MFB_SOF_POS => NVME_RD_MFB_SOF_POS,
        NVME_RD_MFB_EOF_POS => NVME_RD_MFB_EOF_POS,
        NVME_RD_MFB_SRC_RDY => NVME_RD_MFB_SRC_RDY,
        NVME_RD_MFB_DST_RDY => NVME_RD_MFB_DST_RDY,

        NVME_WR_MFB_DATA    => NVME_WR_MFB_DATA,
        NVME_WR_MFB_META    => NVME_WR_MFB_META,
        NVME_WR_MFB_SOF     => NVME_WR_MFB_SOF,
        NVME_WR_MFB_EOF     => NVME_WR_MFB_EOF,
        NVME_WR_MFB_SOF_POS => NVME_WR_MFB_SOF_POS,
        NVME_WR_MFB_EOF_POS => NVME_WR_MFB_EOF_POS,
        NVME_WR_MFB_SRC_RDY => NVME_WR_MFB_SRC_RDY,
        NVME_WR_MFB_DST_RDY => NVME_WR_MFB_DST_RDY,

        HBM_READY => HBM_READY,
        HBM_RESET => HBM_RESET,

        HBM_AXI_ARADDR       => HBM_AXI_ARADDR,
        HBM_AXI_ARBURST      => HBM_AXI_ARBURST,
        HBM_AXI_ARID         => HBM_AXI_ARID,
        HBM_AXI_ARLEN        => HBM_AXI_ARLEN,
        HBM_AXI_ARSIZE       => HBM_AXI_ARSIZE,
        HBM_AXI_ARVALID      => HBM_AXI_ARVALID,
        HBM_AXI_ARREADY      => HBM_AXI_ARREADY,
        HBM_AXI_AWADDR       => HBM_AXI_AWADDR,
        HBM_AXI_AWBURST      => HBM_AXI_AWBURST,
        HBM_AXI_AWID         => HBM_AXI_AWID,
        HBM_AXI_AWLEN        => HBM_AXI_AWLEN,
        HBM_AXI_AWSIZE       => HBM_AXI_AWSIZE,
        HBM_AXI_AWVALID      => HBM_AXI_AWVALID,
        HBM_AXI_AWREADY      => HBM_AXI_AWREADY,
        HBM_AXI_WDATA        => HBM_AXI_WDATA,
        HBM_AXI_WDATA_PARITY => HBM_AXI_WDATA_PARITY,
        HBM_AXI_WLAST        => HBM_AXI_WLAST,
        HBM_AXI_WSTRB        => HBM_AXI_WSTRB,
        HBM_AXI_WVALID       => HBM_AXI_WVALID,
        HBM_AXI_WREADY       => HBM_AXI_WREADY,
        HBM_AXI_BID          => HBM_AXI_BID,
        HBM_AXI_BRESP        => HBM_AXI_BRESP,
        HBM_AXI_BVALID       => HBM_AXI_BVALID,
        HBM_AXI_BREADY       => HBM_AXI_BREADY,
        HBM_AXI_RDATA        => HBM_AXI_RDATA,
        HBM_AXI_RID          => HBM_AXI_RID,
        HBM_AXI_RLAST        => HBM_AXI_RLAST,
        HBM_AXI_RRESP        => HBM_AXI_RRESP,
        HBM_AXI_RVALID       => HBM_AXI_RVALID,
        HBM_AXI_RREADY       => HBM_AXI_RREADY
    );

end architecture;
