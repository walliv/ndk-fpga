# fs_axi_util.py: cocotbext-axi fixtures shared by the file shell's benches
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0
"""AXI3 AxLEN width, a RAM that answers SLVERR, random channel pauses and quiet logging for the
AXI and AXI-Lite models behind or in front of the DUTs."""

import logging
import random

from cocotbext.axi import AxiRam
from cocotbext.axi.axi_channels import AxiARSink, AxiAWSink

from fs_ctx import AXI_BEAT


def use_axi3_len():
    """AXI3 carries a 4-bit AxLEN; cocotbext-axi defaults to AXI4's 8 bits. Call before any bus binds."""
    for cls, field in ((AxiAWSink, "awlen"), (AxiARSink, "arlen")):
        cls._signal_widths = {**cls._signal_widths, field: 4}


def rand_pause(rng, prob):
    while True:
        yield rng.random() < prob


def pause_channels(dev, rng, prob):
    """Random pauses on the five channels of an AXI or AXI-Lite RAM."""
    chans = [dev.write_if.aw_channel, dev.write_if.w_channel, dev.write_if.b_channel,
             dev.read_if.ar_channel, dev.read_if.r_channel]
    for i, ch in enumerate(chans):
        ch.set_pause_generator(rand_pause(random.Random(rng.random() + i), prob))


def quiet(dev):
    """Only warnings from the read and write halves of an AXI or AXI-Lite model."""
    dev.write_if.log.setLevel(logging.WARNING)
    dev.read_if.log.setLevel(logging.WARNING)


class PoisonRam(AxiRam):
    """AxiRam answering SLVERR for writes to the 32 B beats in `poison` and, with `poison_reads`,
    for reads starting at an address in it."""

    def __init__(self, bus, clock, reset, size, poison, poison_reads=True):
        super().__init__(bus, clock, reset, reset_active_level=True, size=size)
        ram = self

        async def _read(address, length):
            if address in poison:
                raise ValueError("poisoned read")
            return ram.read(address % ram.size, length)

        async def _write(address, data):
            if address & ~(AXI_BEAT - 1) in poison:
                raise ValueError("poisoned write")
            ram.write(address % ram.size, data)

        if poison_reads:
            self.read_if._read = _read
        self.write_if._write = _write
