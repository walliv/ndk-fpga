-- user_core_ent.vhd: Entity declaration of the user core to ensure consistent port names
-- Copyright (c) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-P-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.math_pack.all;
use work.type_pack.all;
use work.combo_user_const.all;
use work.nvme_meta_pack.all;

entity USER_CORE is
    generic (
        -- MI parameters: width of data signals
        MI_WIDTH    : integer := 32;
        -- DMA: number of DMA streams
        DMA_STREAMS : natural := 1;
        -- DMA: number of independent SQ/CQ queues (one per SSD) that the DMA is built with.
        -- Governs the width of NVME_RD_REQ_QID and of the QID field appended to NVME_WR_MFB_META.
        NUM_QUEUES  : natural := 1;

        -- DMA MFB: number of regions in word
        DMA_MFB_REGIONS     : natural := 1;
        -- DMA MFB: number of blocks in region
        DMA_MFB_REGION_SIZE : natural := 8;
        -- MFB parameters: number of items in block
        DMA_MFB_BLOCK_SIZE  : natural := 8;
        -- MFB parameters: width of one item in bits
        DMA_MFB_ITEM_WIDTH  : natural := 8;

        FPGA_ID_WIDTH : integer := 16;
        DEVICE        : string  := "ULTRASCALE"
    );
    port (
        -- Custom user clock and reset
        USR_CLK : in std_logic;
        -- Driven from a clock tree and deasserted when the PLL in the MMCM locks
        USR_RST : in std_logic;

        DMA_CLK : in std_logic;
        -- Driven from the PCIe IP and deasserted when initialization of the link is done
        DMA_RST : in std_logic;

        -- =========================================================================================
        -- Memory Interface (MI) bus
        -- =========================================================================================
        MI_CLK : in std_logic;
        -- Driven from a clock tree and deasserted when the PLL in the MMCM locks
        MI_RST : in std_logic;

        -- data from master to slave (write data)
        MI_DWR  : in  std_logic_vector(MI_WIDTH-1 downto 0);
        -- slave address
        MI_ADDR : in  std_logic_vector(MI_WIDTH-1 downto 0);
        -- byte enable for write data
        MI_BE   : in  std_logic_vector((MI_WIDTH/8)-1 downto 0);
        -- read request
        MI_RD   : in  std_logic;
        -- write request
        MI_WR   : in  std_logic;
        -- ready of slave module
        MI_ARDY : out std_logic;
        -- data from slave to master (read data)
        MI_DRD  : out std_logic_vector(MI_WIDTH-1 downto 0);
        -- valid of MI_DRD data signal
        MI_DRDY : out std_logic;

        -- =========================================================================================
        -- Read operation submit interface
        -- =========================================================================================
        -- The size of data (0-based value).
        NVME_RD_REQ_LBA_NUM   : out std_logic_vector(7 downto 0);
        -- This is a LBA address (not a byte address) to the NVMe
        NVME_RD_REQ_LBA_PTR   : out std_logic_vector(63 downto 0);
        -- Per-queue handshake: at most one VLD bit, and it must be bit NVME_RD_REQ_QID. Accepted
        -- when VLD(QID) and RDY(QID) are both high.
        NVME_RD_REQ_VLD       : out std_logic_vector(NUM_QUEUES -1 downto 0);
        NVME_RD_REQ_RDY       : in  std_logic_vector(NUM_QUEUES -1 downto 0);
        -- Queue Identifier of the queue this read request targets (round-robin, see architecture)
        NVME_RD_REQ_QID       : out std_logic_vector(maximum(1, log2(NUM_QUEUES))-1 downto 0);
        -- Tag the accepted read was submitted under, qualified by CID_VLD. It arrives a few cycles
        -- after the accept, so it names the last accepted read, not the current handshake.
        NVME_RD_REQ_CID       : in  std_logic_vector(CQ_ENTRY_CMD_ID_W -1 downto 0);
        NVME_RD_REQ_CID_VLD   : in  std_logic;

        -- =========================================================================================
        -- Operation status interface
        -- =========================================================================================
        -- 0 for write, 1 for read
        NVME_OP_STAT_TYPE : in  std_logic;
        -- Identity of the reported command. CID is per-queue, so it names a command only together
        -- with QID. Neither is meaningful for CODE="10", an LBA-out-of-range rejection.
        NVME_OP_STAT_QID  : in  std_logic_vector(maximum(1, log2(NUM_QUEUES))-1 downto 0);
        NVME_OP_STAT_CID  : in  std_logic_vector(CQ_ENTRY_CMD_ID_W -1 downto 0);
        NVME_OP_STAT_CODE : in  std_logic_vector(1 downto 0);
        NVME_OP_STAT_VLD  : in  std_logic;

        -- =========================================================================================
        -- Read interface
        -- =========================================================================================
        NVME_RD_MFB_DATA    : in  std_logic_vector(DMA_MFB_REGIONS*DMA_MFB_REGION_SIZE*DMA_MFB_BLOCK_SIZE*DMA_MFB_ITEM_WIDTH-1 downto 0);
        -- Per region: bits [CQ_ENTRY_CMD_ID_W-1:0] = CID, bits above = QID. Together they name the
        -- command whose data this frame carries, so returned data can be attributed to a request.
        NVME_RD_MFB_META    : in  std_logic_vector(DMA_MFB_REGIONS*(maximum(1, log2(NUM_QUEUES)) + CQ_ENTRY_CMD_ID_W) -1 downto 0);
        NVME_RD_MFB_SOF     : in  std_logic_vector(DMA_MFB_REGIONS-1 downto 0);
        NVME_RD_MFB_EOF     : in  std_logic_vector(DMA_MFB_REGIONS-1 downto 0);
        NVME_RD_MFB_SOF_POS : in  std_logic_vector(DMA_MFB_REGIONS*maximum(1, log2(DMA_MFB_REGION_SIZE))-1 downto 0);
        NVME_RD_MFB_EOF_POS : in  std_logic_vector(DMA_MFB_REGIONS*log2(DMA_MFB_REGION_SIZE*DMA_MFB_BLOCK_SIZE)-1 downto 0);
        NVME_RD_MFB_SRC_RDY : in  std_logic;
        NVME_RD_MFB_DST_RDY : out std_logic;

        -- ==============================
        -- Write interface: although the data size seems unlimited, the maximum is 128 KiB, or 256
        -- LBAs/32 pages
        -- ==============================
        NVME_WR_MFB_DATA    : out std_logic_vector(DMA_MFB_REGIONS*DMA_MFB_REGION_SIZE*DMA_MFB_BLOCK_SIZE*DMA_MFB_ITEM_WIDTH-1 downto 0);
        -- Per region: bits [SQE_LBA_PTR_W-1:0] = LBA address to which data should be written;
        -- bits [SQE_LBA_PTR_W+QID_W-1:SQE_LBA_PTR_W] = Queue Identifier this write request targets
        NVME_WR_MFB_META    : out std_logic_vector(DMA_MFB_REGIONS*(SQE_LBA_PTR_W + maximum(1, log2(NUM_QUEUES))) -1 downto 0);
        NVME_WR_MFB_SOF     : out std_logic_vector(DMA_MFB_REGIONS-1 downto 0);
        NVME_WR_MFB_EOF     : out std_logic_vector(DMA_MFB_REGIONS-1 downto 0);
        NVME_WR_MFB_SOF_POS : out std_logic_vector(DMA_MFB_REGIONS*maximum(1, log2(DMA_MFB_REGION_SIZE))-1 downto 0);
        NVME_WR_MFB_EOF_POS : out std_logic_vector(DMA_MFB_REGIONS*log2(DMA_MFB_REGION_SIZE*DMA_MFB_BLOCK_SIZE)-1 downto 0);
        NVME_WR_MFB_SRC_RDY : out std_logic;
        NVME_WR_MFB_DST_RDY : in  std_logic;

        -- =========================================================================================
        -- Status signals
        -- =========================================================================================
        -- driven by USR_CLK
        PCIE_LINK_UP : in std_logic;
        -- driven by MI_CLK
        FPGA_ID      : in std_logic_vector(FPGA_ID_WIDTH -1 downto 0);
        -- driven by MI_CLK
        FPGA_ID_VLD  : in std_logic
    );
end entity;
