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
           "PcieReqType"]


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
