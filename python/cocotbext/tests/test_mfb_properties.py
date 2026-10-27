# test_mfb_properties.py: unit test of the MFB protocol checker on stub signals
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import pytest

from cocotbext.ofm.mfb.monitors import MFBProtocolError
from cocotbext.ofm.mfb.properties import MFB_RULES, MFBProperty, attach_mfb_properties, final_check_all
from stubs import StubSignal, mfb_widths

# 2 regions of 4 blocks, each block holding 2 items of 8 bits
REGIONS, REGION_SIZE, BLOCK_SIZE, ITEM_WIDTH = 2, 4, 2, 8
WIDTHS = mfb_widths(REGIONS, REGION_SIZE, BLOCK_SIZE, ITEM_WIDTH)
IDLE = dict(src_rdy="0", dst_rdy="1", sof="00", eof="00", sof_pos="0000", eof_pos="000000", data="0" * 128)


class Log:
    def __init__(self):
        self.errors = []

    def error(self, msg, *args):
        self.errors.append(msg)

    def info(self, msg, *args):
        pass

    def debug(self, msg, *args):
        pass


class Entity:
    """Entity with the signals of an MFB interface named `name`."""

    def __init__(self, *names):
        self._log = Log()
        for name in names:
            for sig, width in WIDTHS.items():
                setattr(self, f"{name}_{sig}", StubSignal(width))


def region_field(width, **per_region):
    """Bit string of a per-region field, region 0 in the least significant position."""
    out = ""
    for r in reversed(range(REGIONS)):
        out += format(per_region.get(f"r{r}", 0), f"0{width}b")
    return out


def cycle(**fields):
    word = dict(IDLE)
    word.update(fields)
    return word


def play(prop, entity, cycles, name="RX"):
    for word in cycles:
        for sig, value in word.items():
            getattr(entity, f"{name}_{sig.upper()}").binstr = value
        prop.check_cycle()


def make(**kwargs):
    entity = Entity("RX")
    prop = MFBProperty(entity, "RX", None, start=False, **kwargs)
    return entity, prop


def whole_frame(region=0, last_item=3):
    sof = "".join("1" if r == region else "0" for r in reversed(range(REGIONS)))
    return cycle(src_rdy="1", sof=sof, eof=sof, eof_pos=region_field(3, **{f"r{region}": last_item}))


def open_frame(region=0):
    sof = "".join("1" if r == region else "0" for r in reversed(range(REGIONS)))
    return cycle(src_rdy="1", sof=sof)


def close_frame(region=0, last_item=3):
    eof = "".join("1" if r == region else "0" for r in reversed(range(REGIONS)))
    return cycle(src_rdy="1", eof=eof, eof_pos=region_field(3, **{f"r{region}": last_item}))


def test_geometry_inferred_from_widths():
    _, prop = make()
    assert (prop._regions, prop._region_size, prop._block_size, prop._item_width) == \
        (REGIONS, REGION_SIZE, BLOCK_SIZE, ITEM_WIDTH)


def test_geometry_of_a_bus_without_position_signals():
    entity = Entity("RX")
    del entity.RX_SOF_POS, entity.RX_EOF_POS
    entity.RX_DATA = StubSignal(REGIONS * 32)
    prop = MFBProperty(entity, "RX", None, start=False)
    assert (prop._regions, prop._region_size, prop._block_size, prop._item_width) == (REGIONS, 1, 1, 32)


def test_legal_traffic_passes():
    entity, prop = make()
    play(prop, entity, [
        whole_frame(0), whole_frame(1), IDLE,
        open_frame(0), cycle(src_rdy="1"), close_frame(1),
        cycle(src_rdy="1", dst_rdy="0", sof="01", sof_pos=region_field(2, r0=1)),
        cycle(src_rdy="1", dst_rdy="0", sof="01", sof_pos=region_field(2, r0=1)),
        cycle(src_rdy="1", sof="01", sof_pos=region_field(2, r0=1)),
        close_frame(0),
    ])
    prop.final_check()
    assert prop.frames == 4 and not prop.errors


def test_straddling_start_after_eof_is_legal_when_allowed():
    entity, prop = make(straddling=True)
    play(prop, entity, [
        open_frame(0),
        cycle(src_rdy="1", sof="10", eof="01", eof_pos=region_field(3, r0=2)),
        close_frame(1),
    ])
    prop.final_check()


