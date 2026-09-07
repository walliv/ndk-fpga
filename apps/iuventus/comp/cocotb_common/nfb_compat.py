# nfb_compat.py: restores the cocotb 1.x names cocotbext.nfb still expects
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

# Import this before cocotbext.nfb. Both USER_CORE architectures' benches need it, so it lives
# here rather than being copied into each of them.
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

