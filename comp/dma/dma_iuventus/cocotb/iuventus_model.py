# iuventus_model.py: A model for the Iuventus DMA controller that serves as a reference
# to the scoreboard
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import logging
from typing import List
from collections import deque

import cocotb
from cocotb.triggers import RisingEdge, Lock
from cocotbext.ofm.mfb.transaction import MfbTransactionWithMeta, MfbTransaction
from cocotbext.ofm.pcie.PcieHeaders import CQHeader, CQMfbMeta, RQHeader, RQMfbMeta, CCHeader, CCMfbMeta
from cocotbext.ofm.dma.iuventus import CQEStatCodeTypes, CQEStatusCodes, SQEOpCodes, SQEntry, CQEntry
from misc_const import CQE_SIZE, PAGE_SIZE, SQE_SIZE, PcieReqType, \
    BUFF_SIZE, pcie_byte_count, SECT_SIZE, IuventusOpStatCode, \
    STORAGE_CAP_LBAS, IuventusBuffers


# TODO: Test the case where the NVMe device supports to transfer less LBAs in one command
# than the size of a write/read buffer. The buffer consists out of 256 LBAs in size which does
# not have to be supported to be transferred in one command.

class IuventusModel:
    def __init__(self, qsize : int, mptr : int, sq_baddr : int, cq_baddr : int, sqtdbl_baddr : int,
                 cqhdbl_baddr : int, rdbuff_prpl_baddr : int, rdbuff_prpl_data : List[int],
                 wrbuff_prpl_baddr : int, wrbuff_prpl_data : List[int], clock, qid :int, buffs : IuventusBuffers):
        self.qsize = qsize
        self.mptr = mptr
        self.sq_baddr = sq_baddr
        self.cq_baddr = cq_baddr
        self.sqtdbl_baddr = sqtdbl_baddr
        self.cqhdbl_baddr = cqhdbl_baddr
        self.wrbuff_baddr = wrbuff_prpl_data[0]
        self.rdbuff_baddr = rdbuff_prpl_data[0]
        self.rdbuff_prpl_baddr = rdbuff_prpl_baddr
        self.wrbuff_prpl_baddr = wrbuff_prpl_baddr
        self.clock = clock
        self.qid = qid
        self.buffs = buffs

        self.m_cc_exp_out = []
        self.m_op_stat_exp_out = []
        self.m_rd_mfb_exp_out = []
        self.m_pcie_rq_exp_out = []

        self._sq_int = buffs.sq
        self._cq_int = buffs.cq
        self._rd_buff_int = buffs.rd_buff
        self._wr_buff_int = buffs.wr_buff

        self._enabled = False
        self.sqtdbl = 0
        self.sqhdbl = 0
        self.cqhdbl = 0
        self._phase_tag = 1
        self.outstanding_cmds = deque()
        self.tag_fifo = deque(range(2048))

        # Counters as taken from the DUT's register map
        self.c_sqes_disp = 0
        self.c_cqes_proc = 0
        self.c_pcie_rd_reqs = 0
        self.c_pcie_rd_req_bytes = 0
        self.c_pcie_wr_reqs = 0
        self.c_pcie_wr_req_bytes = 0
        self.c_sq_rd_reqs = 0
        self.c_sq_rd_req_bytes = 0
        self.c_succ_compls = 0
        self.c_unsucc_compls = 0
        self.c_rdbuff_rd_reqs = 0
        self.c_rdbuff_rd_req_bytes = 0
        self.c_wrbuff_wr_reqs = 0
        self.c_wrbuff_wr_req_bytes = 0
        self.c_cq_wr_reqs = 0
        self.c_cq_wr_req_bytes = 0
        # NOTE: Repeated updates were ommitted since these have to be synchronized
        # with DU T
        self.c_cqhdbl_reg_upds = 0
        self.c_sqtdbl_reg_upds = 0
        self.c_sqe_rd_cmds = 0
        self.c_sqe_rd_cmd_size = 0
        self.c_sqe_wr_cmds = 0
        self.c_sqe_wr_cmd_size = 0

        # NOTE: These counters do not have to be counted in a model since this is not
        # relevant and each one of them can be checked against other counters
        # self.c_wrbuff_usr_rds = 0        - can be checked against c_wrbuff_wr_reqs
        # self.c_wrbuff_usr_rd_bytes = 0   - can be checked against c_wrbuff_wr_req_bytes
        # self.c_rdbuff_disp_rds = 0       - can be checked against c_rdbuff_rd_reqs
        # self.c_rdbuff_disp_rd_bytes = 0  - can be checked against c_rdbuff_rd_req_bytes
        # self.c_sq_disp_rds = 0           - can be checked against c_sq_rd_reqs
        # self.c_sq_disp_rd_bytes = 0      - can be checked against c_sq_rd_req_bytes

        self.log = logging.getLogger("cocotb.%s" % (type(self).__qualname__))
        cocotb.start_soon(self.proc_cqes())

    def reset(self):
        self._enabled = False
        self.sqtdbl = 0
        self.sqhdbl = 0
        self.cqhdbl = 0
        self._phase_tag = 1
        self.outstanding_cmds.clear()
        self.m_cc_exp_out.clear()
        self.m_op_stat_exp_out.clear()
        self.m_rd_mfb_exp_out.clear()
        self.m_pcie_rq_exp_out.clear()
        self.tag_fifo = deque(range(2048))

        self.c_sqes_disp = 0
        self.c_cqes_proc = 0
        self.c_pcie_rd_reqs = 0
        self.c_pcie_rd_req_bytes = 0
        self.c_pcie_wr_reqs = 0
        self.c_pcie_wr_req_bytes = 0
        self.c_sq_rd_reqs = 0
        self.c_sq_rd_req_bytes = 0
        self.c_succ_compls = 0
        self.c_unsucc_compls = 0
        self.c_rdbuff_rd_reqs = 0
        self.c_rdbuff_rd_req_bytes = 0
        self.c_wrbuff_wr_reqs = 0
        self.c_wrbuff_wr_req_bytes = 0
        self.c_cq_wr_reqs = 0
        self.c_cq_wr_req_bytes = 0
        self.c_cqhdbl_reg_upds = 0
        self.c_sqtdbl_reg_upds = 0
        self.c_sqe_rd_cmds = 0
        self.c_sqe_rd_cmd_size = 0
        self.c_sqe_wr_cmds = 0
        self.c_sqe_wr_cmd_size = 0

    @property
    def enabled(self):
        return self._enabled

    @enabled.setter
    def enabled(self, value):
        self._enabled = value

        if value:
            self.sqtdbl = 0
            self.sqhdbl = 0
            self.cqhdbl = 0
            self._phase_tag = 1

    def post_check(self):
        assert self.sqtdbl == self.sqhdbl, f"{type(self).__qualname__}: Post check failed: SQTDbl ({self.sqtdbl}) does not match SQHDbl ({self.sqhdbl})"

    def disp_cc_resps(self, addr, req_size, buff, cq_hdr):
        """
        Dispatch Completion Completion responses based on the CQ request header

        :param addr: Address to the buff with resolution to bytes
        :param req_size: Requested size in bytes
        :param buff: Buffer with data to be sent in the completion
        :param cq_hdr: CQ Header with parameters to be copied to the CC header
        """
        rem_bytes = req_size
        cur_addr = addr % BUFF_SIZE

        if self.log.isEnabledFor(logging.INFO):
            self.log.info(f"Dispatching CC responses for address 0x{addr:x} of size {req_size} bytes.")

        while rem_bytes > 0:
            chunk_size = min(rem_bytes, 128)

            cc_hdr = CCHeader()
            cc_hdr.lower_address = cur_addr & 0x7F
            cc_hdr.at = cq_hdr.at
            cc_hdr.byte_count = rem_bytes
            cc_hdr.dword_count = (chunk_size + 3) // 4
            cc_hdr.completion_status = 0  # Successful Completion
            cc_hdr.rid = cq_hdr.req_id
            cc_hdr.tag = cq_hdr.tag
            cc_hdr.tc = cq_hdr.tc
            cc_hdr.attr = cq_hdr.attr
            cc_hdr.cid  = 1 # Completer function number

            data = buff[cur_addr: cur_addr + chunk_size]

            if len(data) % 4 != 0:
                data.extend(bytearray(4 - (len(data) % 4)))

            if self.log.isEnabledFor(logging.DEBUG):
                self.log.debug(f"Dispatching CC Response: {cc_hdr}, data Length: {len(data)}B (indicated {chunk_size}B), remaining bytes: {rem_bytes}B")

            tr = MfbTransactionWithMeta(
                data=cc_hdr.serialize().to_bytes(len(CCHeader()) // 8, 'little') + data,
                meta=0)

            self.m_cc_exp_out.append(tr)

            rem_bytes -= chunk_size
            cur_addr += chunk_size

    # TODO: Shuffle transactions with writes to the qq write buffer in the NVME controller model

    # Process CQ requests on the PCIe (assign as a callback for the CQ driver)
    def proc_pcie_cq_reqs(self, transaction):
        hdr = int.from_bytes(transaction.data[:len(CQHeader()) // 8], 'little')
        cq_hdr = CQHeader.deserialize(hdr)
        meta = CQMfbMeta.deserialize(transaction.meta)

        if self.log.isEnabledFor(logging.DEBUG):
            self.log.debug(f"Processing PCIe CQ Request: {cq_hdr}, Meta: {meta}")

        # Calculate the real length of data payload in bytes based on
        byte_count = pcie_byte_count(cq_hdr.dword_count, meta.firstBe, meta.lastBe)

        if meta.firstBe & 0x0001: offset = 0
        elif meta.firstBe & 0x0010: offset = 1
        elif meta.firstBe & 0x0100: offset = 2
        elif meta.firstBe & 0x1000: offset = 3
        else: offset = 0  # Should not happen due to assertions in pcie_byte

        addr = (cq_hdr.addr << 2) + offset

        if cq_hdr.req_type == PcieReqType.MRD:
            if addr in range(self.rdbuff_baddr, self.rdbuff_baddr + BUFF_SIZE):
                if self.log.isEnabledFor(logging.INFO):
                    self.log.info(f"MRD request for RD buffer at address 0x{addr:x} of size {byte_count} bytes.")
                self.disp_cc_resps(addr, byte_count, self._rd_buff_int, cq_hdr)
                self.c_rdbuff_rd_reqs += 1
                self.c_rdbuff_rd_req_bytes += byte_count

            elif addr in range(self.sq_baddr, self.sq_baddr + self.qsize * SQE_SIZE):
                if self.log.isEnabledFor(logging.INFO):
                    self.log.info(f"MRD request for SQ at address 0x{addr:x} of size {byte_count} bytes.")
                self.disp_cc_resps(addr, byte_count, self._sq_int, cq_hdr)
                self.c_sq_rd_reqs += 1
                self.c_sq_rd_req_bytes += byte_count
            else:
                assert False, f"Invalid MRD address requested: 0x{addr:x}"

            self.c_pcie_rd_reqs += 1
            self.c_pcie_rd_req_bytes += byte_count

        elif cq_hdr.req_type == PcieReqType.MWR:
            assert byte_count > 0, "Attempt to write data payload of 0 bytes"

            # Extract valid data based on the offset from the first byte enable
            data = transaction.data[(len(CQHeader()) // 8) + offset:]
            assert len(data) > 0, "Attempt to write data payload of 0 bytes"

            if addr in range(self.wrbuff_baddr, self.wrbuff_baddr + BUFF_SIZE):
                if self.log.isEnabledFor(logging.INFO):
                    self.log.info(f"MWR request for WR buffer at address 0x{addr:x} of size {byte_count} bytes.")
                # self.log.debug(f"Writing payload: {data.hex()}")
                addr = addr % BUFF_SIZE
                self._wr_buff_int[addr : addr + len(data)] = data
                self.c_wrbuff_wr_reqs += 1
                self.c_wrbuff_wr_req_bytes += byte_count

            elif addr in range(self.cq_baddr, self.cq_baddr + self.qsize * CQE_SIZE):
                if self.log.isEnabledFor(logging.INFO):
                    self.log.info(f"MWR request for CQ at address 0x{addr:x} of size {byte_count} bytes.")
                # self.log.debug(f"Writing payload: {data.hex()}")
                addr = addr % BUFF_SIZE
                self._cq_int[addr : addr + len(data)] = data
                self.c_cq_wr_reqs += 1
                self.c_cq_wr_req_bytes += byte_count
            else:
                assert False, f"Invalid MWR address requested: 0x{addr:x}"

            self.c_pcie_wr_reqs += 1
            self.c_pcie_wr_req_bytes += byte_count

    async def proc_cqes(self):
        """
        Process Completion Queue Entries in the internal CQ memory
        """

        while True:
            await RisingEdge(self.clock)
            cqe_ser = self._cq_int[self.cqhdbl * CQE_SIZE : (self.cqhdbl + 1) * CQE_SIZE]
            cqe = CQEntry.deserialize(int.from_bytes(cqe_ser, 'little'))

            if cqe.phase_tag != self._phase_tag or not self._enabled:
                continue  # No new CQE to process

            self.sqhdbl = cqe.sqhdbl
            assert cqe.cmd_id == self.outstanding_cmds[-1][0], f"CQE Command ID {cqe.cmd_id} not found in outstanding commands {list(self.outstanding_cmds)}"
            assert self.qid == cqe.sq_id, f"CQE SQ ID {cqe.sq_id} does not match model SQ ID {self.qid}"
            assert cqe.stat_code_type == CQEStatCodeTypes.GENERIC, f"CQE stat code type {cqe.stat_code_type} not supported in model"
            assert cqe.stat_code == CQEStatusCodes.SUCCESS, f"CQE status code {cqe.stat_code} not supported in model"

            # Process the CQE (for now, just print it)
            if self.log.isEnabledFor(logging.INFO):
                self.log.info(f"Processing CQE at index {self.cqhdbl}: {cqe}")
            cmd_id, rd, size = self.outstanding_cmds.pop()
            self.tag_fifo.append(cmd_id)

            self.disp_dbl_update(self.cqhdbl_baddr)
            if self.cqhdbl == 0:
                self._phase_tag ^= 1  # Toggle phase tag

            self.c_cqes_proc += 1

            is_succ = cqe.stat_code_type == CQEStatCodeTypes.GENERIC and cqe.stat_code == CQEStatusCodes.SUCCESS
            if is_succ:
                self.c_succ_compls += 1
                op_stat = IuventusOpStatCode.SUCC
            else:
                self.c_unsucc_compls += 1
                op_stat = IuventusOpStatCode.GEN_FAILURE

            self.m_op_stat_exp_out.append((rd, op_stat))
            if self.log.isEnabledFor(logging.DEBUG):
                self.log.debug(f"Appending operation status to expected output: rd={rd}, op_stat={op_stat}")
            if rd and is_succ:
                tr = MfbTransaction(data = self._wr_buff_int[0 : size])
                self.m_rd_mfb_exp_out.append(tr)

    def disp_dbl_update(self, baddr):
        rq_hdr = RQHeader()
        rq_hdr.addr = baddr >> 2
        rq_hdr.dword_count = 1
        rq_hdr.req_type = PcieReqType.MWR
        rq_hdr.attr = 0b001
        rq_hdr.req_id = 1

        rq_meta = RQMfbMeta()
        rq_meta.firstBe = 0b0011
        rq_meta.lastBe = 0b0000

        dbl_type = "SQ" if baddr == self.sqtdbl_baddr else "CQ"
        dbl_val = 0

        if dbl_type == "SQ":
            dbl_val = (self.sqtdbl + 1) % self.qsize
            self.sqtdbl = dbl_val
            self.log.info(f"Dispatching SQTDbl update: New SQTDbl = {self.sqtdbl}")
            self.c_sqtdbl_reg_upds += 1
        elif dbl_type == "CQ":
            dbl_val = (self.cqhdbl + 1) % self.qsize
            self.cqhdbl = dbl_val
            self.log.info(f"Dispatching CQHDbl update: New CQHDbl = {self.cqhdbl}")
            self.c_cqhdbl_reg_upds += 1

        tr = MfbTransactionWithMeta(
            data = rq_hdr.serialize().to_bytes(len(RQHeader()) // 8, 'little') + dbl_val.to_bytes(2, 'little') + bytearray(2),
            meta = rq_meta.serialize()
        )

        self.m_pcie_rq_exp_out.append(tr)

    def create_nvme_rd_cmd(self, transaction):
        """
        Create a NVMe Read request SQE0 and place it in the internal SQ memory. This should be
        passed as a callback for transactions appended to the NVMe Read Request driver.

        :param transaction: Tuple containing (lba_num, lba_ptr)
        """
        lba_num, lba_ptr = transaction
        if self.log.isEnabledFor(logging.INFO):
            self.log.info(f"Creating NVMe Read Request: LBA Num={lba_num}, LBA Ptr={lba_ptr} ({lba_ptr:x})")

        self.c_sqes_disp += 1
        self.c_sqe_rd_cmds += 1
        self.c_sqe_rd_cmd_size += lba_num * SECT_SIZE

        if lba_ptr + lba_num > STORAGE_CAP_LBAS:
            self.log.warning(f"Requested LBA range (start: {lba_ptr}, num: {lba_num}) exceeds storage capacity. Marking operation as failed.")
            self.m_op_stat_exp_out.append((True, IuventusOpStatCode.LBA_OUT_OF_RANGE))
            return

        sqe = SQEntry()
        sqe.opcode = SQEOpCodes.READ
        sqe.nsid = 1
        sqe.start_lba = lba_ptr
        sqe.num_lba = lba_num - 1  # Zero base0d
        sqe.cmd_id = self.tag_fifo.popleft()
        sqe.mptr = self.mptr
        sqe.prp1 = self.wrbuff_baddr

        self.outstanding_cmds.appendleft((sqe.cmd_id, True, lba_num * SECT_SIZE))

        if (lba_num * 512) > PAGE_SIZE and (lba_num * 512) <= 2 * PAGE_SIZE:
            sqe.prp2 = self.wrbuff_baddr + PAGE_SIZE
        elif (lba_num * 512) > 2 * PAGE_SIZE:
            sqe.prp2 = self.wrbuff_prpl_baddr
        else:
            sqe.prp2 = 0

        if self.log.isEnabledFor(logging.INFO):
            self.log.info(f"Created NVMe Read Request SQE: {sqe}, current SQTDbl: {self.sqtdbl}")

        sqe_ser = sqe.serialize().to_bytes(SQE_SIZE, 'little')
        self._sq_int[self.sqtdbl * SQE_SIZE : (self.sqtdbl + 1) * SQE_SIZE] = sqe_ser
        self.disp_dbl_update(self.sqtdbl_baddr)

    def create_nvme_wr_cmd(self, transaction):
        """
        Create a NVMe Write request SQE and place it in the internal SQ memory. This should be
        passed as a callback for transactions appended to the NVMe Write Request driver.

        :param transaction: MfbTransactionWithMeta containing data to write in the data field and the starting LBA in the meta field
        """
        assert len(transaction.data) <= BUFF_SIZE, f"Data payload size {len(transaction.data)} exceeds buffer size {BUFF_SIZE}"

        lba_num = (len(transaction.data) + SECT_SIZE - 1) // SECT_SIZE

        if self.log.isEnabledFor(logging.INFO):
            self.log.info(f"Creating NVMe Write Request: LBA Num={lba_num}, LBA Ptr={transaction.meta} ({transaction.meta:x})")

        self.c_sqes_disp += 1
        self.c_sqe_wr_cmds += 1
        self.c_sqe_wr_cmd_size += lba_num * SECT_SIZE

        if transaction.meta + lba_num > STORAGE_CAP_LBAS:
            self.log.warning(f"Write request exceeds storage capacity: LBA Ptr={transaction.meta} + LBA Num={lba_num} > Storage Capacity={STORAGE_CAP_LBAS}")
            self.m_op_stat_exp_out.append((False, IuventusOpStatCode.LBA_OUT_OF_RANGE))
            return

        sqe = SQEntry()
        sqe.opcode = SQEOpCodes.WRITE
        sqe.nsid = 1
        sqe.start_lba = transaction.meta
        sqe.num_lba = lba_num - 1  # Zero based
        sqe.cmd_id = self.tag_fifo.popleft()
        sqe.mptr = self.mptr
        sqe.prp1 = self.rdbuff_baddr

        self.outstanding_cmds.appendleft((sqe.cmd_id, False, lba_num * SECT_SIZE))

        if (lba_num * 512) > PAGE_SIZE and (lba_num * 512) <= 2 * PAGE_SIZE:
            sqe.prp2 = self.rdbuff_baddr + PAGE_SIZE
        elif (lba_num * 512) > 2 * PAGE_SIZE:
            sqe.prp2 = self.rdbuff_prpl_baddr
        else:
            sqe.prp2 = 0

        if self.log.isEnabledFor(logging.INFO):
            self.log.info(f"Created NVMe Write Request SQE: {sqe}, current SQTDbl: {self.sqtdbl}")

        sqe_ser = sqe.serialize().to_bytes(SQE_SIZE, 'little')
        self._sq_int[self.sqtdbl * SQE_SIZE : (self.sqtdbl + 1) * SQE_SIZE] = sqe_ser
        self._rd_buff_int[0 : len(transaction.data)] = transaction.data
        self.disp_dbl_update(self.sqtdbl_baddr)