"""Module with general parameters and imports for PCIe extensions."""

from enum import IntEnum

# Xilinx US+ devices
from .Axi4SCompleter import Axi4SCompleter
from .Axi4SRequester import Axi4SRequester

# Intel S10/Agi devices (with P-Tile)
from .AvstCompleter import AvstCompleter
from .AvstRequester import AvstRequester
from .PcieRequester import PcieRequester

# Generic device
from .PcieHeaders import (RQHeader, CQHeader, RCHeader, CCHeader, RQUser, CQUser,
                          RCUser, CQMfbMeta, RQMfbMeta, CCMfbMeta, RCMfbMeta)

__all__ = ["Axi4SCompleter", "Axi4SRequester", "AvstCompleter", "AvstRequester", "PcieRequester",
           "RQHeader", "CQHeader", "RCHeader", "CCHeader", "RQUser", "CQUser",
           "RCUser", "CQMfbMeta", "RQMfbMeta", "CCMfbMeta", "RCMfbMeta"]


class PcieReqType(IntEnum):
    MWR = 0x1
    MRD = 0x0
    IOWR = 0x2
    IORD = 0x3
    MFETCH_AND_ADD = 0x4
    MSWAP = 0x5
    MCOMPARE_SWAP = 0x6
    LOC_RD = 0x7
    TYPE0_CONF_RD = 0x8
    TYPE1_CONF_RD = 0x9
    TYPE0_CONF_WR = 0xA
    TYPE1_CONF_WR = 0xB
    ANY_MSG = 0xC
    VENDOR_MSG = 0xD
    ATS_MSG = 0xE
    RSVD = 0xF
    
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