@pytest.mark.parametrize("rule, cycles, kwargs", [
    ("src_rdy_undefined", [cycle(src_rdy="X")], {}),
    ("dst_rdy_undefined", [cycle(src_rdy="1", dst_rdy="X")], {}),
    ("sof_undefined", [cycle(src_rdy="1", sof="0X")], {}),
    ("eof_undefined", [cycle(src_rdy="1", sof="01", eof="XX")], {}),
    ("sof_pos_undefined", [cycle(src_rdy="1", sof="01", sof_pos="000X")], {}),
    ("eof_pos_undefined", [open_frame(0), cycle(src_rdy="1", eof="01", eof_pos="00000X")], {}),
    ("src_rdy_dropped", [cycle(src_rdy="1", dst_rdy="0"), cycle(src_rdy="0", dst_rdy="0")], {}),
    ("ctrl_changed", [
        cycle(src_rdy="1", dst_rdy="0", sof="01", sof_pos="0001"),
        cycle(src_rdy="1", dst_rdy="0", sof="01", sof_pos="0010"),
    ], {}),
    ("data_changed", [
        cycle(src_rdy="1", dst_rdy="0", data="1" * 128),
        cycle(src_rdy="1", dst_rdy="0", data="0" * 128),
    ], {}),
    ("sof_pos_range", [cycle(src_rdy="1", sof="01", sof_pos="0011")],
     dict(mfb_params=dict(regions=REGIONS, region_size=3, block_size=BLOCK_SIZE, item_width=ITEM_WIDTH))),
    ("eof_pos_range", [open_frame(0), close_frame(0, last_item=7)],
     dict(mfb_params=dict(regions=REGIONS, region_size=3, block_size=BLOCK_SIZE, item_width=ITEM_WIDTH))),
    ("sof_while_frame_open", [open_frame(0), open_frame(0)], {}),
    ("sof_while_frame_open", [open_frame(0), whole_frame(1)], {}),
    ("eof_without_sof", [close_frame(0)], {}),
    ("eof_without_sof", [cycle(src_rdy="1", sof="01", eof="01", sof_pos="0010", eof_pos="000001")], {}),
    ("straddling", [open_frame(0), cycle(src_rdy="1", sof="10")], dict(straddling=True)),
    ("no_straddling", [open_frame(0), cycle(src_rdy="1", sof="10")], dict(straddling=False)),
])
def test_rule_fires(rule, cycles, kwargs):
    entity, prop = make(max_errors=0, **kwargs)
    play(prop, entity, cycles)
    assert rule in {err[1] for err in prop.errors}
    assert rule in MFB_RULES


@pytest.mark.parametrize("rule, cycles", [
    ("src_rdy_dropped", [cycle(src_rdy="1", dst_rdy="0"), cycle(src_rdy="0", dst_rdy="0")]),
    ("eof_without_sof", [close_frame(0)]),
])
def test_disabled_rule_is_silent(rule, cycles):
    entity, prop = make(max_errors=0, disable=[rule])
    play(prop, entity, cycles)
    assert rule not in {err[1] for err in prop.errors}
    prop2_entity, prop2 = make(max_errors=0)
    prop2.disable_rule(rule)
    play(prop2, prop2_entity, cycles)
    assert rule not in {err[1] for err in prop2.errors}


def test_first_violation_raises_by_default():
    entity, prop = make()
    with pytest.raises(MFBProtocolError, match="eof_without_sof"):
        play(prop, entity, [close_frame(0)])


def test_unknown_rule_is_rejected():
    entity = Entity("RX")
    with pytest.raises(ValueError):
        MFBProperty(entity, "RX", None, start=False, disable=["no_such_rule"])


def test_stream_ending_inside_a_frame_fails_the_final_check():
    entity, prop = make(max_errors=0)
    play(prop, entity, [open_frame(0)])
    with pytest.raises(MFBProtocolError):
        prop.final_check()


def test_reset_clears_the_open_frame():
    entity = Entity("RX")
    entity.RST = StubSignal(1)
    prop = MFBProperty(entity, "RX", None, reset=entity.RST, start=False)
    play(prop, entity, [open_frame(0)])
    entity.RST.binstr = "1"
    play(prop, entity, [close_frame(0)])
    assert not prop.errors and not prop.frame_open


def test_attach_covers_only_complete_mfb_interfaces():
    entity = Entity("RX", "TX")
    entity.OTHER_SRC_RDY = StubSignal(1)
    props = attach_mfb_properties(entity, None, exclude=("TX",), start=False)
    assert list(props) == ["RX"]
    play(props["RX"], entity, [open_frame(0), close_frame(0)])
    final_check_all(props)


def test_final_check_all_reports_every_failing_interface():
    entity = Entity("RX", "TX")
    props = attach_mfb_properties(entity, None, start=False, max_errors=0)
    play(props["RX"], entity, [close_frame(0)], name="RX")
    play(props["TX"], entity, [close_frame(0)], name="TX")
    with pytest.raises(MFBProtocolError) as exc:
        final_check_all(props)
    assert "MFB[RX]" in str(exc.value) and "MFB[TX]" in str(exc.value)
