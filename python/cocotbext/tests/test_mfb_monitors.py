# test_mfb_monitors.py: unit test of the MFB monitor on stub signals
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import logging
from dataclasses import dataclass

import cocotb
import pytest
from cocotb.types import LogicArray

from cocotbext.ofm.mfb.monitors import MFBMonitor
from cocotbext.ofm.mfb.transaction import MfbTransaction, MfbTransactionWithMeta
from stubs import mfb_widths

# 2 regions of 4 blocks, each block holding 2 items of 8 bits; META of 4 bits and ID of 3 bits per region
REGIONS, REGION_SIZE, BLOCK_SIZE, ITEM_WIDTH = 2, 4, 2, 8
REGION_BYTES = REGION_SIZE * BLOCK_SIZE * ITEM_WIDTH // 8
WIDTHS = dict(mfb_widths(REGIONS, REGION_SIZE, BLOCK_SIZE, ITEM_WIDTH), META=REGIONS * 4, ID=REGIONS * 3)


class BitStub:
    """A signal handle holding a bit string, read as the simulator's string or as a LogicArray."""

    def __init__(self, width):
        self.binstr = "0" * width
        self._handle = self

    def get_signal_val_binstr(self):
        return self.binstr

    @property
    def value(self):
        return LogicArray(self.binstr)

    def __len__(self):
        return len(self.binstr)


class Entity:
    _name = "dut"
    _log = logging.getLogger("test_mfb_monitors")

    def __init__(self):
        for sig, width in WIDTHS.items():
            setattr(self, f"RX_{sig}", BitStub(width))


class IdMonitor(MFBMonitor):
    _optional_signals = ["meta", "id"]


@dataclass(slots=True)
class IdTransaction(MfbTransactionWithMeta):
    id: int = 0


class Task:
    def cancel(self):
        pass


@pytest.fixture(autouse=True)
def no_scheduler(monkeypatch):
    def start_soon(coro):
        coro.close()
        return Task()
    monkeypatch.setattr(cocotb, "start_soon", start_soon)


def make(monitor=MFBMonitor, **kwargs):
    entity = Entity()
    frames = []
    mon = monitor(entity, "RX", None, start=False, **kwargs)
    mon.add_callback(frames.append)
    return entity, mon, frames


def fields(**per_region):
    """Bit string of per-region fields of width `w`, region 0 lowest; a None field is X."""
    width = per_region.pop("w")
    return "".join("X" * width if per_region.get(f"r{r}") is None else format(per_region[f"r{r}"], f"0{width}b")
                   for r in reversed(range(REGIONS)))


def word(entity, mon, data, sof="00", eof="00", sof_pos="XXXX", eof_pos="XXXXXX", meta="XXXXXXXX", id="XXXXXX"):
    data = data.ljust(2 * REGION_BYTES, b"\x00")
    values = dict(SRC_RDY="1", DST_RDY="1", DATA=format(int.from_bytes(data, "little"), f"0{WIDTHS['DATA']}b"),
                  SOF=sof, EOF=eof, SOF_POS=sof_pos, EOF_POS=eof_pos, META=meta, ID=id)
    for sig, value in values.items():
        getattr(entity, f"RX_{sig}").binstr = value
    mon.monitor_cycle()


def test_frames_span_words_and_share_a_region():
    entity, mon, frames = make(trans_type=MfbTransactionWithMeta)
    a, b = bytes(range(20)), bytes(range(100, 108))
    # A ends in item 3 of the second word, B starts in block 2 there and ends in item 3 of region 1
    word(entity, mon, a[:16], sof="01", sof_pos=fields(w=2, r0=0), meta=fields(w=4, r0=5))
    word(entity, mon, a[16:] + b, sof="01", eof="11", sof_pos=fields(w=2, r0=2), eof_pos=fields(w=3, r0=3, r1=3),
         meta=fields(w=4, r0=9))

    assert [(bytes(f.data), f.meta) for f in frames] == [(a, 5), (b, 9)]
    assert mon.frame_cnt == 2 and mon.item_cnt == len(a) + len(b)


def test_x_outside_the_fields_in_use_spares_the_frame():
    entity, mon, frames = make(trans_type=MfbTransactionWithMeta)
    data = bytes(range(6))
    word(entity, mon, data, sof="01", eof="01", sof_pos=fields(w=2, r0=0), eof_pos=fields(w=3, r0=5),
         meta=fields(w=4, r0=3))

    assert [(bytes(f.data), f.meta) for f in frames] == [(data, 3)]


def test_meta_valid_with_eof():
    entity, mon, frames = make(trans_type=MfbTransactionWithMeta, meta_vld_with="eof")
    data = bytes(range(2 * REGION_BYTES))
    word(entity, mon, data, sof="01", eof="10", sof_pos=fields(w=2, r0=0), eof_pos=fields(w=3, r1=7),
         meta=fields(w=4, r0=1, r1=6))

    assert [(bytes(f.data), f.meta) for f in frames] == [(data, 6)]


def test_a_transaction_without_meta_ignores_it():
    entity, mon, frames = make(trans_type=MfbTransaction)
    data = bytes(range(4))
    word(entity, mon, data, sof="01", eof="01", sof_pos=fields(w=2, r0=0), eof_pos=fields(w=3, r0=3))

    assert [bytes(f.data) for f in frames] == [data]
    assert not hasattr(frames[0], "meta")


def test_bytes_and_other_optional_signals():
    entity, mon, frames = make()
    data = bytes(range(4))
    word(entity, mon, data, sof="01", eof="01", sof_pos=fields(w=2, r0=0), eof_pos=fields(w=3, r0=3),
         meta=fields(w=4, r0=2))
    assert frames == [data]

    entity, mon, frames = make(monitor=IdMonitor, trans_type=IdTransaction)
    word(entity, mon, data, sof="01", eof="01", sof_pos=fields(w=2, r0=0), eof_pos=fields(w=3, r0=3),
         meta=fields(w=4, r0=2), id=fields(w=3, r0=5))
    assert [(bytes(f.data), f.meta, f.id) for f in frames] == [(data, 2, 5)]
