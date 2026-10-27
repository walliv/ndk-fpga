# tx_host_driver.py: host side of TX DMA Calypte, ported from tx/uvm/tbench/rx_env/driver.sv
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

from cocotb.triggers import Event, Lock, RisingEdge, Timer

from cocotbext.ofm.mfb.transaction import MfbTransactionWithMeta
from cocotbext.ofm.utils.math import log2ceil

from pcie_tlp import DmaHeader, cq_encode, encode_fbe, encode_lbe
from traffic import pick

SW_PACKET_ALIGNMENT = 32
HW_PACKET_ALIGNMENT = 128
PCIE_LEN_MAX = 256
_LBE_ANY = (0b1000, 0b1100, 0b1010, 0b1110, 0b1001, 0b1101, 0b1011, 0b1111,
            0b0100, 0b0110, 0b0101, 0b0111, 0b0010, 0b0011, 0b0001)
_LBE_ONE_DW = (0b1111, 0b0111, 0b0011, 0b0001)
_PCIE_LEN_DIST = [(1, 63, 75), (64, PCIE_LEN_MAX // 2 - 1, 15), (PCIE_LEN_MAX // 2, PCIE_LEN_MAX - 1, 8),
                  (PCIE_LEN_MAX, PCIE_LEN_MAX, 2)]


def decode_lbe(mod):
    return (1 << mod) - 1 if mod != 0 else 0b1111


def lbe_to_fbe(lbe):
    if lbe & 0b1000:
        return 0b1111
    fbe, it = 0, 4
    while it > 0 and not (lbe >> (it - 1)) & 1:
        fbe |= 1 << (it - 1)
        it -= 1
    return fbe


class CqSender:
    """driver_sync: the channel drivers hand their CQ writes to the one MFB driver, one at a time,
    each waiting until the previous one has been taken."""

    def __init__(self, mfb_driver, clock):
        self.drv = mfb_driver
        self.clock = clock
        self.lock = Lock()
        self.sent = 0

    def used(self):
        return bool(self.drv._sendQ) or self.drv.frame_cnt < self.sent or self.lock.locked()

    async def put(self, frame, meta):
        async with self.lock:
            while self.drv._sendQ:
                await RisingEdge(self.clock)
            self.drv.append(MfbTransactionWithMeta(data=frame, meta=meta))
            self.sent += 1


class TxChannelDriver:
    def __init__(self, ch, cfg, regs, sender, rng, report):
        self.ch = ch
        self.device = cfg["DEVICE"]
        self.dpw = cfg["TX_PTR_WIDTH"]
        self.chan_w = log2ceil(cfg["TX_CHANNELS"])
        self.regs = regs
        self.sender = sender
        self.rng = rng
        self.report = report
        self.data_addr = 0
        self.hdr_addr = 0
        self.data_mask = 0
        self.hdr_mask = 0
        self.chan_active_reg = 0
        self.data_free_space = 0
        self.hdr_free_space = 0
        # The UVM driver reads the masks before it takes its first sequence item.
        self.ready = Event()
        regs.control_hooks.append(self._on_start)

    def _on_start(self):
        self.hdr_addr = 0
        self.data_addr = 0

    async def init_after_reset(self):
        self.data_mask = (await self.regs.read("data_mask")) & 0xFFFF
        self.hdr_mask = (await self.regs.read("hdr_mask")) & 0xFFFF
        self.data_free_space = self.data_mask
        self.hdr_free_space = self.hdr_mask
        self.ready.set()

    async def _wait_for_free_space(self, requested, is_hdr):
        if self.chan_active_reg != 0:
            reg, addr, mask = ("hhp", self.hdr_addr, self.hdr_mask) if is_hdr else ("hdp", self.data_addr, self.data_mask)
            hw_ptr = (await self.regs.read(reg)) & 0xFFFF
            free = (hw_ptr - 1 - addr) & mask
            while free < requested:
                await Timer(200, "ns")
                hw_ptr = (await self.regs.read(reg)) & 0xFFFF
                free = (hw_ptr - 1 - addr) & mask
        else:
            free = self.hdr_mask if is_hdr else self.data_mask
        if is_hdr:
            self.hdr_free_space = free
        else:
            self.data_free_space = free

    def _addr(self, ptr, hdr):
        return (ptr & ((1 << self.dpw) - 1)) | (self.ch << (self.dpw + 1)) | (hdr << (self.dpw + self.chan_w + 1))

    async def send_packet(self, packet, meta):
        await self.ready.wait()
        packet_ptr = self.data_addr
        await self._send_data(packet)
        await self._send_header(packet, meta, packet_ptr)

    async def _send_data(self, packet):
        rng = self.rng
        size = len(packet)
        packet_len = (size + 3) // 4
        cnt = 0
        trans_ptr = self.data_addr
        transactions = []
        lbe = 0
        while cnt < size:
            pcie_len = pick(rng, _PCIE_LEN_DIST)
            fbe = lbe_to_fbe(lbe)
            if packet_len <= cnt // 4 + pcie_len:
                pcie_len = packet_len - cnt // 4
                lbe = decode_lbe(size % 4)
            elif pcie_len == 1:
                lbe = rng.choice([b for b in _LBE_ONE_DW if b & fbe])
            else:
                lbe = rng.choice(_LBE_ANY)
            data = [rng.getrandbits(32)] + [0] * (pcie_len - 1)
            idx = 0
            if pcie_len > 1:
                data[-1] = rng.getrandbits(32)
                for jt in range(encode_fbe(fbe), 4):
                    data[0] = (data[0] & ~(0xFF << 8 * jt)) | (packet[cnt + idx] << 8 * jt)
                    idx += 1
                for it in range(1, pcie_len - 1):
                    data[it] = int.from_bytes(packet[cnt + idx:cnt + idx + 4], "little")
                    idx += 4
                for jt in range(encode_lbe(lbe)):
                    data[-1] = (data[-1] & ~(0xFF << 8 * jt)) | (packet[cnt + idx] << 8 * jt)
                    idx += 1
                send_lbe = lbe
            else:
                for jt in range(encode_fbe(fbe), encode_lbe(lbe)):
                    data[0] = (data[0] & ~(0xFF << 8 * jt)) | (packet[cnt + idx] << 8 * jt)
                    idx += 1
                fbe &= lbe
                send_lbe = 0
            cnt += idx
            frame, cq_meta = cq_encode(self.device, self._addr(trans_ptr, 0), pcie_len, fbe, send_lbe, data)
            transactions.append((frame, cq_meta, idx))
            trans_ptr = (trans_ptr + idx) & self.data_mask

        self.chan_active_reg = await self.regs.read("status")

        for frame, cq_meta, nbytes in transactions:
            if self.data_free_space < nbytes:
                await self._wait_for_free_space(nbytes, False)
            await self.sender.put(frame, cq_meta)
            self.data_addr = (self.data_addr + nbytes) & self.data_mask
            self.data_free_space -= nbytes

        align = HW_PACKET_ALIGNMENT if self.regs.get("exper") & 1 else SW_PACKET_ALIGNMENT
        if self.data_addr % align:
            to_align = align - self.data_addr % align
            if self.data_free_space < to_align:
                await self._wait_for_free_space(to_align, False)
            self.data_addr = (self.data_addr + to_align) & self.data_mask
            self.data_free_space -= to_align

        if self.chan_active_reg != 0:
            await self.regs.write("sdp", self.data_addr)
        if not 0 <= self.data_free_space <= self.data_mask:
            self.report(f"TX ch{self.ch} driver: data free space counter invalid ({self.data_free_space})")

    async def _send_header(self, packet, meta, packet_ptr):
        p2p = self.regs.get("exper") & 1
        if p2p:
            packet_ptr = (packet_ptr >> 7) & 0x1FF
        hdr = DmaHeader()
        hdr.frame_len, hdr.frame_ptr, hdr.vld, hdr.p2p, hdr.meta = len(packet), packet_ptr, 1, p2p, meta
        dma_hdr = hdr.serialize()
        frame, cq_meta = cq_encode(self.device, self._addr(self.hdr_addr * 8, 1), 2, 0b1111, 0b1111,
                                   [dma_hdr & 0xFFFFFFFF, dma_hdr >> 32])
        if self.hdr_free_space == 0:
            await self._wait_for_free_space(1, True)
        await self.sender.put(frame, cq_meta)
        self.hdr_addr = (self.hdr_addr + 1) & self.hdr_mask
        self.hdr_free_space -= 1
        if self.chan_active_reg != 0:
            await self.regs.write("shp", self.hdr_addr)
        if not 0 <= self.hdr_free_space <= self.hdr_mask:
            self.report(f"TX ch{self.ch} driver: header free space counter invalid ({self.hdr_free_space})")


class TransactionBudget:
    """uvm_common::sequence_cfg_transactions shared by every TX channel sequence."""

    def __init__(self, transactions):
        self.transactions = transactions
        self.count = 0

    def next(self):
        ret = self.count < self.transactions
        self.count += 1
        return ret

    def stopped(self):
        return not self.count < self.transactions


_TRANS_COUNT_DIST = [(1, 100, 10), (100, 1000, 20), (1000, 5000, 60), (5000, 50000, 10)]


def _transaction_count(rng, lo, hi):
    """`dist` of sequence_simple::send_packets restricted to [lo, hi]: each range keeps its `:/`
    weight spread evenly over its values, the values outside the bounds are removed."""
    ranges = []
    for a, b, w in _TRANS_COUNT_DIST:
        a2, b2 = max(a, lo), min(b, hi)
        if a2 <= b2:
            ranges.append((a2, b2, w * (b2 - a2 + 1) / (b - a + 1)))
    return pick(rng, ranges)


class TxChannelSequence:
    """uvm_tx_dma_calypte::sequence_simple with its start/stop register sequences."""

    def __init__(self, ch, regs, driver, budget, rng, pkt_size_max, log):
        self.ch = ch
        self.regs = regs
        self.drv = driver
        self.budget = budget
        self.rng = rng
        self.pkt_size_max = pkt_size_max
        self.log = log
        # start_channel_seq is randomised once and then restarted with the same values.
        self.update_base = rng.getrandbits(61) << 3
        self.p2p = rng.getrandbits(1)
        self.upd_timeout = rng.randint(5, 2**32 - 1)
        self.starts = self.stops = self.packets = 0

    async def start_channel(self):
        r = self.regs
        await r.write("update_base", self.update_base)
        await r.write("sdp", 0)
        await r.write("shp", 0)
        await r.write("upd_timeout", self.upd_timeout)
        await r.write("exper", self.p2p)
        await r.write("control", 1)
        attempts = 0
        while True:
            await Timer(300, "ns")
            status = await r.read("status")
            attempts += 1
            if attempts == 100:
                self.log.warning(f"TX ch{self.ch}: the start of a channel takes suspiciously long time")
            if status & 1 == 1:
                break
        self.starts += 1

    async def stop_channel(self):
        r = self.regs
        await r.write("control", 0)
        attempts = 0
        while True:
            await Timer(500, "ns")
            sdp = await r.read("sdp")
            shp = await r.read("shp")
            hdp = await r.read("hdp")
            hhp = await r.read("hhp")
            status = await r.read("status")
            attempts += 1
            if attempts == 500:
                self.log.warning(f"TX ch{self.ch}: the stop of a channel takes suspiciously long time "
                                 f"(SDP {sdp} HDP {hdp} SHP {shp} HHP {hhp} status {status})")
            if sdp == hdp and shp == hhp and status & 1 == 0:
                break
        self.stops += 1

    async def send_packets(self, lo, hi):
        count = _transaction_count(self.rng, lo, hi)
        it = 0
        while it < count and self.budget.next():
            size = self.rng.randint(1, self.pkt_size_max - 1)
            packet = self.rng.randbytes(size)
            await self.drv.send_packet(packet, self.rng.getrandbits(24))
            self.packets += 1
            it += 1

    async def run(self):
        await self.start_channel()
        while not self.budget.stopped():
            await self.send_packets(1, 500)
            await self.stop_channel()
            await self.send_packets(1, 500)
            await self.start_channel()
        await self.stop_channel()
