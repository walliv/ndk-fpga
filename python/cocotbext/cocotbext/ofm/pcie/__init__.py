"Agents for Integrated Block for PCI Express"

from enum import IntEnum

# Xilinx US+ devices
from .Axi4SCompleter import Axi4SCompleter
from .Axi4SRequester import Axi4SRequester

# Intel S10/Agi devices (with P-Tile)
from .AvstCompleter import AvstCompleter
from .AvstRequester import AvstRequester
from .PcieRequester import PcieRequester

# Generic device
from .PcieHeaders import (RQHeader, CQHeader, RCHeader, CCHeader, RQUser, CQUser, CQUser256,
                          RCUser, CCUser, CQMfbMeta, RQMfbMeta, CCMfbMeta, RCMfbMeta)

__all__ = ["Axi4SCompleter", "Axi4SRequester", "AvstCompleter", "AvstRequester", "PcieRequester",
           "RQHeader", "CQHeader", "RCHeader", "CCHeader", "RQUser", "CQUser",
           "CQUser256", "RCUser", "CCUser", "CQMfbMeta", "RQMfbMeta", "CCMfbMeta", "RCMfbMeta",
           "PcieReqType", "pcie_byte_count"]


class PcieReqType(IntEnum):
    """Request type encoding of the AMD UltraScale+ requester and completer descriptors."""
    MRD = 0x0
    MWR = 0x1
    IORD = 0x2
    IOWR = 0x3
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
    """Total byte count of a request from its Dword count and first and last byte enables, as in the byte count
    table of the AMD UltraScale+ PCIe integrated block (PG213)."""
    if dword_count == 0:
        return 0

    if first_be == 0:
        assert last_be == 0, "If First BE is 0, Last BE must also be 0."
        assert dword_count == 1, "If First BE is 0, Dword Count must also be 1."
        # The table assigns a zero-length request one byte.
        return 1

    first_bit_low = (first_be & -first_be).bit_length() - 1

    if dword_count == 1:
        assert last_be == 0, "For Dword Count = 1, Last BE must be 0."
        first_bit_high = first_be.bit_length() - 1
        return (first_bit_high - first_bit_low) + 1

    assert last_be != 0, "For Dword Count > 1, Last BE must not be 0."
    last_bit_high = last_be.bit_length() - 1

    # Bytes left out at the start of the first Dword and at the end of the last one.
    start_gap = first_bit_low
    end_gap = 3 - last_bit_high

    return (dword_count * 4) - start_gap - end_gap
