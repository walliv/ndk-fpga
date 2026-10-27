# test_math.py: unit test of the math helpers of cocotbext
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import pytest

from cocotbext.ofm.utils.math import log2ceil


@pytest.mark.parametrize("n, bits", [(1, 0), (2, 1), (3, 2), (4, 2), (5, 3), (16, 4), (17, 5)])
def test_log2ceil(n, bits):
    assert log2ceil(n) == bits
