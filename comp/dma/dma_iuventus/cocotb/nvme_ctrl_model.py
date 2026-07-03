# nvme_ctrl_model.py: Model of the simplified NVMe controller able to do Read/Write operations
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import random
import logging
from collections import deque
from typing import List

import cocotb
from cocotb.triggers import Timer, Event
from cocotbext.ofm.mfb.transaction import MfbTransactionWithMeta, MfbTransaction
from cocotbext.ofm.pcie import RQHeader, RQMfbMeta, CCHeader, CQMfbMeta, CQHeader
from cocotbext.ofm.mfb.monitors import MFBMonitor
from cocotbext.ofm.mfb.drivers import MFBDriver

from misc_const import SECT_SIZE, IuventusBarSelection, PcieReqType, SQE_SIZE, MRRS, MPS, PAGE_SIZE, CQE_SIZE, BUFF_SIZE, STORAGE_CAP
from cocotbext.ofm.dma.iuventus import CQEStatCodeTypes, CQEStatusCodes, SQEntry, SQEOpCodes, CQEntry

class NVMEControllerModel:
    def __init__(self, sq_id : int, mptr : int, qsize : int, sq_baddr : int, cq_baddr : int, sqtdbl_baddr : int,
                 cqhdbl_baddr : int, cq_drv : MFBDriver, cc_mon : MFBMonitor, rq_mon : MFBMonitor,
                 rdbuff_prpl_baddr : int, rdbuff_prpl_data : List[int], wrbuff_prpl_baddr : int, wrbuff_prpl_data : List[int],
                 cq_drv_callback):
        self._cq_drv = cq_drv
        self.cq_drv_callback = cq_drv_callback
        self._total_lbas = (STORAGE_CAP * 1024**2) // SECT_SIZE  # 1 LBA = 512 bytes
        # self._storage = bytearray(STORAGE_CAP * 1024**2)
        random.seed(cocotb.RANDOM_SEED)
        self._storage = bytearray(random.randbytes(STORAGE_CAP * 1024**2))
        self._qsize = qsize
        self._mptr = mptr
        self.rdbuff_prpl_baddr = rdbuff_prpl_baddr
        self.rdbuff_prpl_data = rdbuff_prpl_data
        self.wrbuff_prpl_baddr = wrbuff_prpl_baddr
        self.wrbuff_prpl_data = wrbuff_prpl_data

        self._sq_baddr = sq_baddr
        self._cq_baddr = cq_baddr
        self._sqtdbl_baddr = sqtdbl_baddr
        self._cqhdbl_baddr = cqhdbl_baddr
        self._compl_buffer = {}  # tag -> bytearray
        self._sq_int = []
        self._cq_phase_tag = 1
        self._sq_id = sq_id

        self._sqtdbl = 0
        self._sqhdbl = 0
        self._cqtdbl = 0
        self._cqhdbl = 0
        self._processed_cmd_ids = set()  # detect duplicate SQE processing

        self._wrbuff_baddr = wrbuff_prpl_data[0]
        self._rdbuff_baddr = rdbuff_prpl_data[0]
        # Read/write buffer base addresses and size (128 KiB each)
        assert (self._wrbuff_baddr == 0) or (self._wrbuff_baddr % PAGE_SIZE == 0), "Write buffer base address must be page aligned"
        assert (self._rdbuff_baddr == 0) or (self._rdbuff_baddr % PAGE_SIZE == 0), "Read buffer base address must be page aligned"

        self._no_out_reqs_ev = Event()
        self._no_tags_ev = Event()
        self._available_tags = set(range(256))
        self._outstanding_reqs = deque()
        self._oust_lba_ptr = 0
        self.log = logging.getLogger("cocotb.%s" % (type(self).__qualname__))
        self.rd_mfb_exp_out = []

        self.c_sqes_proc = 0
        self.c_cqes_disp = 0
        self.c_pcie_disp_rds = 0
        self.c_pcie_disp_rd_bytes = 0
        self.c_pcie_disp_wrs = 0
        self.c_pcie_disp_wr_bytes = 0
        self.c_pcie_sq_rds = 0
        self.c_pcie_sq_rd_bytes = 0
        self.c_succ_compls = 0
        self.c_unsucc_compls = 0
        self.c_pcie_rdbuff_rds = 0
        self.c_pcie_rdbuff_rd_bytes = 0
        self.c_pcie_wrbuff_wrs = 0
        self.c_pcie_wrbuff_wr_bytes = 0
        self.c_pcie_cq_wrs = 0
        self.c_pcie_cq_wr_bytes = 0
        self.c_cqhdbl_reg_upds = 0
        self.c_sqtdbl_reg_upds = 0
        self.c_sqe_rd_cmds = 0
        self.c_sqe_rd_cmd_size = 0
        self.c_sqe_wr_cmds = 0
        self.c_sqe_wr_cmd_size = 0

        rq_mon.add_callback(self._upd_sqtdbl)
        cc_mon.add_callback(self._process_rd_compls)
        cocotb.start_soon(self._run_controller())

    def post_check(self):
        assert self._sqtdbl == self._sqhdbl, f"{type(self).__qualname__}: SQTDBL does not match SQHDBL after test"
        assert self._cqtdbl == self._cqhdbl, f"{type(self).__qualname__}: CQTDBL does not match CQHDBL after test"
        assert len(self._outstanding_reqs) == 0, f"{type(self).__qualname__}: There are outstanding requests after test"
        assert len(self._sq_int) == 0, f"{type(self).__qualname__}: There are unprocessed SQ entries after test"
        assert len(self._compl_buffer) == 0, f"{type(self).__qualname__}: There are incomplete read completions after test"

    def reinitailize_storage(self):
        self._storage = bytearray(random.randbytes(STORAGE_CAP * 1024**2))

    def clear_storage(self):
        self._storage = bytearray(STORAGE_CAP * 1024**2)

    def reset(self):
        self._sqtdbl = 0
        self._sqhdbl = 0
        self._cqtdbl = 0
        self._cqhdbl = 0
        self._compl_buffer.clear()
        self._available_tags = set(range(256))
        self._outstanding_reqs.clear()
        self._no_tags_ev.clear()
        self._no_out_reqs_ev.clear()
        self._sq_int.clear()
        self._cq_phase_tag = 1

        self.c_sqes_proc = 0
        self.c_cqes_disp = 0
        self.c_pcie_disp_rds = 0
        self.c_pcie_disp_rd_bytes = 0
        self.c_pcie_disp_wrs = 0
        self.c_pcie_disp_wr_bytes = 0
        self.c_pcie_sq_rds = 0
        self.c_pcie_sq_rd_bytes = 0
        self.c_succ_compls = 0
        self.c_unsucc_compls = 0
        self.c_pcie_rdbuff_rds = 0
        self.c_pcie_rdbuff_rd_bytes = 0
        self.c_pcie_wrbuff_wrs = 0
        self.c_pcie_wrbuff_wr_bytes = 0
        self.c_pcie_cq_wrs = 0
        self.c_pcie_cq_wr_bytes = 0
        self.c_cqhdbl_reg_upds = 0
        self.c_sqtdbl_reg_upds = 0
        self.c_sqe_rd_cmds = 0
        self.c_sqe_rd_cmd_size = 0
        self.c_sqe_wr_cmds = 0
        self.c_sqe_wr_cmd_size = 0

    def nullify_doorbell(self):
        self._sqtdbl = 0
        self._sqhdbl = 0
        self._cqtdbl = 0
        self._cqhdbl = 0

    def _parse_sqe(self, sqe_data):
        """Parse a bytearray (or bytes) containing one or more SQ entries and
        populate `self._sq_int` with parsed `SQEntry` objects.

        The input may contain multiple contiguous SQ entries. Any trailing
        incomplete bytes are ignored but a warning will be logged.
        Returns the number of parsed entries.
        """
        if not isinstance(sqe_data, (bytes, bytearray)):
            raise TypeError("sqe_data must be bytes or bytearray")

        entry_len = len(SQEntry()) // 8
        total_len = len(sqe_data)

        if total_len == 0:
            return 0

        if total_len < entry_len:
            assert False, f"{type(self).__qualname__}: input length {total_len} smaller than one SQE ({entry_len})"

        if total_len % entry_len != 0:
            if self.log.isEnabledFor(logging.WARNING):
                self.log.warning(f"input length {total_len} is not a multiple of SQE size {entry_len}, truncating")

        num_entries = total_len // entry_len
        if self.log.isEnabledFor(logging.INFO):
            self.log.info(f"Parsing {num_entries} SQ entries from input data")

        # reset parsed list
        self._sq_int = []

        for i in range(num_entries):
            start = i * entry_len
            chunk = sqe_data[start:start + entry_len]
            sqe_int = int.from_bytes(chunk, 'little')
            sqe_obj = SQEntry.deserialize(sqe_int)
            self._sq_int.append(sqe_obj)

        return len(self._sq_int)

    def _process_rd_compls(self, trans):
        hdr = int.from_bytes(trans.data[:len(CCHeader()) // 8], 'little')
        data = trans.data[len(CCHeader()) // 8:]
        hdr_deser = CCHeader.deserialize(hdr)

        tag = hdr_deser.tag
        byte_trans_len = hdr_deser.dword_count * 4

        # Ensure tag is present among outstanding requests
        assert any(req[0] == tag for req in self._outstanding_reqs), f"Received unexpected tag: {tag}"
        assert hdr_deser.tag == self._outstanding_reqs[-1][0], "Tag has not been returned in-order!"
        assert hdr_deser.byte_count != 0, "Received completion with 0 byte count!"
        assert hdr_deser.dword_count != 0, "Received completion with 0 Dword count!"
        assert hdr_deser.completion_status == 0, "Received completion with error status!"
        assert hdr_deser.byte_count in range(byte_trans_len - 3, byte_trans_len + 1) or hdr_deser.byte_count > byte_trans_len, "Byte count does not correspond to Dword count!"
        assert hdr_deser.cid == 1, "Completer ID does not match expected function number!"

        tag, req_bar,_ = self._outstanding_reqs[-1]
        if self.log.isEnabledFor(logging.INFO):
            self.log.info(f"Processing RD completion: tag={tag}, dword_count={hdr_deser.dword_count}, byte_count={hdr_deser.byte_count}, bar_id={req_bar}")

        # 1. Initialize buffer for this tag if it's the first chunk
        if tag not in self._compl_buffer:
            self._compl_buffer[tag] = bytearray()

        # 2. Append the current payload
        # Note: If the remaining byte count is less than the current TLP's payload size (DWord padded),
        # only take the actual valid bytes.
        valid_bytes = min(byte_trans_len, hdr_deser.byte_count)
        self._compl_buffer[tag].extend(data[:valid_bytes])
        if self.log.isEnabledFor(logging.DEBUG):
            self.log.debug(f"Appended data: {data[:valid_bytes].hex()}")

        # 3. Determine if this is the LAST completion for this specific Read Request
        # PCIe Spec: byte_count is the remaining bytes including this TLP.
        if hdr_deser.byte_count in range(byte_trans_len - 3, byte_trans_len + 1):
            # Full request reassembled!
            full_data = self._compl_buffer.pop(tag)
            if self.log.isEnabledFor(logging.DEBUG):
                self.log.debug(f"Full read data for tag {tag} assembled: {full_data.hex()}")

            # Remove from outstanding requests (assuming strict order for your pop_back)
            _, _, lba_offs = self._outstanding_reqs.pop()

            if req_bar == IuventusBarSelection.SQ_BAR:
                # Process SQ read data
                parsed_entries = self._parse_sqe(full_data)
                assert parsed_entries > 0, "Parsed 0 SQ entries from read data!"

            elif req_bar == IuventusBarSelection.RD_BUFF_BAR:
                # Process Read Buffer data
                byte_offs = (self._oust_lba_ptr + lba_offs) * SECT_SIZE
                self._storage[byte_offs:byte_offs + len(full_data)] = full_data

            # Release tag if all of the completions came for the requested data
            self._available_tags.add(tag)
            self._no_tags_ev.set()

        if not self._outstanding_reqs:
            self._no_out_reqs_ev.set()

    # SQTDBL/CQHDBL updates are the only ones that come on the RQ interface
    # Added as a callback to RQ monitor
    def _upd_sqtdbl(self, trans):
        hdr = int.from_bytes(trans.data[:len(RQHeader()) // 8], 'little')
        data = int.from_bytes(trans.data[len(RQHeader()) // 8:], 'little')
        meta = RQMfbMeta.deserialize(trans.meta)
        hdr_deser = RQHeader.deserialize(hdr)

        assert meta.firstBe == 0x3, "Invalid FBE for DBL pointer update command"
        assert meta.lastBe == 0, "Invalid LBE for DBL pointer update command"
        assert hdr_deser.req_type == 0b0001, "Invalid request type for DBL pointer update command"
        assert hdr_deser.addr == (self._sqtdbl_baddr >> 2) or hdr_deser.addr == (self._cqhdbl_baddr >> 2), "Invalid address for DBL pointer update command"
        assert hdr_deser.dword_count == 1, "Invalid address for DBL pointer update command"

        # Update internal pointer values
        if hdr_deser.addr == (self._sqtdbl_baddr >> 2):
            if self.log.isEnabledFor(logging.INFO):
                self.log.info(f"Updating SQTDBL to {data}")
            self._sqtdbl = data & 0xFFFF
            self.c_sqtdbl_reg_upds += 1
        elif hdr_deser.addr == (self._cqhdbl_baddr >> 2):
            if self.log.isEnabledFor(logging.INFO):
                self.log.info(f"Updating CQHDBL to {data}")
            self._cqhdbl = data & 0xFFFF
            self.c_cqhdbl_reg_upds += 1

    def _dispatch_wr_req(self, base_addr, data,
                            target_bar, buffer_size):
        """
        Generalized PCIe MWr (Write) generator for ring buffers.

        :param base_addr: Base physical address of the buffer.
        :param start_offset: Starting byte offset from base_addr.
        :param data: bytearray of raw data to be written.
        :param target_bar: The BAR ID for PCIe routing.
        :param buffer_size: Size of the circular buffer (strictly > 0).
        """
        total_bytes = len(data)
        if self.log.isEnabledFor(logging.INFO):
            self.log.info(f"Dispatching WR request:\n"
                        f"base_addr=0x{base_addr:x}, total_bytes={total_bytes}\n"
                        f"target_bar={target_bar}, buffer_size={buffer_size}")

        # 1. Validation
        assert total_bytes > 0, "total_bytes must be greater than zero."
        assert buffer_size is not None and buffer_size != 0, "buffer_size cannot be zero if provided."
        assert target_bar in (IuventusBarSelection.CQ_BAR, IuventusBarSelection.WR_BUFF_BAR), "Invalid target_bar for write request."

        bytes_sent = 0
        current_offset = 0

        while bytes_sent < total_bytes:
            # 2. Physical Address Calculation
            phys_addr = base_addr + current_offset

            # 3. Determine Chunk Size (TLP Payload Size)
            # Rule A: Cannot exceed MPS (Maximum Payload Size) constant
            chunk_size = min(total_bytes - bytes_sent, MPS)

            # Rule B: Cannot cross a 4KB address boundary (PCIe Spec)
            bytes_to_4k = 4096 - (phys_addr % 4096)
            chunk_size = min(chunk_size, bytes_to_4k)

            # Rule C: Ring Buffer Wrap Guard
            # Ensure the chunk is truncated at the end of the buffer to wrap properly
            bytes_to_buf_end = buffer_size - (current_offset % buffer_size)
            chunk_size = min(chunk_size, bytes_to_buf_end)

            # 4. Extract data slice for this specific TLP
            payload = data[bytes_sent : bytes_sent + chunk_size]

            if self.log.isEnabledFor(logging.DEBUG):
                self.log.debug(f"Preparing WR TLP: phys_addr=0x{phys_addr:x}, chunk_size={chunk_size},\n"
                            f"current_offset={current_offset}, bytes_sent={bytes_sent}, total_bytes={total_bytes}")

            # 6. Construct PCIe Header
            cq_hdr = CQHeader()
            cq_hdr.bar_apper = 26
            cq_hdr.tgt_func = 1
            cq_hdr.bar_id = target_bar
            cq_hdr.addr = phys_addr >> 2
            cq_hdr.dword_count = chunk_size // 4
            cq_hdr.req_type = PcieReqType.MWR

            cq_mfb_meta = CQMfbMeta()
            cq_mfb_meta.firstBe = [0xF, 0xE, 0xC, 0x8][current_offset % 4]
            cq_mfb_meta.lastBe = [0xF, 0x1, 0x3, 0x7][(current_offset + chunk_size) % 4]

            if chunk_size <= 4:
                cq_mfb_meta.firstBe &= cq_mfb_meta.lastBe
                cq_mfb_meta.lastBe = 0

            if self.log.isEnabledFor(logging.DEBUG):
                self.log.debug(f"Constructed WR Header: {cq_hdr} with Meta: {cq_mfb_meta}")

            # 7. Dispatch Transaction (Header + Payload)
            cq_trans = MfbTransactionWithMeta(
                data=cq_hdr.serialize().to_bytes(len(CQHeader()) // 8, 'little') + (b'\x00' * (current_offset % 4)) + payload,
                meta=cq_mfb_meta.serialize()
            )
            self._cq_drv.append(cq_trans)
            self.cq_drv_callback(cq_trans)

            self.c_pcie_disp_wr_bytes += chunk_size
            self.c_pcie_disp_wrs += 1

            if target_bar == IuventusBarSelection.CQ_BAR:
                self.c_pcie_cq_wr_bytes += chunk_size
                self.c_pcie_cq_wrs += 1
            elif target_bar == IuventusBarSelection.WR_BUFF_BAR:
                self.c_pcie_wrbuff_wr_bytes += chunk_size
                self.c_pcie_wrbuff_wrs += 1

            # 9. Update loop cursors
            bytes_sent += chunk_size
            current_offset = (current_offset + chunk_size) % buffer_size

            assert bytes_sent > 0, "FATAL: bytes_sent iterated to negative!"
            assert chunk_size > 0, "FATAL: chunk_size iterated to negative!"

    async def _dispatch_rd_req(self, base_addr, total_bytes,
                            target_bar, buffer_size):
        """
        Generalized PCIe MRD generator with safety guards.
        """
        if self.log.isEnabledFor(logging.INFO):
            self.log.info(f"Dispatching RD request:\n"
                        f"base_addr=0x{base_addr:x}, total_bytes={total_bytes}\n"
                        f"target_bar={target_bar}, buffer_size={buffer_size}")

        # 1. Guard Clauses: Ensure we aren't processing empty requests
        assert total_bytes > 0, "total_bytes must be greater than zero."
        assert buffer_size is not None and buffer_size != 0, "buffer_size cannot be zero if provided."
        assert target_bar in (IuventusBarSelection.SQ_BAR, IuventusBarSelection.RD_BUFF_BAR), "Invalid target_bar for read request."

        bytes_left = total_bytes
        current_offset = 0

        while bytes_left > 0:
            # 2. Physical Address Calculation
            phys_addr = base_addr + current_offset

            # 3. Determine Chunk Size (TLP Payload Size)
            # Rule: Minimum of (Remaining bytes, MRRS, distance to 4KB boundary)
            chunk_size = min(bytes_left, MRRS)

            bytes_to_4k = PAGE_SIZE - (phys_addr % PAGE_SIZE)
            chunk_size = min(chunk_size, bytes_to_4k)

            # 4. Ring Buffer Wrap Guard
            # If wrapping is enabled, don't let a single TLP cross the buffer end
            bytes_to_buf_end = buffer_size - current_offset
            chunk_size = min(chunk_size, bytes_to_buf_end)

            # 5. Resource Arbitration (8-bit Tag Pool)
            if not self._available_tags:
                await self._no_tags_ev.wait()
                self._no_tags_ev.clear()

            current_tag = self._available_tags.pop()

            # Track the request: (Tag, BAR_ID, Expected_Size)
            # Adding size helps the completion handler know when a tag is 'done'
            self._outstanding_reqs.appendleft((current_tag, target_bar, current_offset))

            if self.log.isEnabledFor(logging.INFO):
                self.log.info(f"Preparing RD TLP:\n"
                            f"phys_addr=0x{phys_addr:x}, chunk_size={chunk_size}, current_offset={current_offset}\n"
                            f"tag={current_tag}")

            # 6. Construct PCIe Header
            cq_hdr = CQHeader()
            cq_hdr.tag = current_tag
            cq_hdr.bar_apper = 26
            cq_hdr.tgt_func = 1
            cq_hdr.bar_id = target_bar
            cq_hdr.addr = phys_addr >> 2
            cq_hdr.dword_count = chunk_size // 4
            cq_hdr.req_type = PcieReqType.MRD

            cq_mfb_meta = CQMfbMeta()
            cq_mfb_meta.firstBe = [0xF, 0xE, 0xC, 0x8][current_offset % 4]
            cq_mfb_meta.lastBe = [0xF, 0x1, 0x3, 0x7][(current_offset + chunk_size) % 4]

            if chunk_size <= 4:
                cq_mfb_meta.firstBe &= cq_mfb_meta.lastBe
                cq_mfb_meta.lastBe = 0

            if self.log.isEnabledFor(logging.DEBUG):
                self.log.debug(f"Constructed RD Header: {cq_hdr} with Meta: {cq_mfb_meta}")

            # 7. Dispatch to Driver
            cq_trans = MfbTransactionWithMeta(
                data=cq_hdr.serialize().to_bytes(len(CQHeader()) // 8, 'little'),
                meta=cq_mfb_meta.serialize()
            )
            self._cq_drv.append(cq_trans)
            self.cq_drv_callback(cq_trans)

            self.c_pcie_disp_rd_bytes += chunk_size
            self.c_pcie_disp_rds += 1

            if target_bar == IuventusBarSelection.SQ_BAR:
                self.c_pcie_sq_rd_bytes += chunk_size
                self.c_pcie_sq_rds += 1
            elif target_bar == IuventusBarSelection.RD_BUFF_BAR:
                self.c_pcie_rdbuff_rd_bytes += chunk_size
                self.c_pcie_rdbuff_rds += 1

            # 8. Update cursors for the next TLP
            bytes_left -= chunk_size
            current_offset = (current_offset + chunk_size) % buffer_size

    async def _complete_sqe(self, cmd_id):
        """Generate a completion entry for the given command ID."""
        cq_entry = CQEntry()
        cq_entry.sq_id = self._sq_id
        cq_entry.sqhdbl = self._sqhdbl
        cq_entry.cmd_id = cmd_id
        cq_entry.phase_tag = self._cq_phase_tag
        # TODO: Vary the status codes
        cq_entry.stat_code = CQEStatusCodes.SUCCESS  # Successful completion
        cq_entry.stat_code_type = CQEStatCodeTypes.GENERIC  # Generic Command Status

        if self.log.isEnabledFor(logging.INFO):
            self.log.info(f"Completing SQE cmd_id={cmd_id} with phase_tag={self._cq_phase_tag} on CQTDBL={self._cqtdbl}")
        if self.log.isEnabledFor(logging.DEBUG):
            self.log.debug(f"Generated CQE: {cq_entry}")

        # Serialize CQE
        data = cq_entry.serialize().to_bytes(len(CQEntry()) // 8, 'little')

        # Wait if CQ is full: next_tail would collide with head
        while (self._cqtdbl + 1) % self._qsize == self._cqhdbl:
            if self.log.isEnabledFor(logging.DEBUG):
                self.log.debug("Completion Queue full, waiting for space")
            await Timer(10, unit='ns')

        # Dispatch the CQ entry to memory (CQ BAR)
        self._dispatch_wr_req(
            base_addr=self._cq_baddr + (self._cqtdbl * CQE_SIZE),
            data=data,
            target_bar=IuventusBarSelection.CQ_BAR,
            buffer_size=self._qsize * CQE_SIZE
        )

        # Advance tail and toggle phase tag on wrap
        self._cqtdbl = (self._cqtdbl + 1) % self._qsize
        self.c_cqes_disp += 1

        is_succ = cq_entry.stat_code_type == CQEStatCodeTypes.GENERIC and cq_entry.stat_code == CQEStatusCodes.SUCCESS
        if is_succ:
            self.c_succ_compls += 1
        else:
            self.c_unsucc_compls += 1

        if self._cqtdbl == 0:
            self._cq_phase_tag ^= 1

    async def _proc_sq_entries(self):

        rng = random.Random(cocotb.RANDOM_SEED)
        # Shuffle the SQ entries to simulate out-of-order processing
        rng.shuffle(self._sq_int)

        # Check for unique cmd_ids in the self._sq_int
        cmd_ids = [sqe.cmd_id for sqe in self._sq_int]
        assert len(cmd_ids) == len(set(cmd_ids)), "Duplicate cmd_id found in SQ entries!"

        for sqe in self._sq_int:
            if self.log.isEnabledFor(logging.INFO):
                self.log.info(f"Processing SQE:\n"
                            f"cmd_id={sqe.cmd_id}, opcode={sqe.opcode}\n"
                            f"prp1=0x{sqe.prp1:x}, prp2=0x{sqe.prp2:x}\n"
                            f"start_lba={sqe.start_lba}, num_lba={sqe.num_lba}")

            assert sqe.fuse == 0, "Non-zero FUSE field in SQE"
            assert sqe.rsv1 == 0, "Non-zero RSV1 field in SQE"
            assert sqe.rsv2 == 0, "Non-zero RSV2 field in SQE"
            assert sqe.rsv3 == 0, "Non-zero RSV3 field in SQE"
            assert sqe.rsv4 == 0, "Non-zero RSV4 field in SQE"
            assert sqe.nsid == 1, "Non-one NSID field in SQE"
            assert sqe.mptr == self._mptr, "MPTR field in SQE does not match model MPTR"
            assert sqe.psdt == 0, "Non-zero PSDT field in SQE"
            assert sqe.dsm == 0, "Non-zero DSM field in SQE"
            assert sqe.elbat == 0, "Non-zero ELBAT field in SQE"
            assert sqe.elbatm == 0, "Non-zero ELBATM field in SQE"
            assert sqe.eilbrt == 0, "Non-zero EILBRT field in SQE"
            assert sqe.prinfo == 0, "Non-zero PRINFO field in SQE"
            assert sqe.fua == 0, "Non-zero FUA field in SQE"
            assert sqe.lr == 0, "Non-zero LR field in SQE"

            start_lba = sqe.start_lba
            num_lba = sqe.num_lba + 1  # zero-based value
            byte_offset = start_lba * SECT_SIZE
            byte_count = num_lba * SECT_SIZE

            assert byte_count <= BUFF_SIZE, f"SQE cmd_id={sqe.cmd_id}: requested {byte_count} bytes exceeds buffer size"
            assert (start_lba + num_lba) <= self._total_lbas, f"Command exceeds storage capacity: start LBA {start_lba}, num LBA {num_lba}, total LBAs {self._total_lbas}"
            assert sqe.prp1 != 0, f"PRP1 0x{sqe.prp1:x} cannot be zero"
            assert sqe.prp1 % MPS == 0, f"PRP1 0x{sqe.prp1:x} is not 4KiB aligned"

            if sqe.opcode == SQEOpCodes.READ:
                # This adds expected data that were read to the RD MFB monitor callback that is
                # connected through scoreboard in order to double check read data correctness
                self.rd_mfb_exp_out.append(MfbTransaction(data=self._storage[byte_offset:byte_offset + byte_count]))

                if byte_count > 2 * PAGE_SIZE:
                    if self.log.isEnabledFor(logging.INFO):
                        self.log.info(f"SQE cmd_id={sqe.cmd_id}: Mult-page read, using PRP List for storage offset {byte_offset}")

                    assert sqe.prp1 in self.wrbuff_prpl_data, f"SQE cmd_id={sqe.cmd_id}: PRP1 0x{sqe.prp1:x} not in write buffer PRP list"
                    assert sqe.prp2 != 0, f"SQE cmd_id={sqe.cmd_id}: PRP2 cannot be zero for multi-page read"
                    assert sqe.prp2 == self.wrbuff_prpl_baddr, f"SQE cmd_id={sqe.cmd_id}: PRP2 0x{sqe.prp2:x} does not point to PRP List ({self.wrbuff_prpl_baddr:x})"

                    # First page from PRP1
                    chunk = self._storage[byte_offset : byte_offset + PAGE_SIZE]
                    self._dispatch_wr_req(
                        base_addr=sqe.prp1,
                        data=chunk,
                        target_bar=IuventusBarSelection.WR_BUFF_BAR,
                        buffer_size=BUFF_SIZE)

                    # Subsequent pages from PRP List
                    rem_bytes = byte_count - PAGE_SIZE
                    prpl_idx = 1
                    while rem_bytes > 0:
                        prp_entry = self.wrbuff_prpl_data[prpl_idx]
                        byte_offset += PAGE_SIZE
                        chunk = self._storage[byte_offset : byte_offset + PAGE_SIZE]

                        if self.log.isEnabledFor(logging.INFO):
                            self.log.info(f"SQE cmd_id={sqe.cmd_id}: Processing PRP List entry {prpl_idx}: 0x{prp_entry:x} for storage offset {byte_offset}")

                        self._dispatch_wr_req(
                            base_addr=prp_entry,
                            data=chunk,
                            target_bar=IuventusBarSelection.WR_BUFF_BAR,
                            buffer_size=BUFF_SIZE)

                        rem_bytes -= PAGE_SIZE
                        prpl_idx += 1

                elif byte_count > PAGE_SIZE and byte_count <= 2 * PAGE_SIZE:
                    if self.log.isEnabledFor(logging.INFO):
                        self.log.info(f"SQE cmd_id={sqe.cmd_id}: Read spans two pages, splitting into two WR requests")

                    assert sqe.prp1 in self.wrbuff_prpl_data, f"SQE cmd_id={sqe.cmd_id}: PRP1 0x{sqe.prp1:x} not in write buffer PRP list"
                    assert sqe.prp2 in self.wrbuff_prpl_data, f"SQE cmd_id={sqe.cmd_id}: PRP2 0x{sqe.prp2:x} not in write buffer PRP list"
                    assert sqe.prp2 % MPS == 0, f"PRP2 0x{sqe.prp2:x} is not 4KiB aligned"

                    first_chunk = self._storage[byte_offset : byte_offset + PAGE_SIZE]
                    second_chunk = self._storage[byte_offset + PAGE_SIZE : byte_offset + byte_count]

                    self._dispatch_wr_req(
                        base_addr=sqe.prp1,
                        data=first_chunk,
                        target_bar=IuventusBarSelection.WR_BUFF_BAR,
                        buffer_size=BUFF_SIZE)

                    self._dispatch_wr_req(
                        base_addr=sqe.prp2,
                        data=second_chunk,
                        target_bar=IuventusBarSelection.WR_BUFF_BAR,
                        buffer_size=BUFF_SIZE)
                else:
                    if self.log.isEnabledFor(logging.INFO):
                        self.log.info(f"SQE cmd_id={sqe.cmd_id}: Single-page Read, dispatching one WR request")

                    assert sqe.prp1 in self.wrbuff_prpl_data, f"SQE cmd_id={sqe.cmd_id}: PRP1 0x{sqe.prp1:x} not in write buffer PRP list"
                    assert sqe.prp2 == 0, f"SQE cmd_id={sqe.cmd_id}: PRP2 must be zero for single-page read"

                    self._dispatch_wr_req(
                        base_addr=sqe.prp1,
                        data=self._storage[byte_offset:byte_offset + byte_count],
                        target_bar=IuventusBarSelection.WR_BUFF_BAR,
                        buffer_size=BUFF_SIZE)

                self.c_sqe_rd_cmds += 1
                self.c_sqe_rd_cmd_size += byte_count

            elif sqe.opcode == SQEOpCodes.WRITE:
                self._oust_lba_ptr = start_lba

                if byte_count > 2 * PAGE_SIZE:
                    if self.log.isEnabledFor(logging.INFO):
                        self.log.info(f"SQE cmd_id={sqe.cmd_id}: Mult-page write, using PRP List for storage offset {byte_offset}")

                    assert sqe.prp1 in self.rdbuff_prpl_data, f"SQE cmd_id={sqe.cmd_id}: PRP1 0x{sqe.prp1:x} not in read buffer PRP list"
                    assert sqe.prp2 != 0, f"SQE cmd_id={sqe.cmd_id}: PRP2 cannot be zero for multi-page write"
                    assert sqe.prp2 == self.rdbuff_prpl_baddr, f"SQE cmd_id={sqe.cmd_id}: PRP2 0x{sqe.prp2:x} does not point to PRP List ({self.rdbuff_prpl_baddr:x})"

                    # First page from PRP1
                    await self._dispatch_rd_req(
                        base_addr=sqe.prp1,
                        total_bytes=PAGE_SIZE,
                        target_bar=IuventusBarSelection.RD_BUFF_BAR,
                        buffer_size=BUFF_SIZE)

                    # Subsequent pages from PRP List
                    rem_bytes = byte_count - PAGE_SIZE
                    prpl_idx = 1
                    while rem_bytes > 0:
                        prp_entry = self.rdbuff_prpl_data[prpl_idx]

                        if self.log.isEnabledFor(logging.INFO):
                            self.log.info(f"SQE cmd_id={sqe.cmd_id}: Processing PRP List entry {prpl_idx}: 0x{prp_entry:x} for storage offset {byte_offset}")

                        await self._dispatch_rd_req(
                            base_addr=prp_entry,
                            total_bytes=min(PAGE_SIZE, rem_bytes),
                            target_bar=IuventusBarSelection.RD_BUFF_BAR,
                            buffer_size=BUFF_SIZE)

                        rem_bytes -= PAGE_SIZE
                        prpl_idx += 1

                elif byte_count > PAGE_SIZE and byte_count <= 2 * PAGE_SIZE:
                    if self.log.isEnabledFor(logging.INFO):
                        self.log.info(f"SQE cmd_id={sqe.cmd_id}: Write spans two pages, splitting into two RD requests")

                    assert sqe.prp1 in self.rdbuff_prpl_data, f"SQE cmd_id={sqe.cmd_id}: PRP1 0x{sqe.prp1:x} not in read buffer PRP list"
                    assert sqe.prp2 in self.rdbuff_prpl_data, f"SQE cmd_id={sqe.cmd_id}: PRP2 0x{sqe.prp2:x} not in read buffer PRP list"
                    assert sqe.prp2 % MPS == 0, f"PRP2 0x{sqe.prp2:x} is not 4KiB aligned"

                    await self._dispatch_rd_req(
                        base_addr=sqe.prp1,
                        total_bytes=PAGE_SIZE,
                        target_bar=IuventusBarSelection.RD_BUFF_BAR,
                        buffer_size=BUFF_SIZE)

                    await self._dispatch_rd_req(
                        base_addr=sqe.prp2,
                        total_bytes=byte_count - PAGE_SIZE,
                        target_bar=IuventusBarSelection.RD_BUFF_BAR,
                        buffer_size=BUFF_SIZE)
                else:
                    if self.log.isEnabledFor(logging.INFO):
                        self.log.info(f"SQE cmd_id={sqe.cmd_id}: Single-page Write, dispatching one RD request")

                    assert sqe.prp1 in self.rdbuff_prpl_data, f"SQE cmd_id={sqe.cmd_id}: PRP1 0x{sqe.prp1:x} not in read buffer PRP list"
                    assert sqe.prp2 == 0, f"SQE cmd_id={sqe.cmd_id}: PRP2 must be zero for single-page write"

                    await self._dispatch_rd_req(
                        base_addr=sqe.prp1,
                        total_bytes=byte_count,
                        target_bar=IuventusBarSelection.RD_BUFF_BAR,
                        buffer_size=BUFF_SIZE)

                self.c_sqe_wr_cmds += 1
                self.c_sqe_wr_cmd_size += byte_count

                # TODO: There has to be somehow passed to which position in the storage should the read data
                # be written. Each tag after its completion (i.e. when all of its data arrived) should have
                # an offset in the storage associated with it. Or something like that...

                # For write commands we need to wait until data are going to be written to the storage
                await self._no_out_reqs_ev.wait()
                self._no_out_reqs_ev.clear()
            else:
                assert False, f"Unsupported SQE opcode: {sqe.opcode}"

            self._sqhdbl = (self._sqhdbl + 1) % self._qsize
            self.c_sqes_proc += 1
            if sqe.cmd_id in self._processed_cmd_ids:
                self.log.error(
                    f"DUPLICATE SQE PROCESSING: cmd_id={sqe.cmd_id} "
                    f"sqes_proc={self.c_sqes_proc} sqhdbl={self._sqhdbl} sqtdbl={self._sqtdbl} "
                    f"cqtdbl={self._cqtdbl} cqhdbl={self._cqhdbl}"
                )
            self._processed_cmd_ids.add(sqe.cmd_id)
            await self._complete_sqe(sqe.cmd_id)

        self._sq_int.clear()  # Clear processed entries

    async def _run_controller(self):
        while True:
            # NOTE: Probably obsolete
            await Timer(1, unit='ns')

            if self._sqhdbl != self._sqtdbl:
                # Send read requests for new SQ entries
                await self._dispatch_rd_req(
                    base_addr=self._sq_baddr + self._sqhdbl * SQE_SIZE,
                    total_bytes=((self._sqtdbl - self._sqhdbl + self._qsize) % self._qsize) * SQE_SIZE,
                    target_bar=IuventusBarSelection.SQ_BAR,
                    buffer_size=self._qsize * SQE_SIZE
                )

                # Wait until all outstanding read requests are completed. Otherwise, there would
                # be multiple read requests dispatched for a single SQ entry.
                await self._no_out_reqs_ev.wait()
                self._no_out_reqs_ev.clear()

            if self._sq_int:
                await self._proc_sq_entries()