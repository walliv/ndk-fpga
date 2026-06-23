# c2h_hbm_reader_reg_map.py: Register map for the C2H HBM reader SW manager
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

from enum import IntEnum

class C2HCtrlRegBits(IntEnum):
    START      = 0
    CLEAR_DONE = 1

class C2HStatRegBits(IntEnum):
    BUSY      = 0
    DONE      = 1
    ERROR     = 2   # AXI RRESP error
    RANGE_ERR = 3   # invalid addr/size request (rejected, no transfer)

class C2HReaderMIRegMap(IntEnum):
    CTRL        = 0x00
    STATUS      = 0x04
    ADDR_L      = 0x08
    ADDR_H      = 0x0C
    SIZE_L      = 0x10
    SIZE_H      = 0x14
    REQ_CNT_L   = 0x18
    REQ_CNT_H   = 0x1C
    REQ_BYTES_L = 0x20
    REQ_BYTES_H = 0x24
