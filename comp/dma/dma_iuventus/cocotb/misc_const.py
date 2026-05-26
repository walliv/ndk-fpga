# misc_const.py: Important constants for the global configuration plus some helper functions
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

from enum import IntEnum

SQE_SIZE = 64
CQE_SIZE = 16
MPS = 512
MRRS = 4096
PAGE_SIZE = 4096
SECT_SIZE = 512
STORAGE_CAP = 10 # in MB
STORAGE_CAP_LBAS = (STORAGE_CAP * 1024**2) // SECT_SIZE
STORAGE_CAP_PAGES = (STORAGE_CAP * 1024**2) // PAGE_SIZE
BUFF_SIZE = 2**17 # 128 KiB
BUFF_SIZE_LBAS = BUFF_SIZE // SECT_SIZE
BUFF_SIZE_PAGES = BUFF_SIZE // PAGE_SIZE

class IuventusBuffers:
    def __init__(self, qsize):
        self.qsize = qsize
        self.sq = bytearray(qsize * SQE_SIZE)
        self.cq = bytearray(qsize * CQE_SIZE)
        self.rd_buff = bytearray(BUFF_SIZE)
        self.wr_buff = bytearray(BUFF_SIZE)

    def reset(self):
        self.sq = bytearray(self.qsize * SQE_SIZE)
        self.cq = bytearray(self.qsize * CQE_SIZE)
        self.rd_buff = bytearray(BUFF_SIZE)
        self.wr_buff = bytearray(BUFF_SIZE)

class IuventusBarSelection(IntEnum):
    SQ_BAR = 0
    CQ_BAR = 1
    WR_BUFF_BAR = 2
    RD_BUFF_BAR = 3


class IuventusOpStatCode(IntEnum):
    # These should be 4 bit values
    SUCC = 0x0
    GEN_FAILURE = 0x1
    LBA_OUT_OF_RANGE = 0x2


class PcieReqType(IntEnum):
    MWR = 0x1
    MRD = 0x0


def pcie_byte_count(dword_count, first_be, last_be):
    """
    Calculates Total Byte Count based on AMD's PCIe logic table.
    Handles First BE and Last BE bit positions to determine 'span'.
    """
    if dword_count == 0:
        return 0

    # Find the index of the lowest set bit in first_be (0 to 3)
    # This corresponds to the starting byte offset.
    if first_be == 0:
        assert last_be == 0, "If First BE is 0, Last BE must also be 0."
        assert dword_count == 1, "If First BE is 0, Dword Count must also be 1."
        # Special case: Zero-length read is often treated as 1 byte in some
        # logic tables or specifically handled by the controller.
        # Table 59 shows 0000/0000 = 1 byte.
        return 1

    # Get position of the lowest '1' (e.g., 1100 -> bit 2)
    first_bit_low = (first_be & -first_be).bit_length() - 1

    # Case 1: Single Dword Transaction (Dword Count = 1)
    if dword_count == 1:
        assert last_be == 0, "For Dword Count = 1, Last BE must be 0."
        # In a single DW, the 'span' is from the first bit to the highest bit
        first_bit_high = first_be.bit_length() - 1
        return (first_bit_high - first_bit_low) + 1

    # Case 2: Multi-Dword Transaction (Dword Count > 1)
    else:
        assert last_be != 0, "For Dword Count > 1, Last BE must not be 0."
        # Find the index of the highest set bit in last_be (0 to 3)
        last_bit_high = last_be.bit_length() - 1

        # Logic from Table 59 (cont'd):
        # Total = (Dword_count * 4) - (unenabled bytes at start) - (unenabled bytes at end)
        start_gap = first_bit_low               # Bytes skipped at the beginning
        end_gap = 3 - last_bit_high             # Bytes skipped at the very end

        return (dword_count * 4) - start_gap - end_gap