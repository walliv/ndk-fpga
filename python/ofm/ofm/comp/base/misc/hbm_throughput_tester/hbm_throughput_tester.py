# Copyright 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

"""Register access for HBM_THROUGHPUT_TESTER.

The tester runs in the HBM port clock domain and counts beats against cycles there, so a rate
derived from these counters is the port's own. The host clock is used only to decide how long to
leave the generator running -- never as a divisor, since a rate taken against wall time would
absorb every pause between register reads.
"""

from dataclasses import dataclass
from enum import IntEnum
from time import sleep

import nfb


class TesterReg(IntEnum):
    CTRL      = 0x00
    STATUS    = 0x04
    BURST_LEN = 0x08
    PORT_EN   = 0x0C
    ADDR_MASK = 0x10


class CtrlBit(IntEnum):
    RUN   = 0
    CLR   = 1
    RD_EN = 2
    WR_EN = 3


# Per-port counter block. Each counter is 48 b, read as a low and a high word except the two
# stall counters, which are read low-word only.
CNT_BASE   = 0x40
CNT_STRIDE = 0x20

CNT_CYCLES   = 0x00
CNT_R_BEATS  = 0x08
CNT_W_BEATS  = 0x10
CNT_AR_STALL = 0x18
CNT_AW_STALL = 0x1C

# One HBM port is 256 b wide; the clock it runs at sets what a beat is worth.
BEAT_BYTES  = 32
HBM_CLK_HZ  = 450e6
PORT_GBPS   = BEAT_BYTES * HBM_CLK_HZ / 1e9      # 14.4 GB/s


@dataclass
class PortResult:
    port: int
    cycles: int
    r_beats: int
    w_beats: int
    ar_stall: int
    aw_stall: int

    @property
    def read_gbps(self) -> float:
        return self.r_beats * BEAT_BYTES / (self.cycles / HBM_CLK_HZ) / 1e9 if self.cycles else 0.0

    @property
    def write_gbps(self) -> float:
        return self.w_beats * BEAT_BYTES / (self.cycles / HBM_CLK_HZ) / 1e9 if self.cycles else 0.0

    @property
    def total_gbps(self) -> float:
        return self.read_gbps + self.write_gbps

    @property
    def utilisation(self) -> float:
        """Share of the port's 14.4 GB/s wire rate that both directions together used."""
        return self.total_gbps / PORT_GBPS


class HbmThroughputTester(nfb.BaseComp):
    DT_COMPATIBLE = "ziti,hbm_throughput_tester"

    def __init__(self, *args, ports: int = 2, **kwargs):
        super().__init__(*args, **kwargs)
        self.ports = ports

    # ---- control ---------------------------------------------------------------------------
    def _ctrl(self, run: bool, rd: bool, wr: bool, clr: bool = False) -> None:
        val = ((1 << CtrlBit.RUN) if run else 0) | ((1 << CtrlBit.RD_EN) if rd else 0) \
            | ((1 << CtrlBit.WR_EN) if wr else 0) | ((1 << CtrlBit.CLR) if clr else 0)
        self._comp.write32(TesterReg.CTRL.value, val)

    def stop(self) -> None:
        self._comp.write32(TesterReg.CTRL.value, 0)

    def clear(self) -> None:
        """Zero every counter. CLR is decoded on the write itself, not latched."""
        self._comp.write32(TesterReg.CTRL.value, 1 << CtrlBit.CLR)

    @property
    def burst_len(self) -> int:
        """AxLEN, i.e. beats-per-burst minus one. 15 is the AXI3 maximum of 16 beats."""
        return self._comp.read32(TesterReg.BURST_LEN.value) & 0xF

    @burst_len.setter
    def burst_len(self, val: int) -> None:
        self._comp.write32(TesterReg.BURST_LEN.value, val & 0xF)

    @property
    def port_en(self) -> int:
        return self._comp.read32(TesterReg.PORT_EN.value)

    @port_en.setter
    def port_en(self, mask: int) -> None:
        self._comp.write32(TesterReg.PORT_EN.value, mask)

    @property
    def addr_mask(self) -> int:
        return self._comp.read32(TesterReg.ADDR_MASK.value)

    @addr_mask.setter
    def addr_mask(self, mask: int) -> None:
        self._comp.write32(TesterReg.ADDR_MASK.value, mask)

    @property
    def resp_err(self) -> int:
        """Bit per port, sticky: a non-OKAY RRESP or BRESP was seen."""
        return self._comp.read32(TesterReg.STATUS.value) & ((1 << self.ports) - 1)

    # ---- counters --------------------------------------------------------------------------
    def _cnt48(self, port: int, field: int) -> int:
        base = CNT_BASE + port * CNT_STRIDE + field
        return (self._comp.read32(base + 4) << 32) | self._comp.read32(base)

    def _cnt32(self, port: int, field: int) -> int:
        return self._comp.read32(CNT_BASE + port * CNT_STRIDE + field)

    def sample(self, port: int) -> PortResult:
        return PortResult(port=port,
                          cycles=self._cnt48(port, CNT_CYCLES),
                          r_beats=self._cnt48(port, CNT_R_BEATS),
                          w_beats=self._cnt48(port, CNT_W_BEATS),
                          ar_stall=self._cnt32(port, CNT_AR_STALL),
                          aw_stall=self._cnt32(port, CNT_AW_STALL))

    # ---- one measurement -------------------------------------------------------------------
    def run(self, seconds: float = 0.5, read: bool = True, write: bool = False,
            port_mask: int = None, burst_len: int = 15):
        """Run one traffic pattern and return a PortResult per enabled port.

        `seconds` only decides how long the generator is left armed; the rate comes from the
        counters it kept while running.
        """
        if port_mask is None:
            port_mask = (1 << self.ports) - 1
        self.stop()
        self.burst_len = burst_len
        self.port_en = port_mask
        self.clear()
        self._ctrl(run=True, rd=read, wr=write)
        sleep(seconds)
        self._ctrl(run=False, rd=read, wr=write)
        return [self.sample(p) for p in range(self.ports) if port_mask & (1 << p)]
