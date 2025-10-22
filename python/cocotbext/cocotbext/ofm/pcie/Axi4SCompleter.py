# SPDX-License-Identifier: BSD-3-Clause
# Copyright (C) 2023 CESNET z. s. p. o.
# Author(s): Martin Spinler <spinler@cesnet.cz>

import logging
import cocotb
import cocotb.queue
from cocotb.triggers import Event, RisingEdge

from ..utils import concat, SerializableHeader
from .PcieHeaders import CQHeader, CCHeader, CQUser, CCUser


class CQHeaderEmpty(SerializableHeader):
    items = list(zip([], []))


class Axi4SCompleter:
    def __init__(self, cq_driver, cc_driver, cc_monitor):
        self._cq = cq_driver
        self._cc = cc_driver
        self._ccm = cc_monitor
        self._queue_send = cocotb.queue.Queue()
        self._queue_recv = cocotb.queue.Queue()
        self._axi_width = len(self._cq.bus.TDATA) // 8

        self._cc_inframe = None
        self._completions = {}
        self._read_requests = {}
        self._tag_queue = cocotb.queue.PriorityQueue()
        [self._tag_queue.put_nowait(i) for i in range(2**5)]

        cc_monitor.add_callback(self._handle_cc_transaction)
        cocotb.start_soon(self._cq_loop())

        self.log = logging.getLogger("cocotbext.ofm.pcie.%s" % (type(self).__qualname__))

    async def _cq_loop(self):
        re = RisingEdge(self._cq.clock)
        await re

        while True:
            if self._queue_send.empty():
                await re
                continue

            item, trigger = self._queue_send.get_nowait()
            tag = None
            if item[2] == 0:  # req_type = read
                tag = await self._tag_queue.get()
                self._read_requests[tag] = (trigger, item, [])
            if tag is None:
                trigger.set()

            await self._cq_req(*item, tag=tag, sync=False)

    def _handle_cc_transaction(self, tr):
        data = list(reversed(tr["TDATA"]))
        # FIXME: Monitor sends values as bytes
        # TODO: When straddling is used, the TLAST signal shouldn't be actually used
        #       although our MFB2AXI converter is assigning it
        tlast = bool(tr['TLAST'][0])

        self.log.debug(f"Transaction arrived: {tr}")

        # INFO: tkeep not checked for continuity
        tkeep = int.from_bytes(tr['TKEEP'], byteorder='big')
        tuser = None
        if tkeep == 0:
            tuser = CCUser.deserialize(int.from_bytes(tr['TUSER'], byteorder='big'))
            # Beginning of a transaction
            if self._cc_inframe is None:

                if tuser.eop0 == 0:
                    vld_bytes = len(data)
                elif tuser.eop0 == 1:
                    vld_bytes = (tuser.eop_ptr0 + 1) * 4

            # Middle of a transaction
            else:
                # Transaction does not end in a current word
                if tuser.eop0 == 0:
                    vld_bytes = len(data)

                # Transaction ends in a current word
                elif tuser.eop0 == 1:
                    vld_bytes = (tuser.eop_ptr0 + 1) * 4
        else:
            vld_bytes = int(tkeep).bit_count() * 4

        self.log.debug(f"TKEEP: {tkeep}")
        self.log.debug(f"TUSER: {tuser}")
        self.log.debug(f"vld_bytes: {vld_bytes}")
        self.log.debug(f"tlast: {tlast}")

        if self._cc_inframe is None:
            h = len(CCHeader()) // 8
            hdrbytes, data = data[:h], data[h:]
            vld_bytes -= h
            self._cc_inframe = CCHeader.deserialize(int.from_bytes(hdrbytes, byteorder='little'))

        data = data[:int(vld_bytes)]
        hdr = self._cc_inframe

        trigger, item, req_data = self._read_requests[hdr.tag]
        addr, byte_count, req_type, orig_data = item

        # Splitted completion for request
        is_first = len(req_data) == 0
        offset = addr % 4 if is_first else 0
        data = data[offset:]

        rem = byte_count - len(req_data)
        is_last = len(data) >= rem
        data = data[:rem] if is_last else data[:]
        req_data.extend(data)

        if tlast:
            self._cc_inframe = None
            if is_last:
                del self._read_requests[hdr.tag]
                trigger.set(req_data)
                self._tag_queue.put_nowait(hdr.tag)

        # TODO: The straddling option should be added to to the Axi4Stream BusMonitor as well
        # as to this function. On this place, a check should be done if a second region does not
        # contain next packet and therefore a new transaction can be started immediately. A current
        # implementation of this function passes since the simulation currently tests a CQ/CC
        # interface with only the MTC which does not utilize a second region.

    async def _cq_req(self, addr, byte_count, req_type=0, data=[], tag=None, sync=True):

        self.log.debug(f"Request to send transaction: {addr=}, {byte_count=}, {req_type=}, {tag=}")

        if byte_count == 0:
            if tag is not None:
                trigger, item, req_data = self._read_requests[tag]
                del self._read_requests[tag]
                self._tag_queue.put_nowait(tag)
                trigger.set(req_data)
            return

        header_empty = CQHeaderEmpty()
        header = CQHeader()

        if req_type == 1:
            assert len(data) == byte_count
            data = [0] * (addr % 4) + data + [0] * (-(addr + byte_count) % 4)

        if tag is not None:
            header.tag = tag

        dwords = (addr % 4 + byte_count + 3) // 4
        header.bar_apper = 26
        header.addr = addr >> 2
        header.dword_count = dwords
        header.req_type = req_type

        self.log.debug(f"Generated CQ request hdr: {header}")

        first = True
        while len(data) or len(header):
            cnt = min(self._axi_width - len(header) // 8, len(data))
            tdata = concat([(header.serialize(), len(header))] + list(zip(data[:cnt], [8] * cnt)))

            user = CQUser()
            user.firstBe0 = [0xF, 0xE, 0xC, 0x8][addr % 4]
            user.lastBe0 = [0xF, 0x1, 0x3, 0x7][(addr + byte_count) % 4]

            if dwords <= 1:
                user.firstBe0 &= user.lastBe0
                user.lastBe0 = 0

            user.sop0 = 1 if first else 0
            user.sop_ptr0 = 0

            if len(data) <= cnt:
                user.eop0 = 1
                end_dw_addr = (addr + byte_count - 1) >> 2
                user.eop_ptr0 = end_dw_addr if not first else end_dw_addr + 4
            else:
                user.eop0 = 0
                user.eop_ptr0 = 0

            tuser = user.serialize()
            tkeep = 2**(cnt // 4 + len(header) // 32) - 1

            self.log.debug(f"Generated CQ request bus word: \n{tdata:x}\nTUSER: {user}\nTKEEP: {tkeep:x}")
            await self._cq.write({"TDATA": tdata, "TUSER": tuser, "TKEEP": tkeep}, sync=sync)

            header = header_empty
            data = data[cnt:]
            first = False

    async def read(self, addr: int, byte_count: int) -> bytes:
        # TODO: split big reads to more transactions
        e = Event()
        await self._queue_send.put(((addr, byte_count, 0, []), e))
        await e.wait()
        return bytes(e.data)

    async def write(self, addr: int, data: bytes):
        # TODO: split big writes to more transactions
        e = Event()
        data = list(data)
        await self._queue_send.put(((addr, len(data), 1, data), e))
        data = await e.wait()

    async def read64(self, addr):
        rawdata = await self.read(addr, 8)
        return int.from_bytes(bytes(rawdata), byteorder="little")

    async def read32(self, addr):
        rawdata = await self.read(addr, 4)
        return int.from_bytes(bytes(rawdata), byteorder="little")

    async def write32(self, addr, val):
        await self.write(addr, list(val.to_bytes(4, byteorder="little")))

    async def write64(self, addr, val):
        await self.write(addr, list(val.to_bytes(8, byteorder="little")))
