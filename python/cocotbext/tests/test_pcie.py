# test_pcie.py: unit test of the PCIe MFB metadata layouts and the byte count helper
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import itertools
import random
import re
from pathlib import Path

import pytest

from cocotbext.ofm.pcie import (CCMfbMeta, CCUser, CQMfbMeta, CQUser, CQUser256, PcieReqType, RCMfbMeta,
                                RQMfbMeta, pcie_byte_count)

META_PACK = Path(__file__).resolve().parents[3] / "comp" / "base" / "pkg" / "pcie_meta_pack.vhd"


def vhdl_constants():
    """Natural constants of pcie_meta_pack.vhd, evaluated in declaration order."""
    consts = {}
    for name, expr in re.findall(r"constant\s+(\w+)\s*:\s*natural\s*:=\s*([^;]+);", META_PACK.read_text()):
        consts[name] = eval(expr, {}, consts)
    return consts


# layout class, VHDL prefix, VHDL name of every field in layout order
LAYOUTS = [
    (CQMfbMeta, "CQ", ["HEADER", "PREFIX", "BAR", "FBE", "LBE", "TPH_PRESENT", "TPH_TYPE", "TPH_ST_TAG", "BE"]),
    (RQMfbMeta, "RQ", ["HEADER", "PREFIX", "FBE", "LBE"]),
    (CCMfbMeta, "CC", ["HEADER", "PREFIX"]),
    (RCMfbMeta, "RC", ["HEADER", "PREFIX"]),
]


@pytest.mark.parametrize("layout, prefix, names", LAYOUTS, ids=[x[1] for x in LAYOUTS])
def test_field_offsets_match_pcie_meta_pack(layout, prefix, names):
    consts = vhdl_constants()
    for (field, offset), name in zip(layout.offsets().items(), names):
        assert offset == consts[f"PCIE_{prefix}_META_{name}_O"], f"{prefix} field {field}"
    assert len(layout.items) == len(names)
    assert consts[f"PCIE_{prefix}_META_WIDTH"] == len(layout())


@pytest.mark.parametrize("layout", [x[0] for x in LAYOUTS])
def test_serialize_roundtrip(layout):
    rnd = random.Random(random.getrandbits(32))
    meta = layout()
    for field, width in layout.items:
        setattr(meta, field, rnd.getrandbits(width))

    back = layout.deserialize(meta.serialize())

    assert all(getattr(back, field) == getattr(meta, field) for field, _ in layout.items)


def test_cq_user_follows_the_512_bit_tuser_of_pg213():
    offsets = CQUser.offsets()

    assert (offsets["byte_en"], offsets["sop0"], offsets["eop0"], offsets["discontiune"]) == (16, 80, 86, 96)
    assert (offsets["tph_present"], offsets["tph_type"], offsets["tph_sh_tag"], offsets["parity"]) == (97, 99, 103, 119)
    assert len(CQUser()) == 183


def test_cq_user_256_follows_the_256_bit_tuser_of_pg213():
    offsets = CQUser256.offsets()

    assert (offsets["byte_en"], offsets["sop"], offsets["tph_present"], offsets["tph_st_tag"]) == (8, 40, 42, 45)
    assert offsets["parity"] == 53 and len(CQUser256()) == 85


def test_cc_user_follows_the_512_bit_tuser_of_pg213():
    offsets = CCUser.offsets()

    assert (offsets["sop_ptr0"], offsets["eop0"], offsets["eop_ptr0"], offsets["eop_ptr1"]) == (2, 6, 8, 12)
    assert offsets["parity"] == 17 and len(CCUser()) == 81


def test_request_types_match_the_amd_transaction_type_table():
    assert [PcieReqType(i).name for i in range(16)] == [
        "MRD", "MWR", "IORD", "IOWR", "MFETCH_AND_ADD", "MSWAP", "MCOMPARE_SWAP", "LOC_RD",
        "TYPE0_CONF_RD", "TYPE1_CONF_RD", "TYPE0_CONF_WR", "TYPE1_CONF_WR", "ANY_MSG", "VENDOR_MSG",
        "ATS_MSG", "RSVD",
    ]


def expand(pattern):
    """Every 4-bit value matching a pattern of 0, 1 and x, MSB first."""
    return [int("".join(bits), 2) for bits in itertools.product(*[("0", "1") if c == "x" else (c,) for c in pattern])]


# first_be, last_be and the total byte count with its Dword count dependence, as printed in the byte count
# table of the AMD UltraScale+ PCIe integrated block (PG213)
SINGLE_DWORD = [("1xx1", 4), ("01x1", 3), ("1x10", 3), ("0011", 2), ("0110", 2), ("1100", 2),
                ("0001", 1), ("0010", 1), ("0100", 1), ("1000", 1), ("0000", 1)]
MULTI_DWORD = [("xxx1", "1xxx", 0), ("xxx1", "01xx", 1), ("xxx1", "001x", 2), ("xxx1", "0001", 3),
               ("xx10", "1xxx", 1), ("xx10", "01xx", 2), ("xx10", "001x", 3), ("xx10", "0001", 4),
               ("x100", "1xxx", 2), ("x100", "01xx", 3), ("x100", "001x", 4), ("x100", "0001", 5),
               ("1000", "1xxx", 3), ("1000", "01xx", 4), ("1000", "001x", 5), ("1000", "0001", 6)]


@pytest.mark.parametrize("pattern, count", SINGLE_DWORD)
def test_byte_count_of_a_single_dword(pattern, count):
    for first_be in expand(pattern):
        assert pcie_byte_count(1, first_be, 0) == count


@pytest.mark.parametrize("first_pattern, last_pattern, missing", MULTI_DWORD)
@pytest.mark.parametrize("dword_count", [2, 3, 17, 1024])
def test_byte_count_of_several_dwords(first_pattern, last_pattern, missing, dword_count):
    for first_be, last_be in itertools.product(expand(first_pattern), expand(last_pattern)):
        assert pcie_byte_count(dword_count, first_be, last_be) == dword_count * 4 - missing


def test_byte_count_of_an_empty_request():
    assert pcie_byte_count(0, 0, 0) == 0


@pytest.mark.parametrize("dword_count, first_be, last_be", [(2, 0, 0), (1, 0b1111, 0b1111), (2, 0b1111, 0)])
def test_byte_count_rejects_illegal_byte_enables(dword_count, first_be, last_be):
    with pytest.raises(AssertionError):
        pcie_byte_count(dword_count, first_be, last_be)
