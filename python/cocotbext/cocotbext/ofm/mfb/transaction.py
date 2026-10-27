# SPDX-License-Identifier: BSD-3-Clause
# Copyright (C) 2025 CESNET z. s. p. o.
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>

from dataclasses import dataclass
from ..base.transaction import Transaction
from ..utils.hex_formatter import format_bytes


@dataclass(slots=True)
class MfbTransaction(Transaction):
    data: bytes = b""

    def __repr__(self) -> str:
        """Return formatted hex representation of the transaction."""
        # MfbTransaction does not have meta attribute, only MfbTransactionWithMeta does
        if hasattr(self, "data") and self.data:
            return format_bytes(self.data, label="DATA")
        return super().__repr__()


@dataclass(slots=True)
class MfbTransactionWithMeta(MfbTransaction):
    meta: int = 0

    def __repr__(self) -> str:
        """Return formatted hex representation of the transaction."""
        # Convert meta to bytes - handle 0 as special case (0.bit_length() returns 0)
        meta_bytes = (
            self.meta.to_bytes(1, byteorder='big') if self.meta == 0
            else self.meta.to_bytes((self.meta.bit_length() + 7) // 8, byteorder='big')
        )
        ret = format_bytes(meta_bytes, label="META")
        ret += "\n"

        if hasattr(self, "data") and self.data:
            ret += format_bytes(self.data, label="DATA")

        return ret


@dataclass(slots=True)
class MfbWord(Transaction):
    """One MFB word given signal by signal, e.g. for a META that differs between the regions of a frame.

    Values span the whole bus: SOF and EOF are region masks, positions and META their region fields, region 0 lowest.
    None leaves a field X, and `be` None enables the bytes of the frames.
    """
    data    : int = 0
    sof     : int = 0
    eof     : int = 0
    sof_pos : int | None = None
    eof_pos : int | None = None
    meta    : int | None = None
    be      : int | None = None
