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
    CONTROL                     = 0x000
    STATUS                      = 0x004
    SQTDBL                      = 0x008
    SQHDBL                      = 0x00C
    CQHDBL                      = 0x010
    DBL_MASK                    = 0x014
    SQTDBL_BADDR_L              = 0x018
    SQTDBL_BADDR_H              = 0x01C
    CQHDBL_BADDR_L              = 0x020
    CQHDBL_BADDR_H              = 0x024
    RDBUFF_BADDR_L              = 0x028
    RDBUFF_BADDR_H              = 0x02C
    RDBUFF_PRP_LIST_PTR_L       = 0x030
    RDBUFF_PRP_LIST_PTR_H       = 0x034
    WRBUFF_BADDR_L              = 0x038
    WRBUFF_BADDR_H              = 0x03C
    WRBUFF_PRP_LIST_PTR_L       = 0x040
    WRBUFF_PRP_LIST_PTR_H       = 0x044
    LAST_CQ_ENTRY_0             = 0x048
    LAST_CQ_ENTRY_1             = 0x04C
    LAST_CQ_ENTRY_2             = 0x050
    LAST_CQ_ENTRY_3             = 0x054
    SQE_DISP_CNTR_L             = 0x058
    SQE_DISP_CNTR_H             = 0x05C
    CQE_PROC_CNTR_L             = 0x060
    CQE_PROC_CNTR_H             = 0x064
    PCIE_RDS_CNTR_L             = 0x068
    PCIE_RDS_CNTR_H             = 0x06C
    PCIE_RD_BYTES_CNTR_L        = 0x070
    PCIE_RD_BYTES_CNTR_H        = 0x074
    PCIE_WRS_CNTR_L             = 0x078
    PCIE_WRS_CNTR_H             = 0x07C
    PCIE_WR_BYTES_CNTR_L        = 0x080
    PCIE_WR_BYTES_CNTR_H        = 0x084
    SQ_PCIE_RDS_CNTR_L          = 0x088
    SQ_PCIE_RDS_CNTR_H          = 0x08C
    SQ_PCIE_RD_BYTES_CNTR_L     = 0x090
    SQ_PCIE_RD_BYTES_CNTR_H     = 0x094
    LBA_NUM_MASK                = 0x098
    SUCC_COMPL_CNTR_L           = 0x09C
    SUCC_COMPL_CNTR_H           = 0x0A0
    UNSUCC_COMPL_CNTR_L         = 0x0A4
    UNSUCC_COMPL_CNTR_H         = 0x0A8
    CPL_ERR_MASK_L              = 0x0AC
    CPL_ERR_MASK_H              = 0x0B0
    RDBUFF_PCIE_RDS_CNTR_L      = 0x0B4
    RDBUFF_PCIE_RDS_CNTR_H      = 0x0B8
    RDBUFF_PCIE_RD_BYTES_CNTR_L = 0x0BC
    RDBUFF_PCIE_RD_BYTES_CNTR_H = 0x0C0
    WRBUFF_PCIE_WRS_CNTR_L      = 0x0C4
    WRBUFF_PCIE_WRS_CNTR_H      = 0x0C8
    WRBUFF_PCIE_WR_BYTES_CNTR_L = 0x0CC
    WRBUFF_PCIE_WR_BYTES_CNTR_H = 0x0D0
    LBA_SPACE_SIZE_L            = 0x0D4
    LBA_SPACE_SIZE_H            = 0x0D8
    CQ_PCIE_WRS_CNTR_L          = 0x0DC
    CQ_PCIE_WRS_CNTR_H          = 0x0E0
    CQ_PCIE_WR_BYTES_CNTR_L     = 0x0E4
    CQ_PCIE_WR_BYTES_CNTR_H     = 0x0E8
    CQHDBL_REG_UPDS_CNTR_L      = 0x0EC
    CQHDBL_REG_UPDS_CNTR_H      = 0x0F0
    CQHDBL_RPT_UPDS_CNTR_L      = 0x0F4
    CQHDBL_RPT_UPDS_CNTR_H      = 0x0F8
    SQTDBL_REG_UPDS_CNTR_L      = 0x0FC
    SQTDBL_REG_UPDS_CNTR_H      = 0x100
    SQTDBL_RPT_UPDS_CNTR_L      = 0x104
    SQTDBL_RPT_UPDS_CNTR_H      = 0x108
    META_PTR_L                  = 0x10C
    META_PTR_H                  = 0x110
    NVME_RD_BYTES_CNTR_L        = 0x114
    NVME_RD_BYTES_CNTR_H        = 0x118
    NVME_WR_BYTES_CNTR_L        = 0x11C
    NVME_WR_BYTES_CNTR_H        = 0x120
    WRBUFF_USR_RDS_CNTR_L       = 0x124
    WRBUFF_USR_RDS_CNTR_H       = 0x128
    WRBUFF_USR_RD_BYTES_CNTR_L  = 0x12C
    WRBUFF_USR_RD_BYTES_CNTR_H  = 0x130
    RDBUFF_DISP_RDS_CNTR_L      = 0x134
    RDBUFF_DISP_RDS_CNTR_H      = 0x138
    RDBUFF_DISP_RD_BYTES_CNTR_L = 0x13C
    RDBUFF_DISP_RD_BYTES_CNTR_H = 0x140
    SQ_DISP_RDS_CNTR_L          = 0x144
    SQ_DISP_RDS_CNTR_H          = 0x148
    SQ_DISP_RD_BYTES_CNTR_L     = 0x14C
    SQ_DISP_RD_BYTES_CNTR_H     = 0x150
    TAG_FIFO_STATUS             = 0x154
    NVME_FLUSH_DISP_CNTR_L      = 0x158
    NVME_FLUSH_DISP_CNTR_H      = 0x15C