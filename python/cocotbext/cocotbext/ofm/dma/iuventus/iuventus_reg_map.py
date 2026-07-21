# mi_reg_map.py: Contains register map for Iuventus NVMe controller
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

from enum import IntEnum

class CtrlRegBits(IntEnum):
    ENABLE = 0
    SAMPLE_CNTRS = 1
    CLR_ERR_MASK = 2
    RST_CNTRS = 3
    EN_UPD_RPT = 4

class StatRegBits(IntEnum):
    READY = 0
    RST_DONE = 1
    TAG_INIT_DONE = 2

class IuventusMiRegMap(IntEnum):
    """COMMON register block (shared across every queue): CONTROL/STATUS, the shared RDBUFF/
    WRBUFF data-pool base addresses/PRP list pointers, METADATA_PTR, LAST_CQ_ENTRY/CPL_ERR_MASK/
    TAG_FIFO_STATUS status, and every *_CNTR performance counter (see nvme_sw_manager.vhd's
    R_ADDRS_COMMON, which this must match exactly). Per-queue configuration/doorbell registers
    live in the separate PER_Q_BASE-based 2D block -- see IuventusPerQueueRegMap below.
    """
    CONTROL                     = 0x000
    STATUS                      = 0x004
    RDBUFF_BADDR_L              = 0x008
    RDBUFF_BADDR_H              = 0x00C
    RDBUFF_PRP_LIST_PTR_L       = 0x010
    RDBUFF_PRP_LIST_PTR_H       = 0x014
    WRBUFF_BADDR_L              = 0x018
    WRBUFF_BADDR_H              = 0x01C
    WRBUFF_PRP_LIST_PTR_L       = 0x020
    WRBUFF_PRP_LIST_PTR_H       = 0x024
    META_PTR_L                  = 0x028
    META_PTR_H                  = 0x02C
    LAST_CQ_ENTRY_0             = 0x030
    LAST_CQ_ENTRY_1             = 0x034
    LAST_CQ_ENTRY_2             = 0x038
    LAST_CQ_ENTRY_3             = 0x03C
    CPL_ERR_MASK_L              = 0x040
    CPL_ERR_MASK_H              = 0x044
    TAG_FIFO_STATUS             = 0x048
    SQE_DISP_CNTR_L             = 0x04C
    SQE_DISP_CNTR_H             = 0x050
    CQE_PROC_CNTR_L             = 0x054
    CQE_PROC_CNTR_H             = 0x058
    PCIE_RDS_CNTR_L             = 0x05C
    PCIE_RDS_CNTR_H             = 0x060
    PCIE_RD_BYTES_CNTR_L        = 0x064
    PCIE_RD_BYTES_CNTR_H        = 0x068
    PCIE_WRS_CNTR_L             = 0x06C
    PCIE_WRS_CNTR_H             = 0x070
    PCIE_WR_BYTES_CNTR_L        = 0x074
    PCIE_WR_BYTES_CNTR_H        = 0x078
    SQ_PCIE_RDS_CNTR_L          = 0x07C
    SQ_PCIE_RDS_CNTR_H          = 0x080
    SQ_PCIE_RD_BYTES_CNTR_L     = 0x084
    SQ_PCIE_RD_BYTES_CNTR_H     = 0x088
    SUCC_COMPL_CNTR_L           = 0x08C
    SUCC_COMPL_CNTR_H           = 0x090
    UNSUCC_COMPL_CNTR_L         = 0x094
    UNSUCC_COMPL_CNTR_H         = 0x098
    RDBUFF_PCIE_RDS_CNTR_L      = 0x09C
    RDBUFF_PCIE_RDS_CNTR_H      = 0x0A0
    RDBUFF_PCIE_RD_BYTES_CNTR_L = 0x0A4
    RDBUFF_PCIE_RD_BYTES_CNTR_H = 0x0A8
    WRBUFF_PCIE_WRS_CNTR_L      = 0x0AC
    WRBUFF_PCIE_WRS_CNTR_H      = 0x0B0
    WRBUFF_PCIE_WR_BYTES_CNTR_L = 0x0B4
    WRBUFF_PCIE_WR_BYTES_CNTR_H = 0x0B8
    CQ_PCIE_WRS_CNTR_L          = 0x0BC
    CQ_PCIE_WRS_CNTR_H          = 0x0C0
    CQ_PCIE_WR_BYTES_CNTR_L     = 0x0C4
    CQ_PCIE_WR_BYTES_CNTR_H     = 0x0C8
    CQHDBL_REG_UPDS_CNTR_L      = 0x0CC
    CQHDBL_REG_UPDS_CNTR_H      = 0x0D0
    CQHDBL_RPT_UPDS_CNTR_L      = 0x0D4
    CQHDBL_RPT_UPDS_CNTR_H      = 0x0D8
    SQTDBL_REG_UPDS_CNTR_L      = 0x0DC
    SQTDBL_REG_UPDS_CNTR_H      = 0x0E0
    SQTDBL_RPT_UPDS_CNTR_L      = 0x0E4
    SQTDBL_RPT_UPDS_CNTR_H      = 0x0E8
    NVME_RD_BYTES_CNTR_L        = 0x0EC
    NVME_RD_BYTES_CNTR_H        = 0x0F0
    NVME_WR_BYTES_CNTR_L        = 0x0F4
    NVME_WR_BYTES_CNTR_H        = 0x0F8
    WRBUFF_USR_RDS_CNTR_L       = 0x0FC
    WRBUFF_USR_RDS_CNTR_H       = 0x100
    WRBUFF_USR_RD_BYTES_CNTR_L  = 0x104
    WRBUFF_USR_RD_BYTES_CNTR_H  = 0x108
    RDBUFF_DISP_RDS_CNTR_L      = 0x10C
    RDBUFF_DISP_RDS_CNTR_H      = 0x110
    RDBUFF_DISP_RD_BYTES_CNTR_L = 0x114
    RDBUFF_DISP_RD_BYTES_CNTR_H = 0x118
    SQ_DISP_RDS_CNTR_L          = 0x11C
    SQ_DISP_RDS_CNTR_H          = 0x120
    SQ_DISP_RD_BYTES_CNTR_L     = 0x124
    SQ_DISP_RD_BYTES_CNTR_H     = 0x128
    NVME_FLUSH_DISP_CNTR_L      = 0x12C
    NVME_FLUSH_DISP_CNTR_H      = 0x130


