# test_mfb_utils.py: unit test of the MFB geometry and frame helpers
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

from types import SimpleNamespace

import pytest

from cocotbext.ofm.mfb.protocol import MfbParams
from cocotbext.ofm.mfb.utils import get_mfb_params, region_frame_event
from stubs import StubSignal, mfb_widths


def _bus(regions, region_size, block_size, item_width, meta_width=0):
    """Stand-in for a bound MFB bus."""
    widths = mfb_widths(regions, region_size, block_size, item_width)
    bus = SimpleNamespace(**{sig.lower(): StubSignal(widths[sig]) for sig in ("SOF", "DATA", "SOF_POS", "EOF_POS")})
    if meta_width:
        bus.meta = StubSignal(regions * meta_width)
    return bus


@pytest.mark.parametrize("sof, eof, sof_item, eof_item, event", [
    (1, 1, 2, 5, "whole"), (1, 1, 2, 2, "whole"), (1, 1, 4, 3, "end_start"),
    (1, 0, 0, 0, "start"), (0, 1, 0, 0, "end"), (0, 0, 0, 0, None),
])
def test_region_frame_event(sof, eof, sof_item, eof_item, event):
    assert region_frame_event(sof, eof, sof_item, eof_item) == event


@pytest.mark.parametrize("geometry, pos_widths", [((2, 4, 8, 8), (2, 5)), ((2, 1, 8, 32), (0, 3))])
def test_params_of_a_bus(geometry, pos_widths):
    params = MfbParams.from_bus(_bus(*geometry))

    assert (params.regions, params.region_size, params.block_size, params.item_width) == geometry
    assert (params.sof_pos_width, params.eof_pos_width) == pos_widths
    assert params.word_width == len(_bus(*geometry).data)


def test_params_of_a_bus_without_position_signals():
    bus = SimpleNamespace(sof=StubSignal(2), data=StubSignal(64))

    assert MfbParams.from_bus(bus) == MfbParams(2, 1, 1, 32)


@pytest.mark.parametrize("geometry", [(1, 1, 8, 32), (2, 1, 8, 32), (1, 4, 8, 8), (1, 8, 8, 8), (4, 8, 8, 8)])
def test_inferred_geometry(geometry):
    assert get_mfb_params(_bus(*geometry, meta_width=12), None) == (*geometry, 12, "sof")


def test_explicit_parameters_override_the_inferred_ones():
    params = dict(meta_width=3, os_vld_with="eof")

    assert get_mfb_params(_bus(2, 4, 8, 8, meta_width=12), params) == (2, 4, 8, 8, 3, "eof")


def test_parameters_that_disagree_with_the_signals_are_rejected():
    with pytest.raises(Exception):
        get_mfb_params(_bus(2, 4, 8, 8), dict(regions=3))
