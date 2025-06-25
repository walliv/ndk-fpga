# SPDX-License-Identifier: BSD-3-Clause
# Copyright (C) 2024 CESNET z. s. p. o.
# Author(s): Daniel Kondys <kondys@cesnet.cz>

import sys

from dataclasses import dataclass
from ..base.transaction import Transaction


@dataclass
class MvbTransaction(Transaction):
    """Base class for MVB Transactions with configurable data items"""

    attrs = []

    def __init__(self):
        for i in self.attrs:
            setattr(self, i, 0)

    def __str__(self):
        return f"{[(attr, getattr(self, attr)) for attr in self.attrs]}"

    def __repr__(self):
        return f"{[(attr, getattr(self, attr)) for attr in self.attrs]}"

    def __eq__(self, other):
        if isinstance(other, MvbTransaction):
            for attr in self.attrs:
                if getattr(self, attr) != getattr(other, attr):
                    return False
            return True
        return NotImplemented

    @classmethod
    def from_bytes(cls, tr: bytes):
        """Class method for compatibility with versions when MVB driver accepted only bytes.
           Returns a MvbTransaction object.
        """

        mvb_tr = MvbTrClassic()
        mvb_tr.data = int.from_bytes(tr, byteorder=sys.byteorder)
        return mvb_tr


class MvbTrClassic(MvbTransaction):
    attrs = ["data"]


class MvbTrClassicWithMeta(MvbTransaction):
    attrs = ["data", "meta"]


class MvbTrAddressWithMeta(MvbTransaction):
    attrs = ["addr", "meta"]
