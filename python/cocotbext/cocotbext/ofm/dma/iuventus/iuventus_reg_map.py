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
    OP_SOFT_RST = 5

class StatRegBits(IntEnum):
    READY = 0
    RST_DONE = 1
    TAG_INIT_DONE = 2

class IuventusMiRegMap(IntEnum):
    """COMMON register block (shared across every queue): CONTROL/STATUS, the shared RDBUFF/
    WRBUFF data-pool base addresses/PRP list pointers, METADATA_PTR, LAST_CQ_ENTRY/CPL_ERR_MASK/
    TAG_FIFO_STATUS status, and every *_CNTR performance counter (see nvme_sw_manager.vhd's
    R_ADDRS, which this must match exactly). Per-queue configuration/doorbell registers live in
    the separate PER_Q_BASE-based 2D block (IuventusPerQueueRegMap below); per-queue SSD-facing
    stat counters (succ/unsucc completions, SQE dispatches, CQE processed) live in the separate
    PER_Q_CNTR_BASE-based 2D block (IuventusPerQueueCntrRegMap below).

    The debug-only per-BAR/buffer breakdown counters (aggregate PCIE_RDS/RD_BYTES/WRS/WR_BYTES,
    RDBUFF_PCIE_*, WRBUFF_PCIE_*, CQ_PCIE_*, SQ_DISP_RDS/BYTES, RDBUFF_DISP_*, WRBUFF_USR_*, and
    the never-wired *_RPT_UPDS_CNTR_* placeholders) were dropped from the register map -- they
    weren't needed for SSD throughput/HW debug (see the report accompanying this change).
    SUCC_COMPL/UNSUCC_COMPL/SQE_DISP/CQE_PROC stay here as COMMON aggregates (quick "everything"
    totals) alongside their new per-queue counterparts in IuventusPerQueueCntrRegMap.
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
    SQ_PCIE_RDS_CNTR_L          = 0x05C
    SQ_PCIE_RDS_CNTR_H          = 0x060
    SQ_PCIE_RD_BYTES_CNTR_L     = 0x064
    SQ_PCIE_RD_BYTES_CNTR_H     = 0x068
    SUCC_COMPL_CNTR_L           = 0x06C
    SUCC_COMPL_CNTR_H           = 0x070
    UNSUCC_COMPL_CNTR_L         = 0x074
    UNSUCC_COMPL_CNTR_H         = 0x078
    CQHDBL_REG_UPDS_CNTR_L      = 0x07C
    CQHDBL_REG_UPDS_CNTR_H      = 0x080
    SQTDBL_REG_UPDS_CNTR_L      = 0x084
    SQTDBL_REG_UPDS_CNTR_H      = 0x088
    NVME_RD_BYTES_CNTR_L        = 0x08C
    NVME_RD_BYTES_CNTR_H        = 0x090
    NVME_WR_BYTES_CNTR_L        = 0x094
    NVME_WR_BYTES_CNTR_H        = 0x098
    NVME_FLUSH_DISP_CNTR_L      = 0x09C
    NVME_FLUSH_DISP_CNTR_H      = 0x0A0


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


# Base offset and per-queue slot stride of the PER-QUEUE COUNTER 2D register block (must match
# nvme_sw_manager.vhd's PER_Q_CNTR_BASE/PER_Q_CNTR_STRIDE constants exactly). A SEPARATE, parallel
# 2D block from IuventusPerQueueRegMap above -- PER_Q_STRIDE (0x40) has no room left for these 8
# more 32-bit fields alongside the 12 already there.
PER_Q_CNTR_BASE = 0x800
PER_Q_CNTR_STRIDE = 0x40


class IuventusPerQueueCntrRegMap(IntEnum):
    """Byte offsets *relative to one queue's slot* (PER_Q_CNTR_BASE + qid*PER_Q_CNTR_STRIDE) --
    see per_queue_cntr_reg_addr() below. Read-only; populated by SAMPLE_CNTRS like the COMMON
    counters (write CtrlRegBits.SAMPLE_CNTRS to IuventusMiRegMap.CONTROL, then read). Must match
    nvme_sw_manager.vhd's PQC_* constants exactly.

    sq_pcie_rds is NOT here (stays a COMMON-only aggregate, IuventusMiRegMap.SQ_PCIE_RDS_CNTR_*):
    the underlying PCIe-read-request-count signal is classified only by which BAR it targets, not
    which queue's SQ ring within that BAR, so no per-queue QID is available at that signal's
    boundary (see the report accompanying this change).
    """
    SUCC_CPLS_L   = 0x00
    SUCC_CPLS_H   = 0x04
    UNSUCC_CPLS_L = 0x08
    UNSUCC_CPLS_H = 0x0C
    SQE_DISP_L    = 0x10
    SQE_DISP_H    = 0x14
    CQE_PROC_L    = 0x18
    CQE_PROC_H    = 0x1C


def per_queue_cntr_reg_addr(reg: IuventusPerQueueCntrRegMap, qid: int) -> int:
    """Absolute MI byte address of per-queue counter register `reg` for queue `qid`."""
    return PER_Q_CNTR_BASE + qid * PER_Q_CNTR_STRIDE + int(reg)
