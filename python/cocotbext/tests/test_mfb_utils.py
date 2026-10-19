# test_mfb_utils.py: get_mfb_params on bus geometries described only by their signal widths
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

from math import log2
from types import SimpleNamespace

import pytest

from cocotbext.ofm.mfb.utils import get_mfb_params


def _bus(regions, region_size, block_size, item_width, meta_width=0):
    """Stand-in for a bound MFB bus: get_mfb_params only takes len() of its signals."""
    sof_pos_w = regions * max(1, int(log2(region_size)))
    eof_pos_w = regions * max(1, int(log2(region_size * block_size)))
    bus = SimpleNamespace(
        sof=[0] * regions,
        data=[0] * (regions * region_size * block_size * item_width),
        sof_pos=[0] * sof_pos_w,
        eof_pos=[0] * eof_pos_w,
    )
    if meta_width:
        bus.meta = [0] * (regions * meta_width)
    return bus


@pytest.mark.parametrize("geometry", [(1, 1, 8, 32), (2, 1, 8, 32), (1, 4, 8, 8), (1, 8, 8, 8), (4, 8, 8, 8)])
def test_inferred_geometry(geometry):
    assert get_mfb_params(_bus(*geometry, meta_width=12), None) == (*geometry, 12)