# Base offset and per-queue slot stride of the PER-QUEUE 2D register block (must match
# nvme_sw_manager.vhd's PER_Q_BASE/PER_Q_STRIDE constants exactly). Queue 0 is q=0 of this block
# -- there is no separate/legacy register set for queue 0.
PER_Q_BASE = 0x200
PER_Q_STRIDE = 0x40


class IuventusPerQueueRegMap(IntEnum):
    """Byte offsets *relative to one queue's slot* (PER_Q_BASE + qid*PER_Q_STRIDE) -- see
    per_queue_reg_addr() below for turning one of these into an absolute MI address for a given
    queue. Must match nvme_sw_manager.vhd's PQ_OFFSETS exactly.
    """
    SQTDBL           = 0x00  # RO: observed current SQTDBL value
    SQHDBL           = 0x04  # RO: observed current SQHDBL value
    CQHDBL           = 0x08  # RO: observed current CQHDBL value
    DBL_MASK         = 0x0C
    SQTDBL_BADDR_L   = 0x10
    SQTDBL_BADDR_H   = 0x14
    CQHDBL_BADDR_L   = 0x18
    CQHDBL_BADDR_H   = 0x1C
    LBA_SPACE_SIZE_L = 0x20
    LBA_SPACE_SIZE_H = 0x24
    NAMESPACE_ID     = 0x28
    LBA_NUM_MASK     = 0x2C


def per_queue_reg_addr(reg: IuventusPerQueueRegMap, qid: int) -> int:
    """Absolute MI byte address of per-queue register `reg` for queue `qid`."""
    return PER_Q_BASE + qid * PER_Q_STRIDE + int(reg)
