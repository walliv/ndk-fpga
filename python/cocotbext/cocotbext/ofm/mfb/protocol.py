# SPDX-License-Identifier: BSD-3-Clause
# Copyright (C) 2026 CESNET z. s. p. o.
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Ondrej Schwarz <ondrejschwarz@cesnet.cz>
#            Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>

from cocotb.types import Logic
from cocotbext.ofm.base.types import LogicArray, LogicArray2D
from cocotbext.ofm.base.protocol import BusProtocol, parameter, generic, signal, optional_signal
from cocotbext.ofm.mfb.utils import get_mfb_params
from math import log2
from dataclasses import dataclass


def _serialized(value):
    """The flat value of a per-region signal, which a driver gives as a LogicArray2D or already flat."""
    return value.serialize() if isinstance(value, LogicArray2D) else value


@dataclass
class MfbParams:
    regions     : int = 0
    region_size : int = 0
    block_size  : int = 0
    item_width  : int = 0

    @property
    def region_items(self) -> int:
        return self.region_size * self.block_size

    @property
    def word_width(self) -> int:
        return self.regions * self.region_items * self.item_width

    @property
    def sof_pos_width(self) -> int:
        """Bits of the SOF_POS field of one region, 0 for a region of one block."""
        return (self.region_size - 1).bit_length()

    @property
    def eof_pos_width(self) -> int:
        """Bits of the EOF_POS field of one region, 0 for a region of one item."""
        return (self.region_items - 1).bit_length()

    @classmethod
    def from_bus(cls, bus, params_dic=None) -> "MfbParams":
        """Geometry of a bus as get_mfb_params infers it from the signal widths and `params_dic`."""
        return cls(*get_mfb_params(bus, params_dic)[:4])


class MfbProtocol(BusProtocol):
    REGIONS     : int = generic()
    REGION_SIZE : int = generic()
    BLOCK_SIZE  : int = generic()
    ITEM_WIDTH  : int = generic()

    @parameter
    def WORD_WIDTH(self):
        return self.REGIONS * self.REGION_SIZE * self.BLOCK_SIZE * self.ITEM_WIDTH

    @parameter
    def SOF_POS_WIDTH(self):
        return self.REGIONS * log2(self.REGION_SIZE)

    @parameter
    def EOF_POS_WIDTH(self):
        return self.REGIONS * log2(self.REGION_SIZE * self.BLOCK_SIZE)

    @parameter
    def META_WIDTH(self):
        return self.dut.META_WIDTH

    @signal
    def DATA(self, sigval) -> LogicArray:
        return sigval

    @DATA.write()
    def DATA(self, signal, value: LogicArray | bytearray | bytes | int) -> None:
        # an int converts straight to the bit string the simulator takes, without a LogicArray of the whole word
        if isinstance(value, bytearray) or isinstance(value, bytes):
            value = int.from_bytes(value, byteorder="little")
        signal.value = value

    @signal
    def SOF_POS(self, sigval) -> LogicArray:
        return sigval

    @SOF_POS.write()
    def SOF_POS(self, signal, value: LogicArray2D | LogicArray | str | int) -> None:
        signal.value = _serialized(value)

    @signal
    def EOF_POS(self, sigval) -> LogicArray:
        return sigval

    @EOF_POS.write()
    def EOF_POS(self, signal, value: LogicArray2D | LogicArray | str | int) -> None:
        signal.value = _serialized(value)

    SOF     : LogicArray = signal()
    EOF     : LogicArray = signal()
    SRC_RDY : Logic      = signal()
    DST_RDY : Logic      = signal()

    @optional_signal.read(put_with="SOF")
    def META(self, sigval: LogicArray) -> LogicArray:
        return sigval

    @META.write(put_with="SOF")
    def META(self, signal, value: LogicArray2D | LogicArray | str | int) -> None:
        signal.value = _serialized(value)

    # one bit per byte of DATA, set where the byte is valid
    BE      : LogicArray = optional_signal()
