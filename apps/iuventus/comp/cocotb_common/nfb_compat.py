# nfb_compat.py: restores the cocotb 1.x names cocotbext.nfb still expects
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

# The USER_CORE benches call load_cocotbext_nfb() once after their other imports; it patches cocotb and then imports cocotbext.nfb.
# It lives here rather than being copied into each bench.
import functools
import inspect

import cocotb

# cocotbext.nfb calls cocotb.external/function, gone from cocotb 2.0's top level; restore them
# from cocotb._bridge before importing it. Its servicers are old-style generators, and resume()
# cannot await a bare one (TypeError), so wrap them first.
import cocotb._bridge as _cocotb_bridge


def _generator_compat_resume(func):
    if not inspect.isgeneratorfunction(func):
        return _cocotb_bridge.resume(func)

    @functools.wraps(func)
    async def _driven(*args, **kwargs):
        gen = func(*args, **kwargs)
        sent = None
        while True:
            try:
                yielded = gen.send(sent)
            except StopIteration as stop:
                return stop.value
            sent = await yielded

    return _cocotb_bridge.resume(_driven)


if not hasattr(cocotb, "external"):
    cocotb.external = _cocotb_bridge.bridge
    cocotb.function = _generator_compat_resume


def load_cocotbext_nfb():
    """Applies the patch above, then imports and returns cocotbext.nfb."""
    import importlib

    return importlib.import_module("cocotbext.nfb")
