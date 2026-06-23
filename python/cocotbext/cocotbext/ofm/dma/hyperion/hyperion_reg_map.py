# hyperion_reg_map.py: Register map for the H2C DMA Hyperion SW manager
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

from enum import IntEnum

class CtrlRegBits(IntEnum):
    SAMPLE_CNTRS = 0
    RST_CNTRS    = 1

class StatRegBits(IntEnum):
    PCIE_BLOCK  = 0
    HBM_W_BLOCK = 1
    HBM_AW_BLOCK = 2

class H2CHyperionMIRegMap(IntEnum):
    CONTROL                  = 0x00
    STATUS                   = 0x04
    PCIE_WR_REQS_CNTR_L      = 0x08
    PCIE_WR_REQS_CNTR_H      = 0x0C
    PCIE_WR_REQ_BYTES_CNTR_L = 0x10
    PCIE_WR_REQ_BYTES_CNTR_H = 0x14
    PCIE_RD_REQS_CNTR_L      = 0x18
    PCIE_RD_REQS_CNTR_H      = 0x1C
    PCIE_RD_REQ_BYTES_CNTR_L = 0x20
    PCIE_RD_REQ_BYTES_CNTR_H = 0x24
    HBM_WR_TRS_CNTR_L        = 0x28
    HBM_WR_TRS_CNTR_H        = 0x2C
    HBM_WR_BYTES_CNTR_L      = 0x30
    HBM_WR_BYTES_CNTR_H      = 0x34
    PCIE_MFB_BLOCK_CNTR_L    = 0x38
    PCIE_MFB_BLOCK_CNTR_H    = 0x3C
    HBM_W_BLOCK_CNTR_L       = 0x40
    HBM_W_BLOCK_CNTR_H       = 0x44
    HBM_AW_BLOCK_CNTR_L      = 0x48
    HBM_AW_BLOCK_CNTR_H      = 0x4C
    PCIE_DROP_CNTR_L         = 0x50
    PCIE_DROP_CNTR_H         = 0x54
    PCIE_DROP_BYTES_CNTR_L   = 0x58
    PCIE_DROP_BYTES_CNTR_H   = 0x5C
