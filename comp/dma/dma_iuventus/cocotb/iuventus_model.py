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
    STORAGE_CAP_LBAS, IuventusBuffers, QUEUE_DEPTH


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
        self.tag_fifo = deque(range(QUEUE_DEPTH))
        self._completed_cmd_ids = set()  # detect duplicate CQE processing
        # WRITEs (unlike READs) reserve a bounded MAX_WR_PAGES run rather than DATA_PAGES (the
        # whole buffer), so more than one can legitimately be outstanding at once and the RTL's
        # first-fit wr_alloc can hand out a page k other than FIRST_DATA_PAGE -- and the model
        # cannot predict k any more reliably here than it can for READs (see create_nvme_rd_cmd):
        # it depends on live wr_alloc occupancy this model does not track. Instead, mirror the
        # READ side's approach exactly: don't predict k at all here. The write's payload is
        # stashed (keyed by cmd_id, not FIFO order: nvme_ctrl_model._proc_sq_entries shuffles a
        # batch of freshly-fetched SQEs before processing them, so processing order does not
        # match creation/ring order) and only placed into _rd_buff_int once nvme_ctrl_model
        # discovers the *real* k from the actual dispatched SQE's PRP1 -- see place_wr_payload.
        self._pending_wr_payloads = {}  # cmd_id -> raw payload bytes
        # Per-command snapshot of serialized SQEs, in dispatch (creation) order: (slot, sqe_bytes).
        # The SSD reads SQ slots strictly in sqhdbl-increasing order, i.e. in the same order these
        # were created, so this FIFO lets disp_cc_resps predict the exact SQE content the DUT holds
        # for a given MRD even if self._sq_int has since been overwritten by a later, wrapped-around
        # command (see _resolve_sq_read_bytes).
        self._sq_snapshot = deque()

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
        self.tag_fifo = deque(range(QUEUE_DEPTH))
        self._sq_snapshot.clear()
        self._pending_wr_payloads.clear()

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

    def disp_cc_resps(self, addr, req_size, buff, cq_hdr, is_sq_read=False):
        """
        Dispatch Completion Completion responses based on the CQ request header

        :param addr: Address to the buff with resolution to bytes
        :param req_size: Requested size in bytes
        :param buff: Buffer with data to be sent in the completion
        :param cq_hdr: CQ Header with parameters to be copied to the CC header
        :param is_sq_read: True if this CC response is for a MRD targeting the SQ ring; in that
            case `buff` is a snapshot resolved from `_resolve_sq_read_bytes` (see there), not the
            live, mutable `self._sq_int`, so PRP masking is enabled the same way as before.
        """
        rem_bytes = req_size
        # Wrap within the actual backing buffer's size, not BUFF_SIZE: the SQ ring is only
        # qsize*SQE_SIZE bytes (a power of two, and a multiple of 128B), so an MRD near its tail
        # (as exercised by the phase-wrap stress test) legitimately wraps back to its start well
        # before BUFF_SIZE is reached.
        buff_len = len(buff)
        cur_addr = addr % buff_len
        hdr_len = len(CCHeader()) // 8
        first_chunk = True

        if self.log.isEnabledFor(logging.INFO):
            self.log.info(f"Dispatching CC responses for address 0x{addr:x} of size {req_size} bytes.")

        while rem_bytes > 0:
            # A completion may not cross a Read Completion Boundary (RCB, 128B). The first
            # completion is capped at the next 128B boundary; every subsequent completion starts
            # 128B-aligned, so its lower_address is always 0.
            if first_chunk:
                chunk_size = min(rem_bytes, 128 - (cur_addr & 0x7F))
            else:
                chunk_size = min(rem_bytes, 128)

            cc_hdr = CCHeader()
            cc_hdr.lower_address = (cur_addr & 0x7F) if first_chunk else 0
            cc_hdr.at = cq_hdr.at
            cc_hdr.byte_count = rem_bytes
            cc_hdr.dword_count = (chunk_size + 3) // 4
            cc_hdr.completion_status = 0  # Successful Completion
            cc_hdr.rid = cq_hdr.req_id
            cc_hdr.tag = cq_hdr.tag
            cc_hdr.tc = cq_hdr.tc
            cc_hdr.attr = cq_hdr.attr
            cc_hdr.cid  = 1 # Completer function number

            if cur_addr + chunk_size <= buff_len:
                data = buff[cur_addr: cur_addr + chunk_size]
            else:
                # The chunk wraps around the end of the ring buffer.
                data = buff[cur_addr:] + buff[:cur_addr + chunk_size - buff_len]

            if len(data) % 4 != 0:
                data.extend(bytearray(4 - (len(data) % 4)))

            if self.log.isEnabledFor(logging.DEBUG):
                self.log.debug(f"Dispatching CC Response: {cc_hdr}, data Length: {len(data)}B (indicated {chunk_size}B), remaining bytes: {rem_bytes}B")

            tr = MfbTransactionWithMeta(
                data=cc_hdr.serialize().to_bytes(len(CCHeader()) // 8, 'little') + data,
                meta=0)

            if is_sq_read:
                # The SQE's PRP1 (bytes 24-31) and PRP2 (bytes 32-39) fields are unpredictable on
                # the model side (the RTL's dynamic first-fit page allocator decides the actual
                # buffer page `k`, which this model no longer tries to predict). Attach the byte
                # ranges (within this transaction's data, i.e. including the CC header offset)
                # that fall on PRP dwords so the scoreboard comparator can mask them out.
                prp_mask = []
                run_start = None
                for i in range(chunk_size):
                    o = cur_addr + i
                    if 24 <= (o % SQE_SIZE) < 40:
                        if run_start is None:
                            run_start = i
                    else:
                        if run_start is not None:
                            prp_mask.append((hdr_len + run_start, hdr_len + i))
                            run_start = None
                if run_start is not None:
                    prp_mask.append((hdr_len + run_start, hdr_len + chunk_size))
                tr._prp_mask = prp_mask

            self.m_cc_exp_out.append(tr)

            rem_bytes -= chunk_size
            cur_addr = (cur_addr + chunk_size) % buff_len
            first_chunk = False

    def _resolve_sq_read_bytes(self, addr, req_size):
        """
        Resolve the exact bytes the DUT holds for a SQ-ring MRD covering [addr, addr+req_size),
        from the per-command snapshot FIFO (`self._sq_snapshot`) instead of the live, mutable
        `self._sq_int`.

        Rationale: `self._sq_int` is a per-slot ring that `create_*_cmd` overwrites the instant a
        new command is created (model's `sqtdbl`), without regard to whether the SSD has consumed
        (read) the previous occupant of that slot yet -- unlike the RTL dispatcher, which only
        writes a slot once `(sqtdbl+1) & DBL_MASK != sqhdbl`. Under multiple-outstanding dispatch
        with an SQ-ring wrap, the model can therefore race ahead of the DUT and clobber a slot the
        scoreboard still needs to predict. The snapshot FIFO instead records each command's
        serialized SQE once, in creation (=dispatch) order; since the SSD reads SQ slots strictly
        in sqhdbl-increasing order (see nvme_ctrl_model._run_controller / _dispatch_rd_req, which
        always starts a MRD at a slot boundary and never lets one MRD cross the ring's end), the
        front of this FIFO always holds the correct SQE for the next slot(s) being read, no matter
        what has since been written into the live ring.

        Returns a bytearray the size of the full SQ ring, with only the requested [addr,
        addr+req_size) byte range filled in (the rest is never read by the caller), so it is a
        drop-in `buff` replacement for disp_cc_resps().
        """
        ring_bytes = self.qsize * SQE_SIZE
        start_off = addr % ring_bytes
        assert start_off % SQE_SIZE == 0, \
            f"SQ MRD must start at a SQE slot boundary, got offset {start_off} within the ring"
        assert req_size % SQE_SIZE == 0, \
            f"SQ MRD size must be a multiple of SQE_SIZE ({SQE_SIZE}), got {req_size}"

        start_slot = start_off // SQE_SIZE
        n_slots = req_size // SQE_SIZE

        resolved = bytearray(ring_bytes)
        for i in range(n_slots):
            expected_slot = (start_slot + i) % self.qsize
            assert self._sq_snapshot, \
                f"SQ snapshot FIFO underrun while resolving MRD at addr 0x{addr:x}, slot {expected_slot}"
            slot, sqe_bytes = self._sq_snapshot.popleft()
            assert slot == expected_slot, (
                f"SQ snapshot FIFO desync: MRD expects slot {expected_slot} next, "
                f"but the oldest un-consumed snapshot entry is for slot {slot}"
            )
            resolved[slot * SQE_SIZE : (slot + 1) * SQE_SIZE] = sqe_bytes

        return resolved

    # NOTE: CQ-buffer / read-data writes are split into randomly sized bursts and emitted weakly
    # ordered by the NVMe controller model (nvme_ctrl_model._dispatch_wr_req, WC emulation). This
    # callback is address-based and updates the model buffers atomically per transaction, so it is
    # order-independent; only the DUT observes the weakly ordered wire sequence.

    # Process CQ requests on the PCIe (assign as a callback for the CQ driver)
    def proc_pcie_cq_reqs(self, transaction):
        hdr = int.from_bytes(transaction.data[:len(CQHeader()) // 8], 'little')
        cq_hdr = CQHeader.deserialize(hdr)
        meta = CQMfbMeta.deserialize(transaction.meta)

        if self.log.isEnabledFor(logging.DEBUG):
            self.log.debug(f"Processing PCIe CQ Request: {cq_hdr}, Meta: {meta}")

        # Calculate the real length of data payload in bytes based on
        byte_count = pcie_byte_count(cq_hdr.dword_count, meta.firstBe, meta.lastBe)

        # Byte offset of the first valid byte within the first DWORD = position of the
        # lowest set bit in firstBe (0..3). With byte-granular WC writes firstBe can be any
        # contiguous mask (e.g. 0xE -> offset 1, 0xC -> offset 2), so decode it properly
        # rather than assuming a DWORD-aligned start.
        if meta.firstBe == 0:
            offset = 0  # zero-length; byte_count == 1 per pcie_byte_count
        else:
            offset = (meta.firstBe & -meta.firstBe).bit_length() - 1

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
                sq_snapshot_buff = self._resolve_sq_read_bytes(addr, byte_count)
                self.disp_cc_resps(addr, byte_count, sq_snapshot_buff, cq_hdr, is_sq_read=True)
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

    def place_wr_payload(self, cmd_id, k):
        """
        Place the queued WRITE payload for `cmd_id` (see _pending_wr_payloads) into RDBUFF at the
        real page `k` the RTL's wr_alloc actually granted it. Called from
        nvme_ctrl_model._proc_sq_entries once it determines k from the *real* dispatched SQE's
        PRP1, exactly the same way the READ side already resolves its WRBUFF placement (see
        create_nvme_rd_cmd) -- so, like the READ side, this model never has to predict wr_alloc's
        live occupancy or admission timing at all. Keyed by cmd_id rather than dispatch-order FIFO
        because nvme_ctrl_model shuffles the processing order of a batch of freshly-fetched SQEs.
        """
        data = self._pending_wr_payloads.pop(cmd_id)
        wr_offset = k * PAGE_SIZE
        self._rd_buff_int[wr_offset : wr_offset + len(data)] = data

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

            # Use cmd_id membership as the authoritative phantom/genuine discriminator.
            # proc_cqes detects new CQEs by phase tag alone, so a stale CQE slot whose
            # phase coincidentally matches the expected tag (e.g. after even numbers of
            # full CQ rounds) would be a false positive.  A genuine CQE always carries the
            # cmd_id of an outstanding command; a stale/phantom slot does not.
            # nvme_ctrl_model may complete commands out of order (it shuffles SQEs with a
            # fixed seed), so we search the entire deque instead of popping the tail.
            match_idx = next(
                (i for i, entry in enumerate(self.outstanding_cmds) if entry[0] == cqe.cmd_id),
                None
            )
            if match_idx is None:
                raw = self._cq_int[self.cqhdbl * CQE_SIZE : (self.cqhdbl + 1) * CQE_SIZE]
                already_done = cqe.cmd_id in self._completed_cmd_ids
                self.log.warning(
                    f"proc_cqes: skipping CQE at slot {self.cqhdbl} "
                    f"phase={cqe.phase_tag} expected={self._phase_tag} "
                    f"cmd_id={cqe.cmd_id} already_completed={already_done} "
                    f"outstanding_count={len(self.outstanding_cmds)} "
                    f"raw={raw.hex()}"
                )
                continue  # phantom/stale CQE: cmd_id not found among outstanding commands

            self.sqhdbl = cqe.sqhdbl
            assert self.qid == cqe.sq_id, f"CQE SQ ID {cqe.sq_id} does not match model SQ ID {self.qid}"
            assert cqe.stat_code_type == CQEStatCodeTypes.GENERIC, f"CQE stat code type {cqe.stat_code_type} not supported in model"
            assert cqe.stat_code == CQEStatusCodes.SUCCESS, f"CQE status code {cqe.stat_code} not supported in model"

            if self.log.isEnabledFor(logging.INFO):
                self.log.info(f"Processing CQE at index {self.cqhdbl}: {cqe}")
            cmd_id, rd, size = self.outstanding_cmds[match_idx]
            del self.outstanding_cmds[match_idx]
            self.tag_fifo.append(cmd_id)
            self._completed_cmd_ids.add(cmd_id)

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

        if lba_ptr + lba_num > STORAGE_CAP_LBAS:
            self.log.info(f"NVMe RD OOR: lba_ptr={lba_ptr} lba_num={lba_num} exceeds storage capacity {STORAGE_CAP_LBAS}. Reporting LBA_OUT_OF_RANGE.")
            self.m_op_stat_exp_out.append((True, IuventusOpStatCode.LBA_OUT_OF_RANGE))
            return

        self.c_sqes_disp += 1
        self.c_sqe_rd_cmds += 1
        self.c_sqe_rd_cmd_size += lba_num * SECT_SIZE

        sqe = SQEntry()
        sqe.opcode = SQEOpCodes.READ
        sqe.nsid = 1
        sqe.start_lba = lba_ptr
        sqe.num_lba = lba_num - 1  # Zero base0d
        sqe.cmd_id = self.tag_fifo.popleft()
        # This cmd_id is being reissued: it is no longer "completed" (_completed_cmd_ids tracks only
        # cmd_ids that finished a PRIOR command and have not yet been reused, so proc_cqes' phantom-CQE
        # diagnostic doesn't accumulate stale entries across the whole test).
        self._completed_cmd_ids.discard(sqe.cmd_id)
        sqe.mptr = self.mptr
        # NOTE: The RTL's dynamic first-fit page allocator decides the actual WRBUFF page `k` for
        # this command; the model does not try to predict it (PRP1/PRP2 are masked out in the
        # SQ-read CC scoreboard comparison instead), so build the SQE with k=0 for simplicity.
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
        # Snapshot the SQE for this slot in creation order BEFORE writing it into the mutable
        # ring, so a later command that wraps around and overwrites this slot can never corrupt
        # the scoreboard's expected content for the SQ MRD that reads it (see _resolve_sq_read_bytes).
        self._sq_snapshot.append((self.sqtdbl, sqe_ser))
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

        if transaction.meta + lba_num > STORAGE_CAP_LBAS:
            self.log.info(f"NVMe WR OOR: lba_ptr={transaction.meta} lba_num={lba_num} exceeds storage capacity {STORAGE_CAP_LBAS}. Reporting LBA_OUT_OF_RANGE.")
            self.m_op_stat_exp_out.append((False, IuventusOpStatCode.LBA_OUT_OF_RANGE))
            # An OOR write never becomes a real SQE (op_ctrl's own "LEAK FIX" frees its wr_alloc
            # reservation before ever dispatching one), so no payload is queued for it either.
            return

        self.c_sqes_disp += 1
        self.c_sqe_wr_cmds += 1
        self.c_sqe_wr_cmd_size += lba_num * SECT_SIZE

        sqe = SQEntry()
        sqe.opcode = SQEOpCodes.WRITE
        sqe.nsid = 1
        sqe.start_lba = transaction.meta
        sqe.num_lba = lba_num - 1  # Zero based
        sqe.cmd_id = self.tag_fifo.popleft()
        # See create_nvme_rd_cmd: this cmd_id is being reissued, so it's no longer "completed".
        self._completed_cmd_ids.discard(sqe.cmd_id)
        sqe.mptr = self.mptr
        # PRP1/PRP2 are masked out in the SQ-read CC scoreboard comparison (see create_nvme_rd_cmd
        # and disp_cc_resps), so their exact value here is unused for scoreboard purposes -- k=0
        # is kept for simplicity. The RTL's wr_alloc first-fit allocator decides the real RDBUFF
        # page k (which need not be FIRST_DATA_PAGE, since WRITEs reserving a bounded MAX_WR_PAGES
        # run rather than the whole buffer can be multiple-outstanding); this model does not try
        # to predict it -- the payload is queued instead and placed once nvme_ctrl_model discovers
        # the real k (see place_wr_payload).
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
        # See create_nvme_rd_cmd: snapshot before overwriting the live ring slot.
        self._sq_snapshot.append((self.sqtdbl, sqe_ser))
        self._sq_int[self.sqtdbl * SQE_SIZE : (self.sqtdbl + 1) * SQE_SIZE] = sqe_ser
        # Stash this write's payload (keyed by cmd_id) for placement into RDBUFF once
        # nvme_ctrl_model discovers the real page k from the actual dispatched SQE -- see
        # place_wr_payload.
        self._pending_wr_payloads[sqe.cmd_id] = transaction.data
        self.disp_dbl_update(self.sqtdbl_baddr)
