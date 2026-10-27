# regs.py: MI register map of the DMA_CALYPTE channels and a Python mirror of written values
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

from cocotb.triggers import Lock

from cocotbext.ofm.mi.drivers import MIRequestDriver

RX_BASE = 0x00000000
TX_BASE = 0x00200000
CH_STRIDE = 0x80

# name: (offset, width in bits); the RX and TX UVM register models (env/reg_channel.sv,
# dma_regs/reg_channel.sv). 64-bit registers are two 32-bit accesses, low word first.
RX_MAP = {
    "control": (0x00, 1), "status": (0x04, 1), "exper": (0x08, 1),
    "sdp": (0x10, 16), "shp": (0x14, 16), "hdp": (0x18, 16), "hhp": (0x1C, 16),
    "upd_timeout": (0x20, 32), "data_base": (0x40, 64), "hdr_base": (0x48, 64), "update_base": (0x50, 64),
    "data_mask": (0x58, 16), "hdr_mask": (0x5C, 16),
    "sent_pkts": (0x60, 64), "sent_bytes": (0x68, 64), "disc_pkts": (0x70, 64), "disc_bytes": (0x78, 64),
}


def tx_map(ptr_width):
    return {
        "control": (0x00, 1), "status": (0x04, 1), "exper": (0x08, 1),
        "sdp": (0x10, ptr_width), "shp": (0x14, ptr_width), "hdp": (0x18, ptr_width), "hhp": (0x1C, ptr_width),
        "upd_timeout": (0x20, 32), "update_base": (0x50, 64),
        "data_mask": (0x58, ptr_width), "hdr_mask": (0x5C, ptr_width),
        "sent_pkts": (0x60, 64), "sent_bytes": (0x68, 64), "disc_pkts": (0x70, 64), "disc_bytes": (0x78, 64),
    }


COUNTERS = ("sent_pkts", "sent_bytes", "disc_pkts", "disc_bytes")


class MiBus:
    """One MI master shared by every register user; MIRequestDriver is not re-entrant, so a Lock
    serialises the accesses as the UVM register sequencer does."""

    def __init__(self, dut, clock):
        self.drv = MIRequestDriver(dut, "MI", clock)
        self.lock = Lock()
        self.accesses = 0

    async def write32(self, addr, value):
        async with self.lock:
            self.accesses += 1
            await self.drv.write32(addr, value)

    async def write64(self, addr, value):
        """A 64-bit software write as the 32-bit MI bus gets it: low word, then high word, nothing in between."""
        async with self.lock:
            self.accesses += 2
            await self.drv.write64(addr, value)

    async def read32(self, addr):
        async with self.lock:
            self.accesses += 1
            return await self.drv.read32(addr)


class ChannelRegs:
    """Registers of one channel. `get` returns the UVM mirror (desired) value: the last value
    written or read. `control_hooks` run before a write of control with bit 0 set, like the
    uvm_reg_cbs pre_write callbacks of the models and the TX host driver."""

    def __init__(self, mi, base, regmap):
        self.mi = mi
        self.base = base
        self.map = regmap
        self.mirror = {}
        self.control_hooks = []

    def get(self, name):
        return self.mirror.get(name, 0)

    async def write(self, name, value):
        off, width = self.map[name]
        value &= (1 << width) - 1
        if name == "control" and value & 1:
            for hook in self.control_hooks:
                hook()
        self.mirror[name] = value
        await self.mi.write32(self.base + off, value)
        if width == 64:
            await self.mi.write32(self.base + off + 4, value >> 32)

    async def write_sp(self, sdp, shp):
        """SDP | SHP << 32 as one 64-bit write (nc_ndp_ctrl_sp_flush)."""
        assert self.map["shp"][0] == self.map["sdp"][0] + 4
        sdp &= (1 << self.map["sdp"][1]) - 1
        shp &= (1 << self.map["shp"][1]) - 1
        self.mirror["sdp"], self.mirror["shp"] = sdp, shp
        await self.mi.write64(self.base + self.map["sdp"][0], sdp | (shp << 32))

    async def write_words(self, name, low, high):
        """A 64-bit register written as two explicit words (the counter strobes)."""
        off, width = self.map[name]
        assert width == 64
        await self.mi.write32(self.base + off, low)
        await self.mi.write32(self.base + off + 4, high)

    async def read(self, name):
        off, width = self.map[name]
        value = await self.mi.read32(self.base + off)
        if width == 64:
            value |= (await self.mi.read32(self.base + off + 4)) << 32
        value &= (1 << width) - 1
        self.mirror[name] = value
        return value
