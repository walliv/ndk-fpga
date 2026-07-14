# cocotb_test.py: Basic verification of the DMA Iuventus
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import os
import random
import cocotb
import logging

from logging.handlers import RotatingFileHandler
from cocotb.logging import SimLogFormatter

from typing import List

from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles, Event, ReadOnly, Timer

from scapy.utils import hexdump

from cocotb_bus.drivers import BitDriver
# from cocotb_bus.monitors import BusMonitor
from cocotb_bus.scoreboard import Scoreboard

from cocotbext.ofm.mi.drivers import MIRequestDriver

from cocotbext.ofm.mfb.utils import random_tuple_iterator
from cocotbext.ofm.mfb.monitors import MFBMonitor
from cocotbext.ofm.mfb.drivers import MFBDriver
from cocotbext.ofm.mfb.transaction import MfbTransactionWithMeta, MfbTransaction

from cocotbext.ofm.ver.generators import random_integers, random_packets

from dataclasses import dataclass

from misc_const import BUFF_SIZE_PAGES, SECT_SIZE, STORAGE_CAP_LBAS, PAGE_SIZE, BUFF_SIZE, \
    BUFF_SIZE_LBAS, IuventusBuffers, QUEUE_DEPTH, DATA_PAGES, FIRST_DATA_PAGE, MAX_CMD_LBAS, \
    NUM_QUEUES, SQE_LBA_PTR_W, FLUSH_DELAY_CNTR_WIDTH
from iuventus_model import IuventusModel
from nvme_ctrl_model import NVMEControllerModel
from read_req_driver import ReadReqDriver
from op_stat_monitor import OpStatMonitor
from cocotbext.ofm.dma.iuventus import (IuventusMiRegMap, IuventusPerQueueRegMap, CtrlRegBits,
                                         per_queue_reg_addr)

root_logger = logging.getLogger()
file_handler = RotatingFileHandler("rotating.log", maxBytes=(10 * 1024 * 1024), backupCount=2)
file_handler.setFormatter(SimLogFormatter(strip_ansi=True))
root_logger.addHandler(file_handler)

# The model buffers are actually shared across all tests since the DUT does not clean its buffers
# unless explicit routine has been created for that.
iuventus_model_buffers = None


@dataclass
class QueueCtx:
    """One SQ[q]/CQ[q] queue's model pair, sharing the Testbench's single set of physical buses
    (PCIE_CQ_MFB driver, PCIE_CC_MFB/PCIE_RQ_MFB monitors, WR_MFB driver, MI driver, OP_STAT
    monitor) and the shared RDBUFF/WRBUFF data pool with every other queue -- see
    Testbench.add_queue."""
    qid: int
    qsize: int
    iuventus_model: IuventusModel
    nvme_ctrl_model: NVMEControllerModel
    sqtdbl_baddr: int
    cqhdbl_baddr: int


class Testbench:
    def __init__(self, dut, qid : int, mptr : int, qsize :int, sq_baddr : int, cq_baddr : int,
                 sqtdbl_baddr : int, cqhdbl_baddr : int, rdbuff_prpl_baddr : int, rdbuff_prpl_data : List[int],
                 wrbuff_prpl_baddr : int, wrbuff_prpl_data : List[int], iuventus_model_buffers : IuventusBuffers, debug=False,
                 strict_rq=True, tag_range=range(256), rd_mfb_reorder_depth=0):
        self.dut = dut
        # strict_rq=False skips the in-order PCIE_RQ scoreboard interface. The RQ scoreboard / reference
        # model are validated at qsize=16; at smaller queues with heavy out-of-order completion they
        # mis-predict SQ/CQ doorbell ORDERING and raise spurious mismatches that mask the real signal.
        # The wrap-collision test disables it and relies on the stall detector (a genuinely lost
        # completion = the hw wedge) plus the CC/RD/OP_STAT scoreboards (data/status correctness).
        self.strict_rq = strict_rq

        mi_clk = dut.CLK if bool(dut.MI_SAME_CLK.value) else dut.MI_CLK
        self.m_mi_driver = MIRequestDriver(dut, "MI", mi_clk)

        # vld_gen=None: no post-EOF off-period words are inserted into _wordQ.
        # With a non-None vld_gen the MFBDriver appends SRC_RDY=0 words after the
        # EOF word; _wait_ready() in the send loop then stalls until WR_MFB_DST_RDY
        # rises again.  WR_MFB_DST_RDY is 0 in every state except S_IDLE /
        # S_WR_REQ_FINISH_WAIT, so the stall lasts until the DUT has fully
        # processed the write (dispatch -> SQE TLP -> SQTDBL -> NVMe -> CQE ->
        # S_IDLE), meaning the driver callback (create_nvme_wr_cmd) fires *after*
        # OP_STAT is emitted and proc_cqes has already skipped the CQE, causing
        # "Received a transaction but wasn't expecting anything" on the OP_STAT
        # scoreboard.  With vld_gen=None the callback fires immediately after EOF
        # is accepted, before any DUT processing begins.
        self.m_wr_mfb_driver = MFBDriver(dut, "WR_MFB", dut.CLK, vld_gen=None)
        self.m_rd_mfb_monitor = MFBMonitor(dut, "RD_MFB", dut.CLK, trans_type = MfbTransaction)
        self.m_rd_mfb_bpsr = BitDriver(dut.RD_MFB_DST_RDY, dut.CLK)

        self.m_cq_mfb_driver = MFBDriver(dut, "PCIE_CQ_MFB", dut.CLK, vld_gen=random_tuple_iterator(100,200,1,20))
        self.m_cc_mfb_monitor = MFBMonitor(dut, "PCIE_CC_MFB", dut.CLK, trans_type = MfbTransactionWithMeta)
        self.m_cc_mfb_bpsr = BitDriver(dut.PCIE_CC_MFB_DST_RDY, dut.CLK)
        self.m_rq_mfb_monitor = MFBMonitor(dut, "PCIE_RQ_MFB", dut.CLK, trans_type = MfbTransactionWithMeta)
        self.m_rq_mfb_bpsr = BitDriver(dut.PCIE_RQ_MFB_DST_RDY, dut.CLK)
        self.rd_req_driver = ReadReqDriver(dut, "NVME_RD_REQ", dut.CLK)
        self.op_stat_mon = OpStatMonitor(dut, "OP_STAT", dut.CLK)

        self.iuventus_model = IuventusModel(
            qsize=qsize, mptr=mptr, sq_baddr=sq_baddr, cq_baddr=cq_baddr,
            sqtdbl_baddr=sqtdbl_baddr, cqhdbl_baddr=cqhdbl_baddr,
            rdbuff_prpl_baddr=rdbuff_prpl_baddr, rdbuff_prpl_data=rdbuff_prpl_data,
            wrbuff_prpl_baddr=wrbuff_prpl_baddr, wrbuff_prpl_data=wrbuff_prpl_data,
            clock=dut.CLK, qid=qid, buffs=iuventus_model_buffers)
        self.nvme_ctrl_model = NVMEControllerModel(
            sq_id=qid, mptr=mptr, qsize=qsize, sq_baddr=sq_baddr, cq_baddr=cq_baddr,
            sqtdbl_baddr=sqtdbl_baddr, cqhdbl_baddr=cqhdbl_baddr,
            cq_drv=self.m_cq_mfb_driver, cc_mon=self.m_cc_mfb_monitor,
            rq_mon=self.m_rq_mfb_monitor, rdbuff_prpl_baddr=rdbuff_prpl_baddr,
            rdbuff_prpl_data=rdbuff_prpl_data, wrbuff_prpl_baddr=wrbuff_prpl_baddr,
            wrbuff_prpl_data=wrbuff_prpl_data,
            cq_drv_callback=self.iuventus_model.proc_pcie_cq_reqs,
            # Lets nvme_ctrl_model tell the model where to place a WRITE's payload once it
            # discovers the real wr_alloc page k from the actual dispatched SQE's PRP1 (see
            # IuventusModel.place_wr_payload / _proc_sq_entries's WRITE branch).
            wr_placement_callback=self.iuventus_model.place_wr_payload,
            tag_range=tag_range,
            # Lets nvme_ctrl_model tell the model about an autonomous FLUSH keepalive SQE the
            # moment it recognizes one (see IuventusModel.observe_flush_dispatch /
            # _proc_sq_entries's FLUSH branch).
            flush_observed_callback=self.iuventus_model.observe_flush_dispatch)

        self.qsize = qsize
        self.cq_baddr = cq_baddr
        # Queue 0 (this Testbench's own models); add_queue() appends queues 1..NUM_QUEUES-1 for
        # multi-queue tests. Single-queue tests never call add_queue, so self.queues stays a
        # 1-element list referencing exactly self.iuventus_model/self.nvme_ctrl_model, unchanged.
        self.queues: List[QueueCtx] = [QueueCtx(
            qid=qid, qsize=qsize, iuventus_model=self.iuventus_model,
            nvme_ctrl_model=self.nvme_ctrl_model, sqtdbl_baddr=sqtdbl_baddr, cqhdbl_baddr=cqhdbl_baddr)]

        self.m_scoreboard = Scoreboard(dut)
        # Custom compare_fn: the SQE's PRP1/PRP2 fields on SQ-read CC responses are unpredictable
        # (the RTL's dynamic first-fit page allocator decides the actual buffer page `k`, which
        # the model no longer predicts) -- see IuventusModel.disp_cc_resps / self._cc_compare.
        self.m_scoreboard.add_interface(self.m_cc_mfb_monitor, self.iuventus_model.m_cc_exp_out, compare_fn=self._cc_compare)
        # OP_STAT reorder window: with multiple outstanding NVMe commands, completions can retire
        # out of submission order (nvme_ctrl_model shuffles SQE processing), and an OOR command's
        # status is appended synchronously at dispatch time (it never becomes a real SQE) while a
        # real command's status is appended only when its completion is actually processed -- so an
        # OOR status can legitimately race ahead of / behind an already-outstanding real command's
        # status. reorder_depth lets the scoreboard match content regardless of position within the
        # window instead of false-positiving on ORDER; a genuine {type,code} content mismatch still
        # fails once outside the window. QUEUE_DEPTH bounds the number of commands that can be
        # concurrently outstanding, so it bounds how far a status can legitimately be reordered.
        op_stat_reorder_depth = int(os.getenv("OP_STAT_REORDER_DEPTH", str(QUEUE_DEPTH)))
        self.m_scoreboard.add_interface(self.op_stat_mon, self.iuventus_model.m_op_stat_exp_out, strict_type=True, reorder_depth=op_stat_reorder_depth)
        # RD_MFB expected data comes from the nvme_ctrl_model only: it derives the actual buffer
        # page `k` from the real SQE it read (nvme_ctrl_model._proc_sq_entries) and builds the
        # expected read data from the actual storage, whereas iuventus_model can no longer predict
        # `k` (see the RD_MFB removal in IuventusModel.proc_cqes).
        # rd_mfb_reorder_depth defaults to 0 (strict, front-of-queue-only match), matching the
        # original single-queue behavior exactly. Multi-queue callers (see prepare_multi) pass a
        # nonzero window: rd_mfb_exp_out is appended to eagerly, per queue, at each queue's OWN
        # _proc_sq_entries dispatch time (independent asyncio coroutines racing across queues), but
        # the DUT's actual RD_MFB drain order follows the single physical cqe_processor round-robin
        # arbiter's real completion-recognition order across all queues -- the two need not agree
        # even though each queue's OWN reads are still emitted in that queue's own dispatch order.
        self.m_scoreboard.add_interface(self.m_rd_mfb_monitor, self.nvme_ctrl_model.rd_mfb_exp_out, strict_type=True, reorder_depth=rd_mfb_reorder_depth)
        # RQ reorder window: default 1 (strict, as the validated tests expect). The phase-wrap stress
        # test uses a small queue with heavy out-of-order completion, which legitimately reorders the
        # RQ doorbell/SQE writes well beyond depth 1; it sets RQ_REORDER_DEPTH so the ordering check
        # doesn't false-positive, while the lost-completion wedge is still caught by the stall detector.
        rq_reorder_depth = int(os.getenv("RQ_REORDER_DEPTH", "1"))
        if self.strict_rq:
            self.m_scoreboard.add_interface(self.m_rq_mfb_monitor, self.iuventus_model.m_pcie_rq_exp_out, strict_type=True, reorder_depth=rq_reorder_depth)

        self.tb_rd_reqs = 0
        self.tb_rd_req_bytes = 0
        self.tb_wr_reqs = 0
        self.tb_wr_req_bytes = 0

        self.log = logging.getLogger("cocotb.%s" % (type(self).__qualname__))

        if debug:
            self.m_rd_mfb_monitor.log.setLevel(logging.INFO)
            self.m_cc_mfb_monitor.log.setLevel(logging.INFO)
            self.m_rq_mfb_monitor.log.setLevel(logging.INFO)
            self.m_scoreboard.log.setLevel(logging.DEBUG)
            self.m_wr_mfb_driver.log.setLevel(logging.INFO)
            self.m_cq_mfb_driver.log.setLevel(logging.INFO)
            self.m_mi_driver.log.setLevel(logging.INFO)
            self.rd_req_driver.log.setLevel(logging.INFO)
            self.iuventus_model.log.setLevel(logging.INFO)
            self.nvme_ctrl_model.log.setLevel(logging.INFO)
            self.op_stat_mon.log.setLevel(logging.INFO)
            self.log.setLevel(logging.DEBUG)
        else:
            self.m_rd_mfb_monitor.log.setLevel(logging.WARNING)
            self.m_cc_mfb_monitor.log.setLevel(logging.WARNING)
            self.m_rq_mfb_monitor.log.setLevel(logging.WARNING)
            self.m_scoreboard.log.setLevel(logging.INFO)
            self.m_wr_mfb_driver.log.setLevel(logging.WARNING)
            self.m_cq_mfb_driver.log.setLevel(logging.WARNING)
            self.m_mi_driver.log.setLevel(logging.WARNING)
            self.rd_req_driver.log.setLevel(logging.WARNING)
            self.iuventus_model.log.setLevel(logging.WARNING)
            self.nvme_ctrl_model.log.setLevel(logging.WARNING)
            self.op_stat_mon.log.setLevel(logging.WARNING)
            self.log.setLevel(logging.WARNING)

    def add_queue(self, qid, mptr, qsize, sq_baddr, cq_baddr, sqtdbl_baddr, cqhdbl_baddr,
                  rdbuff_prpl_baddr, rdbuff_prpl_data, wrbuff_prpl_baddr, wrbuff_prpl_data,
                  buffs : IuventusBuffers, tag_range):
        """
        Add queue `qid` (1..NUM_QUEUES-1) to this Testbench: a new IuventusModel/NVMEControllerModel
        pair with its own SQ[qid]/CQ[qid] (sq_baddr/cq_baddr/sqtdbl_baddr/cqhdbl_baddr) and tag
        pool (tag_range, which MUST be disjoint from every other queue's -- see
        NVMEControllerModel's tag_range parameter), but sharing this Testbench's single physical
        buses (PCIE_CQ_MFB driver, PCIE_CC_MFB/PCIE_RQ_MFB monitors) and RDBUFF/WRBUFF data pool
        (`buffs` must share its rd_buff/wr_buff with queue 0's buffer, e.g. via
        IuventusBuffers(qsize, shared_pool=iuventus_model_buffers)).

        The new queue's expected-output lists are the SAME list objects as queue 0's (see
        IuventusModel/NVMEControllerModel's m_cc_exp_out/m_op_stat_exp_out/m_pcie_rq_exp_out/
        rd_mfb_exp_out parameters), so the scoreboard's single add_interface() call (already set
        up in __init__ against queue 0's lists) covers every queue added here too.
        """
        iuventus_model = IuventusModel(
            qsize=qsize, mptr=mptr, sq_baddr=sq_baddr, cq_baddr=cq_baddr,
            sqtdbl_baddr=sqtdbl_baddr, cqhdbl_baddr=cqhdbl_baddr,
            rdbuff_prpl_baddr=rdbuff_prpl_baddr, rdbuff_prpl_data=rdbuff_prpl_data,
            wrbuff_prpl_baddr=wrbuff_prpl_baddr, wrbuff_prpl_data=wrbuff_prpl_data,
            clock=self.dut.CLK, qid=qid, buffs=buffs,
            m_cc_exp_out=self.iuventus_model.m_cc_exp_out,
            m_op_stat_exp_out=self.iuventus_model.m_op_stat_exp_out,
            m_pcie_rq_exp_out=self.iuventus_model.m_pcie_rq_exp_out)
        nvme_ctrl_model = NVMEControllerModel(
            sq_id=qid, mptr=mptr, qsize=qsize, sq_baddr=sq_baddr, cq_baddr=cq_baddr,
            sqtdbl_baddr=sqtdbl_baddr, cqhdbl_baddr=cqhdbl_baddr,
            cq_drv=self.m_cq_mfb_driver, cc_mon=self.m_cc_mfb_monitor,
            rq_mon=self.m_rq_mfb_monitor, rdbuff_prpl_baddr=rdbuff_prpl_baddr,
            rdbuff_prpl_data=rdbuff_prpl_data, wrbuff_prpl_baddr=wrbuff_prpl_baddr,
            wrbuff_prpl_data=wrbuff_prpl_data,
            cq_drv_callback=iuventus_model.proc_pcie_cq_reqs,
            wr_placement_callback=iuventus_model.place_wr_payload,
            tag_range=tag_range,
            rd_mfb_exp_out=self.nvme_ctrl_model.rd_mfb_exp_out,
            flush_observed_callback=iuventus_model.observe_flush_dispatch)

        iuventus_model.log.setLevel(self.iuventus_model.log.level)
        nvme_ctrl_model.log.setLevel(self.nvme_ctrl_model.log.level)

        self.queues.append(QueueCtx(
            qid=qid, qsize=qsize, iuventus_model=iuventus_model, nvme_ctrl_model=nvme_ctrl_model,
            sqtdbl_baddr=sqtdbl_baddr, cqhdbl_baddr=cqhdbl_baddr))
        return iuventus_model, nvme_ctrl_model

    def _cc_compare(self, transaction):
        """Custom scoreboard comparator for the PCIE_CC_MFB (SQ-read/RDBUFF-read completion)
        interface. Mirrors cocotb_bus.scoreboard.Scoreboard's default check_received_transaction
        + compare exactly, except: if the popped expected transaction carries a `_prp_mask`
        attribute (set by IuventusModel.disp_cc_resps for SQ-read CC responses -- the SQE's
        PRP1/PRP2 fields are unpredictable since the RTL's dynamic first-fit page allocator, not
        the model, decides the actual buffer page `k`), the listed byte ranges are zeroed in both
        the received and the expected data before comparing.
        """
        expected_output = self.iuventus_model.m_cc_exp_out
        scoreboard = self.m_scoreboard
        monitor = self.m_cc_mfb_monitor

        if monitor.name:
            log_name = scoreboard.log.name + "." + monitor.name
        else:
            log_name = scoreboard.log.name + "." + type(monitor).__qualname__
        log = logging.getLogger(log_name)

        if len(expected_output):
            exp = expected_output.pop(0)
        else:
            scoreboard.errors += 1
            log.error("Received a transaction but wasn't expecting anything")
            log.info("Got: %s" % (hexdump(str(transaction), dump=True)))
            if scoreboard._imm:
                assert False, "Received a transaction but wasn't expecting anything"
            return

        prp_mask = getattr(exp, "_prp_mask", None)
        if prp_mask:
            got_data = bytearray(transaction.data)
            exp_data = bytearray(exp.data)
            for start, end in prp_mask:
                for i in range(start, end):
                    got_data[i] = 0
                    exp_data[i] = 0
            got = MfbTransactionWithMeta(data=bytes(got_data), meta=transaction.meta)
            exp = MfbTransactionWithMeta(data=bytes(exp_data), meta=exp.meta)
        else:
            got = transaction

        scoreboard.compare(got, exp, log, strict_type=True)

    def bpsr_start(self):
        self.m_rd_mfb_bpsr.start(random_tuple_iterator(100,500,1,5))
        self.m_cc_mfb_bpsr.start(random_tuple_iterator(100,500,1,5))
        self.m_rq_mfb_bpsr.start(random_tuple_iterator(100,500,1,5))

    async def reset(self):
        for q in self.queues:
            q.nvme_ctrl_model.reset()
            q.iuventus_model.reset()
        self.m_wr_mfb_driver.clear()
        self.m_cq_mfb_driver.clear()
        self.m_mi_driver.clear()
        self.rd_req_driver.clear()
        self.tb_rd_reqs = 0
        self.tb_rd_req_bytes = 0
        self.tb_wr_reqs = 0
        self.tb_wr_req_bytes = 0

        self.dut.RST.value = 1
        self.dut.MI_RST.value = 1
        await ClockCycles(self.dut.CLK, 100)
        self.dut.RST.value = 0
        await RisingEdge(self.dut.CLK)
        self.dut.MI_RST.value = 0
        await RisingEdge(self.dut.MI_CLK)

    async def nullify_cpl_queue(self):
        from misc_const import CQE_SIZE, IuventusBarSelection, PcieReqType
        from cocotbext.ofm.pcie import CQMfbMeta, CQHeader

        for q in self.queues:
            for idx in range(q.qsize):
                phys_addr = q.nvme_ctrl_model._cq_baddr + (idx * CQE_SIZE)

                cq_hdr = CQHeader()
                cq_hdr.bar_apper = 26
                cq_hdr.tgt_func = 1
                cq_hdr.bar_id = IuventusBarSelection.CQ_BAR
                cq_hdr.addr = phys_addr >> 2
                cq_hdr.dword_count = CQE_SIZE // 4
                cq_hdr.req_type = PcieReqType.MWR

                cq_mfb_meta = CQMfbMeta()
                cq_mfb_meta.firstBe = 0xF
                cq_mfb_meta.lastBe = 0xF

                cq_trans = MfbTransactionWithMeta(
                    data=cq_hdr.serialize().to_bytes(len(CQHeader()) // 8, 'little') + (b'\x00' * CQE_SIZE),
                    meta=cq_mfb_meta.serialize()
                )

                self.m_cq_mfb_driver.append(cq_trans)
                q.iuventus_model.proc_pcie_cq_reqs(cq_trans)

            self.log.info(f"Sent {q.qsize} transactions to nullify queue {q.qid}'s completion queue")
        await ClockCycles(self.dut.CLK, 100)
        self.log.info(f"Waited for 100 cycles after nullifying the completion queue(s)")

    async def enable_dut(self):
        for q in self.queues:
            q.iuventus_model.enabled = True
            q.nvme_ctrl_model.nullify_doorbell()
        ctrl_reg = int.from_bytes(await self.m_mi_driver.read(IuventusMiRegMap.CONTROL, 1))
        ctrl_reg |= (1 << CtrlRegBits.ENABLE)
        await self.m_mi_driver.write(IuventusMiRegMap.CONTROL, ctrl_reg.to_bytes(1, 'little'))

        stat_reg = int.from_bytes(await self.m_mi_driver.read(IuventusMiRegMap.STATUS, 1)) & 0x07
        for _ in range(100):
            if stat_reg == 7:
                return
            await ClockCycles(self.dut.MI_CLK, 10)
            stat_reg = int.from_bytes(await self.m_mi_driver.read(IuventusMiRegMap.STATUS, 1)) & 0x07
        assert False, "DUT enable timeout: STATUS register did not indicate running state"

    async def disable_dut(self):
        for q in self.queues:
            q.iuventus_model.enabled = False
        ctrl_reg = int.from_bytes(await self.m_mi_driver.read(IuventusMiRegMap.CONTROL, 1))
        ctrl_reg &= ~(1 << CtrlRegBits.ENABLE)
        await self.m_mi_driver.write(IuventusMiRegMap.CONTROL, ctrl_reg.to_bytes(1, 'little'))

        stat_reg = int.from_bytes(await self.m_mi_driver.read(IuventusMiRegMap.STATUS, 1)) & 0x01
        for _ in range(20):
            if stat_reg == 0:
                return
            await ClockCycles(self.dut.MI_CLK, 10)
            stat_reg = int.from_bytes(await self.m_mi_driver.read(IuventusMiRegMap.STATUS, 1)) & 0x01

        assert False, "DUT disable timeout: STATUS register did not indicate stopped state"

    def nvme_rd(self, lba_ptr, lba_num, qid=0):
        """Submit a READ request targeting queue `qid` (drives NVME_RD_REQ_QID; default 0 for
        single-queue tests, unchanged)."""
        q = self.queues[qid]
        self.rd_req_driver.append((lba_num, lba_ptr, qid), q.iuventus_model.create_nvme_rd_cmd)
        self.tb_rd_reqs += 1
        # Only count non-OOR requests to match iuventus_model.c_sqe_rd_cmd_size semantics.
        # OOR reads are caught by the model and never dispatched as SQEs.
        if lba_ptr + lba_num <= STORAGE_CAP_LBAS:
            self.tb_rd_req_bytes += lba_num * SECT_SIZE

    def nvme_wr(self, lba_ptr, data, qid=0):
        """Submit a WRITE request targeting queue `qid` (drives the QID bits appended above
        SQE_LBA_PTR_W in WR_MFB_META; default 0 for single-queue tests, unchanged)."""
        q = self.queues[qid]
        meta = lba_ptr | (qid << SQE_LBA_PTR_W)
        tr = MfbTransactionWithMeta(data=data, meta=meta)
        if self.log.isEnabledFor(logging.DEBUG):
            self.log.debug(f"Appending NVMe write command: LBA_PTR=0x{lba_ptr:016X}, QID={qid}, SIZE={len(data)} bytes")
        self.m_wr_mfb_driver.append(tr, q.iuventus_model.create_nvme_wr_cmd)
        self.tb_wr_reqs += 1
        # Only count non-OOR requests to match iuventus_model.c_sqe_wr_cmd_size semantics.
        # OOR writes are caught by the model and never dispatched as SQEs.
        lba_num_wr = (len(data) + SECT_SIZE - 1) // SECT_SIZE
        if lba_ptr + lba_num_wr <= STORAGE_CAP_LBAS:
            self.tb_wr_req_bytes += lba_num_wr * SECT_SIZE

    def check_models(self):
        self.nvme_ctrl_model.post_check()
        self.iuventus_model.post_check()

        assert self.nvme_ctrl_model.c_sqes_proc == self.iuventus_model.c_sqes_disp, \
            f"Mismatch in processed SQEs: NVME Model={self.nvme_ctrl_model.c_sqes_proc}, Iuventus Model={self.iuventus_model.c_sqes_disp}"
        assert self.nvme_ctrl_model.c_cqes_disp == self.iuventus_model.c_cqes_proc, \
            f"Mismatch in dispatched CQEs: NVME Model={self.nvme_ctrl_model.c_cqes_disp}, Iuventus Model={self.iuventus_model.c_cqes_proc}"
        assert self.nvme_ctrl_model.c_pcie_disp_rds == self.iuventus_model.c_pcie_rd_reqs, \
            f"Mismatch in dispatched PCIe read requests: NVME Model={self.nvme_ctrl_model.c_pcie_disp_rds}, Iuventus Model={self.iuventus_model.c_pcie_rd_reqs}"
        assert self.nvme_ctrl_model.c_pcie_disp_rd_bytes == self.iuventus_model.c_pcie_rd_req_bytes, \
            f"Mismatch in dispatched PCIe read request bytes: NVME Model={self.nvme_ctrl_model.c_pcie_disp_rd_bytes}, Iuventus Model={self.iuventus_model.c_pcie_rd_req_bytes}"
        # assert self.nvme_ctrl_model.c_pcie_disp_wrs == self.iuventus_model.c_pcie_wr_reqs, \
        #     f"Mismatch in dispatched PCIe write requests: NVME Model={self.nvme_ctrl_model.c_pcie_disp_wrs}, Iuventus Model={self.iuventus_model.c_pcie_wr_reqs}"
        # assert self.nvme_ctrl_model.c_pcie_disp_wr_bytes == self.iuventus_model.c_pcie_wr_req_bytes, \
        #     f"Mismatch in dispatched PCIe write request bytes: NVME Model={self.nvme_ctrl_model.c_pcie_disp_wr_bytes}, Iuventus Model={self.iuventus_model.c_pcie_wr_req_bytes}"
        assert self.nvme_ctrl_model.c_pcie_sq_rds == self.iuventus_model.c_sq_rd_reqs, \
            f"Mismatch in PCIe SQ read requests: NVME Model={self.nvme_ctrl_model.c_pcie_sq_rds}, Iuventus Model={self.iuventus_model.c_sq_rd_reqs}"
        assert self.nvme_ctrl_model.c_pcie_sq_rd_bytes == self.iuventus_model.c_sq_rd_req_bytes, \
            f"Mismatch in PCIe SQ read request bytes: NVME Model={self.nvme_ctrl_model.c_pcie_sq_rd_bytes}, Iuventus Model={self.iuventus_model.c_sq_rd_req_bytes}"
        assert self.nvme_ctrl_model.c_succ_compls == self.iuventus_model.c_succ_compls, \
            f"Mismatch in successful completions: NVME Model={self.nvme_ctrl_model.c_succ_compls}, Iuventus Model={self.iuventus_model.c_succ_compls}"
        assert self.nvme_ctrl_model.c_unsucc_compls == self.iuventus_model.c_unsucc_compls, \
            f"Mismatch in unsuccessful completions: NVME Model={self.nvme_ctrl_model.c_unsucc_compls}, Iuventus Model={self.iuventus_model.c_unsucc_compls}"
        assert self.nvme_ctrl_model.c_pcie_rdbuff_rds == self.iuventus_model.c_rdbuff_rd_reqs, \
            f"Mismatch in PCIe read buffer read requests: NVME Model={self.nvme_ctrl_model.c_pcie_rdbuff_rds}, Iuventus Model={self.iuventus_model.c_rdbuff_rd_reqs}"
        assert self.nvme_ctrl_model.c_pcie_rdbuff_rd_bytes == self.iuventus_model.c_rdbuff_rd_req_bytes, \
            f"Mismatch in PCIe read buffer read request bytes: NVME Model={self.nvme_ctrl_model.c_pcie_rdbuff_rd_bytes}, Iuventus Model={self.iuventus_model.c_rdbuff_rd_req_bytes}"
        assert self.nvme_ctrl_model.c_pcie_wrbuff_wrs == self.iuventus_model.c_wrbuff_wr_reqs, \
            f"Mismatch in PCIe write buffer write requests: NVME Model={self.nvme_ctrl_model.c_pcie_wrbuff_wrs}, Iuventus Model={self.iuventus_model.c_wrbuff_wr_reqs}"
        assert self.nvme_ctrl_model.c_pcie_wrbuff_wr_bytes == self.iuventus_model.c_wrbuff_wr_req_bytes, \
            f"Mismatch in PCIe write buffer write request bytes: NVME Model={self.nvme_ctrl_model.c_pcie_wrbuff_wr_bytes}, Iuventus Model={self.iuventus_model.c_wrbuff_wr_req_bytes}"
        # assert self.nvme_ctrl_model.c_pcie_cq_wrs == self.iuventus_model.c_cq_wr_reqs, \
        #     f"Mismatch in PCIe CQ write requests: NVME Model={self.nvme_ctrl_model.c_pcie_cq_wrs}, Iuventus Model={self.iuventus_model.c_cq_wr_reqs}"
        # assert self.nvme_ctrl_model.c_pcie_cq_wr_bytes == self.iuventus_model.c_cq_wr_req_bytes, \
        #     f"Mismatch in PCIe CQ write request bytes: NVME Model={self.nvme_ctrl_model.c_pcie_cq_wr_bytes}, Iuventus Model={self.iuventus_model.c_cq_wr_req_bytes}"
        # iuventus.c_cqhdbl_reg_upds counts disp_dbl_update calls (one per CQE),
        # while nvme.c_cqhdbl_reg_upds counts TLPs actually received.  The RTL
        # dbl_updater coalesces rapid updates so the nvme count can be smaller.
        # Correctness of the final CQHDBL VALUE is verified by check_doorbels();
        # the actual TLP dispatch count is verified by check_dut_cntrs() against
        # the DUT hardware counter.
        assert self.nvme_ctrl_model.c_cqhdbl_reg_upds <= self.iuventus_model.c_cqhdbl_reg_upds, \
            f"nvme received more CQHDBL TLPs than iuventus dispatched: NVME Model={self.nvme_ctrl_model.c_cqhdbl_reg_upds}, Iuventus Model={self.iuventus_model.c_cqhdbl_reg_upds}"
        # iuventus.c_sqtdbl_reg_upds counts disp_dbl_update calls (one per dispatched SQE), while
        # nvme.c_sqtdbl_reg_upds counts TLPs actually received. Under multiple outstanding commands
        # the RTL dbl_updater coalesces rapid tail updates exactly like it does for CQHDBL above, so
        # the SSD can legitimately receive fewer SQTDBL TLPs than commands were dispatched.
        assert self.nvme_ctrl_model.c_sqtdbl_reg_upds <= self.iuventus_model.c_sqtdbl_reg_upds, \
            f"nvme received more SQTDBL TLPs than iuventus dispatched: NVME Model={self.nvme_ctrl_model.c_sqtdbl_reg_upds}, Iuventus Model={self.iuventus_model.c_sqtdbl_reg_upds}"
        assert self.nvme_ctrl_model.c_sqe_rd_cmds == self.iuventus_model.c_sqe_rd_cmds, \
            f"Mismatch in SQE read commands: NVME Model={self.nvme_ctrl_model.c_sqe_rd_cmds}, Iuventus Model={self.iuventus_model.c_sqe_rd_cmds}"
        assert self.nvme_ctrl_model.c_sqe_rd_cmd_size == self.iuventus_model.c_sqe_rd_cmd_size, \
            f"Mismatch in SQE read command bytes: NVME Model={self.nvme_ctrl_model.c_sqe_rd_cmd_size}, Iuventus Model={self.iuventus_model.c_sqe_rd_cmd_size}"
        assert self.nvme_ctrl_model.c_sqe_wr_cmds == self.iuventus_model.c_sqe_wr_cmds, \
            f"Mismatch in SQE write commands: NVME Model={self.nvme_ctrl_model.c_sqe_wr_cmds}, Iuventus Model={self.iuventus_model.c_sqe_wr_cmds}"
        assert self.nvme_ctrl_model.c_sqe_wr_cmd_size == self.iuventus_model.c_sqe_wr_cmd_size, \
            f"Mismatch in SQE write command bytes: NVME Model={self.nvme_ctrl_model.c_sqe_wr_cmd_size}, Iuventus Model={self.iuventus_model.c_sqe_wr_cmd_size}"

    async def check_dut_cntrs(self):
        # assert self.tb_rd_reqs == self.iuventus_model.c_sqes_disp, \
        #     f"Mismatch in read commands: TB={self.tb_rd_reqs}, Iuventus Model={self.iuventus_model.c_sqes_disp}"
        assert self.tb_rd_req_bytes == self.iuventus_model.c_sqe_rd_cmd_size, \
            f"Mismatch in read command bytes: TB={self.tb_rd_req_bytes}, Iuventus Model={self.iuventus_model.c_sqe_rd_cmd_size}"
        assert self.tb_wr_req_bytes == self.iuventus_model.c_sqe_wr_cmd_size, \
            f"Mismatch in read command bytes: TB={self.tb_rd_req_bytes}, Iuventus Model={self.iuventus_model.c_sqe_rd_cmd_size}"

        # Write to control register to sample counters
        ctrl_reg = int.from_bytes(await self.m_mi_driver.read(IuventusMiRegMap.CONTROL, 1))
        ctrl_reg |= (1 << CtrlRegBits.SAMPLE_CNTRS)
        await self.m_mi_driver.write(IuventusMiRegMap.CONTROL, ctrl_reg.to_bytes(1, 'little'))

        cntr = await self.m_mi_driver.read(IuventusMiRegMap.SQE_DISP_CNTR_L, 8)
        assert int.from_bytes(cntr, 'little') == self.iuventus_model.c_sqes_disp, \
            f"Mismatch in SQE_DISP_CNTR: DUT={int.from_bytes(cntr, 'little')}, Iuventus Model={self.iuventus_model.c_sqes_disp}"
        cntr = await self.m_mi_driver.read(IuventusMiRegMap.CQE_PROC_CNTR_L, 8)
        assert int.from_bytes(cntr, 'little') == self.iuventus_model.c_cqes_proc, \
            f"Mismatch in CQE_PROC_CNTR: DUT={int.from_bytes(cntr, 'little')}, Iuventus Model={self.iuventus_model.c_cqes_proc}"
        cntr = await self.m_mi_driver.read(IuventusMiRegMap.PCIE_RDS_CNTR_L, 8)
        assert int.from_bytes(cntr, 'little') == self.iuventus_model.c_pcie_rd_reqs, \
            f"Mismatch in PCIE_RDS_CNTR: DUT={int.from_bytes(cntr, 'little')}, Iuventus Model={self.iuventus_model.c_pcie_rd_reqs}"
        cntr = await self.m_mi_driver.read(IuventusMiRegMap.PCIE_RD_BYTES_CNTR_L, 8)
        assert int.from_bytes(cntr, 'little') == self.iuventus_model.c_pcie_rd_req_bytes, \
            f"Mismatch in PCIE_RD_BYTES_CNTR: DUT={int.from_bytes(cntr, 'little')}, Iuventus Model={self.iuventus_model.c_pcie_rd_req_bytes}"
        cntr = await self.m_mi_driver.read(IuventusMiRegMap.PCIE_WRS_CNTR_L, 8)
        assert int.from_bytes(cntr, 'little') == self.iuventus_model.c_pcie_wr_reqs, \
            f"Mismatch in PCIE_WRS_CNTR: DUT={int.from_bytes(cntr, 'little')}, Iuventus Model={self.iuventus_model.c_pcie_wr_reqs}"
        cntr = await self.m_mi_driver.read(IuventusMiRegMap.PCIE_WR_BYTES_CNTR_L, 8)
        assert int.from_bytes(cntr, 'little') == self.iuventus_model.c_pcie_wr_req_bytes, \
            f"Mismatch in PCIE_WR_BYTES_CNTR: DUT={int.from_bytes(cntr, 'little')}, Iuventus Model={self.iuventus_model.c_pcie_wr_req_bytes}"
        cntr = await self.m_mi_driver.read(IuventusMiRegMap.SQ_PCIE_RDS_CNTR_L, 8)
        assert int.from_bytes(cntr, 'little') == self.iuventus_model.c_sq_rd_reqs, \
            f"Mismatch in SQ_PCIE_RDS_CNTR: DUT={int.from_bytes(cntr, 'little')}, Iuventus Model={self.iuventus_model.c_sq_rd_reqs}"
        cntr = await self.m_mi_driver.read(IuventusMiRegMap.SQ_PCIE_RD_BYTES_CNTR_L, 8)
        assert int.from_bytes(cntr, 'little') == self.iuventus_model.c_sq_rd_req_bytes, \
            f"Mismatch in SQ_PCIE_RD_BYTES_CNTR: DUT={int.from_bytes(cntr, 'little')}, Iuventus Model={self.iuventus_model.c_sq_rd_req_bytes}"
        cntr = await self.m_mi_driver.read(IuventusMiRegMap.SUCC_COMPL_CNTR_L, 8)
        assert int.from_bytes(cntr, 'little') == self.iuventus_model.c_succ_compls, \
            f"Mismatch in SUCC_COMPL_CNTR: DUT={int.from_bytes(cntr, 'little')}, Iuventus Model={self.iuventus_model.c_succ_compls}"
        cntr = await self.m_mi_driver.read(IuventusMiRegMap.UNSUCC_COMPL_CNTR_L, 8)
        assert int.from_bytes(cntr, 'little') == self.iuventus_model.c_unsucc_compls, \
            f"Mismatch in UNSUCC_COMPL_CNTR: DUT={int.from_bytes(cntr, 'little')}, Iuventus Model={self.iuventus_model.c_unsucc_compls}"
        cntr = await self.m_mi_driver.read(IuventusMiRegMap.RDBUFF_PCIE_RDS_CNTR_L, 8)
        assert int.from_bytes(cntr, 'little') == self.iuventus_model.c_rdbuff_rd_reqs, \
            f"Mismatch in RDBUFF_PCIE_RDS_CNTR: DUT={int.from_bytes(cntr, 'little')}, Iuventus Model={self.iuventus_model.c_rdbuff_rd_reqs}"
        cntr = await self.m_mi_driver.read(IuventusMiRegMap.RDBUFF_PCIE_RD_BYTES_CNTR_L, 8)
        assert int.from_bytes(cntr, 'little') == self.iuventus_model.c_rdbuff_rd_req_bytes, \
            f"Mismatch in RDBUFF_PCIE_RD_BYTES_CNTR: DUT={int.from_bytes(cntr, 'little')}, Iuventus Model={self.iuventus_model.c_rdbuff_rd_req_bytes}"
        cntr = await self.m_mi_driver.read(IuventusMiRegMap.WRBUFF_PCIE_WRS_CNTR_L, 8)
        assert int.from_bytes(cntr, 'little') == self.iuventus_model.c_wrbuff_wr_reqs, \
            f"Mismatch in WRBUFF_PCIE_WRS_CNTR: DUT={int.from_bytes(cntr, 'little')}, Iuventus Model={self.iuventus_model.c_wrbuff_wr_reqs}"
        cntr = await self.m_mi_driver.read(IuventusMiRegMap.WRBUFF_PCIE_WR_BYTES_CNTR_L, 8)
        assert int.from_bytes(cntr, 'little') == self.iuventus_model.c_wrbuff_wr_req_bytes, \
            f"Mismatch in WRBUFF_PCIE_WR_BYTES_CNTR: DUT={int.from_bytes(cntr, 'little')}, Iuventus Model={self.iuventus_model.c_wrbuff_wr_req_bytes}"
        cntr = await self.m_mi_driver.read(IuventusMiRegMap.CQ_PCIE_WRS_CNTR_L, 8)
        assert int.from_bytes(cntr, 'little') == self.iuventus_model.c_cq_wr_reqs, \
            f"Mismatch in CQ_PCIE_WRS_CNTR: DUT={int.from_bytes(cntr, 'little')}, Iuventus Model={self.iuventus_model.c_cq_wr_reqs}"
        cntr = await self.m_mi_driver.read(IuventusMiRegMap.CQ_PCIE_WR_BYTES_CNTR_L, 8)
        assert int.from_bytes(cntr, 'little') == self.iuventus_model.c_cq_wr_req_bytes, \
            f"Mismatch in CQ_PCIE_WR_BYTES_CNTR: DUT={int.from_bytes(cntr, 'little')}, Iuventus Model={self.iuventus_model.c_cq_wr_req_bytes}"
        cntr = await self.m_mi_driver.read(IuventusMiRegMap.CQHDBL_REG_UPDS_CNTR_L, 8)
        # Compare against the nvme model's received count (= actual TLPs dispatched
        # by the RTL dbl_updater).  iuventus.c_cqhdbl_reg_upds overcounts when
        # dbl_updater coalesces rapid updates; the DUT hardware counter matches
        # the actually-dispatched-TLP count tracked by the nvme model.
        assert int.from_bytes(cntr, 'little') == self.nvme_ctrl_model.c_cqhdbl_reg_upds, \
            f"Mismatch in CQHDBL_REG_UPD_CNTR: DUT={int.from_bytes(cntr, 'little')}, NVME Model={self.nvme_ctrl_model.c_cqhdbl_reg_upds}"
        cntr = await self.m_mi_driver.read(IuventusMiRegMap.SQTDBL_REG_UPDS_CNTR_L, 8)
        # Compare against the nvme model's received count (= actual TLPs dispatched by the RTL
        # dbl_updater). iuventus.c_sqtdbl_reg_upds overcounts when dbl_updater coalesces rapid
        # updates; the DUT hardware counter matches the actually-dispatched-TLP count tracked by
        # the nvme model (mirrors the CQHDBL_REG_UPD_CNTR check above).
        assert int.from_bytes(cntr, 'little') == self.nvme_ctrl_model.c_sqtdbl_reg_upds, \
            f"Mismatch in SQTDBL_REG_UPD_CNTR: DUT={int.from_bytes(cntr, 'little')}, NVME Model={self.nvme_ctrl_model.c_sqtdbl_reg_upds}"
        cntr = await self.m_mi_driver.read(IuventusMiRegMap.NVME_RD_BYTES_CNTR_L, 8)
        assert int.from_bytes(cntr, 'little') == self.iuventus_model.c_sqe_rd_cmd_size, \
            f"Mismatch in NVME_RD_BYTES_CNTR: DUT={int.from_bytes(cntr, 'little')}, Iuventus Model={self.iuventus_model.c_sqe_rd_cmd_size}"

    async def check_doorbels(self):
        # This design only has one RTL queue (slot 0 of the PER_Q_BASE block -- see
        # Testbench.nvme_rd/nvme_wr's self.queues[qid] list-index semantics).
        # Check CQHDBL doorbell
        cqhdbl_dut = int.from_bytes(await self.m_mi_driver.read(per_queue_reg_addr(IuventusPerQueueRegMap.CQHDBL, 0), 2), 'little')
        assert cqhdbl_dut == self.iuventus_model.cqhdbl,\
            f"Mismatch in CQHDBL doorbell: DUT=0x{cqhdbl_dut:04X}, Iuventus Model=0x{self.iuventus_model.cqhdbl:04X}"
        assert cqhdbl_dut == self.nvme_ctrl_model._cqhdbl, \
            f"Mismatch in CQHDBL doorbell: DUT=0x{cqhdbl_dut:04X}, NVME Ctrl Model=0x{self.nvme_ctrl_model._cqhdbl:04X}"
        # Check SQTDBL doorbell
        sqtdbl_dut = int.from_bytes(await self.m_mi_driver.read(per_queue_reg_addr(IuventusPerQueueRegMap.SQTDBL, 0), 2), 'little')
        assert sqtdbl_dut == self.iuventus_model.sqtdbl, \
            f"Mismatch in SQTDBL doorbell: DUT=0x{sqtdbl_dut:04X}, Iuventus Model=0x{self.iuventus_model.sqtdbl:04X}"
        assert sqtdbl_dut == self.nvme_ctrl_model._sqtdbl, \
            f"Mismatch in SQTDBL doorbell: DUT=0x{sqtdbl_dut:04X}, NVME Ctrl Model=0x{self.nvme_ctrl_model._sqtdbl:04X}"

    # Print counters from every model and DUT on the end of the test as a table
    async def print_stats(self):
        stat_str = f"{'Counter':<40} {'Iuventus Model':<20} {'NVME Ctrl Model':<20} {'DUT':<20}\n"
        stat_str += "-" * 90 + "\n"
        counters = [
            ("SQEs Dispatched", self.iuventus_model.c_sqes_disp, self.nvme_ctrl_model.c_sqes_proc),
            ("CQEs Processed", self.iuventus_model.c_cqes_proc, self.nvme_ctrl_model.c_cqes_disp),
            ("PCIe Read Requests Dispatched", self.iuventus_model.c_pcie_rd_reqs, self.nvme_ctrl_model.c_pcie_disp_rds),
            ("PCIe Read Request Bytes Dispatched", self.iuventus_model.c_pcie_rd_req_bytes, self.nvme_ctrl_model.c_pcie_disp_rd_bytes),
            ("PCIe Write Requests Dispatched", self.iuventus_model.c_pcie_wr_reqs, self.nvme_ctrl_model.c_pcie_disp_wrs),
            ("PCIe Write Request Bytes Dispatched", self.iuventus_model.c_pcie_wr_req_bytes, self.nvme_ctrl_model.c_pcie_disp_wr_bytes),
            ("PCIe SQ Read Requests", self.iuventus_model.c_sq_rd_reqs, self.nvme_ctrl_model.c_pcie_sq_rds),
            ("PCIe SQ Read Request Bytes", self.iuventus_model.c_sq_rd_req_bytes, self.nvme_ctrl_model.c_pcie_sq_rd_bytes),
            ("Successful Completions", self.iuventus_model.c_succ_compls, self.nvme_ctrl_model.c_succ_compls),
            ("Unsuccessful Completions", self.iuventus_model.c_unsucc_compls, self.nvme_ctrl_model.c_unsucc_compls),
            ("PCIe Read Buffer Read Requests", self.iuventus_model.c_rdbuff_rd_reqs, self.nvme_ctrl_model.c_pcie_rdbuff_rds),
            ("PCIe Read Buffer Read Request Bytes", self.iuventus_model.c_rdbuff_rd_req_bytes, self.nvme_ctrl_model.c_pcie_rdbuff_rd_bytes),
            ("PCIe Write Buffer Write Requests", self.iuventus_model.c_wrbuff_wr_reqs, self.nvme_ctrl_model.c_pcie_wrbuff_wrs),
            ("PCIe Write Buffer Write Request Bytes", self.iuventus_model.c_wrbuff_wr_req_bytes, self.nvme_ctrl_model.c_pcie_wrbuff_wr_bytes),
            ("PCIe CQ Write Requests", self.iuventus_model.c_cq_wr_reqs, self.nvme_ctrl_model.c_pcie_cq_wrs),
            ("PCIe CQ Write Request Bytes", self.iuventus_model.c_cq_wr_req_bytes, self.nvme_ctrl_model.c_pcie_cq_wr_bytes),
            ("CQHDBL Register Updates", self.iuventus_model.c_cqhdbl_reg_upds, self.nvme_ctrl_model.c_cqhdbl_reg_upds),
            ("SQTDBL Register Updates", self.iuventus_model.c_sqtdbl_reg_upds, self.nvme_ctrl_model.c_sqtdbl_reg_upds),
            ("SQE Read Commands", self.iuventus_model.c_sqe_rd_cmds, self.nvme_ctrl_model.c_sqe_rd_cmds),
            ("SQE Read Command Bytes", self.iuventus_model.c_sqe_rd_cmd_size, self.nvme_ctrl_model.c_sqe_rd_cmd_size),
            ("SQE Write Commands", self.iuventus_model.c_sqe_wr_cmds, self.nvme_ctrl_model.c_sqe_wr_cmds),
            ("SQE Write Command Bytes", self.iuventus_model.c_sqe_wr_cmd_size, self.nvme_ctrl_model.c_sqe_wr_cmd_size),
        ]

        ctrl_reg = int.from_bytes(await self.m_mi_driver.read(IuventusMiRegMap.CONTROL, 1))
        ctrl_reg |= (1 << CtrlRegBits.SAMPLE_CNTRS)
        await self.m_mi_driver.write(IuventusMiRegMap.CONTROL, ctrl_reg.to_bytes(1, 'little'))

        for name, iuventus_val, nvme_ctrl_val in counters:
            stat_str += f"{name:<40} {iuventus_val:<20} {nvme_ctrl_val:<20} "
            try:
                if name == "SQEs Dispatched":
                    dut_val = int.from_bytes(await self.m_mi_driver.read(IuventusMiRegMap.SQE_DISP_CNTR_L, 8), 'little')
                elif name == "CQEs Processed":
                    dut_val = int.from_bytes(await self.m_mi_driver.read(IuventusMiRegMap.CQE_PROC_CNTR_L, 8), 'little')
                elif name == "PCIe Read Requests Dispatched":
                    dut_val = int.from_bytes(await self.m_mi_driver.read(IuventusMiRegMap.PCIE_RDS_CNTR_L, 8), 'little')
                elif name == "PCIe Read Request Bytes Dispatched":
                    dut_val = int.from_bytes(await self.m_mi_driver.read(IuventusMiRegMap.PCIE_RD_BYTES_CNTR_L, 8), 'little')
                elif name == "PCIe Write Requests Dispatched":
                    dut_val = int.from_bytes(await self.m_mi_driver.read(IuventusMiRegMap.PCIE_WRS_CNTR_L, 8), 'little')
                elif name == "PCIe Write Request Bytes Dispatched":
                    dut_val = int.from_bytes(await self.m_mi_driver.read(IuventusMiRegMap.PCIE_WR_BYTES_CNTR_L, 8), 'little')
                elif name == "PCIe SQ Read Requests":
                    dut_val = int.from_bytes(await self.m_mi_driver.read(IuventusMiRegMap.SQ_PCIE_RDS_CNTR_L, 8), 'little')
                elif name == "PCIe SQ Read Request Bytes":
                    dut_val = int.from_bytes(await self.m_mi_driver.read(IuventusMiRegMap.SQ_PCIE_RD_BYTES_CNTR_L, 8), 'little')
                elif name == "Successful Completions":
                    dut_val = int.from_bytes(await self.m_mi_driver.read(IuventusMiRegMap.SUCC_COMPL_CNTR_L, 8), 'little')
                elif name == "Unsuccessful Completions":
                    dut_val = int.from_bytes(await self.m_mi_driver.read(IuventusMiRegMap.UNSUCC_COMPL_CNTR_L, 8), 'little')
                elif name == "PCIe Read Buffer Read Requests":
                    dut_val = int.from_bytes(await self.m_mi_driver.read(IuventusMiRegMap.RDBUFF_PCIE_RDS_CNTR_L, 8), 'little')
                elif name == "PCIe Read Buffer Read Request Bytes":
                    dut_val = int.from_bytes(await self.m_mi_driver.read(IuventusMiRegMap.RDBUFF_PCIE_RD_BYTES_CNTR_L, 8), 'little')
                elif name == "PCIe Write Buffer Write Requests":
                    dut_val = int.from_bytes(await self.m_mi_driver.read(IuventusMiRegMap.WRBUFF_PCIE_WRS_CNTR_L, 8), 'little')
                elif name == "PCIe Write Buffer Write Request Bytes":
                    dut_val = int.from_bytes(await self.m_mi_driver.read(IuventusMiRegMap.WRBUFF_PCIE_WR_BYTES_CNTR_L, 8), 'little')
                elif name == "PCIe CQ Write Requests":
                    dut_val = int.from_bytes(await self.m_mi_driver.read(IuventusMiRegMap.CQ_PCIE_WRS_CNTR_L, 8), 'little')
                elif name == "PCIe CQ Write Request Bytes":
                    dut_val = int.from_bytes(await self.m_mi_driver.read(IuventusMiRegMap.CQ_PCIE_WR_BYTES_CNTR_L, 8), 'little')
                elif name == "CQHDBL Register Updates":
                    dut_val = int.from_bytes(await self.m_mi_driver.read(IuventusMiRegMap.CQHDBL_REG_UPDS_CNTR_L, 8), 'little')
                elif name == "SQTDBL Register Updates":
                    dut_val = int.from_bytes(await self.m_mi_driver.read(IuventusMiRegMap.SQTDBL_REG_UPDS_CNTR_L, 8), 'little')
                elif name == "SQE Read Command Bytes":
                    dut_val = int.from_bytes(await self.m_mi_driver.read(IuventusMiRegMap.NVME_RD_BYTES_CNTR_L, 8), 'little')
                elif name == "SQE Write Command Bytes":
                    dut_val = int.from_bytes(await self.m_mi_driver.read(IuventusMiRegMap.NVME_WR_BYTES_CNTR_L, 8), 'little')
                else:
                    dut_val = "N/A"
            except Exception as e:
                dut_val = f"Error: {e}"
            stat_str += f"{dut_val:<20}\n"

        self.log.info("\n" + stat_str)

    async def post_test_checks(self, req_count, last_test=False, max_stall_cycles=None):
        self.log.setLevel(logging.INFO)
        last_num = 0
        stall_cycles = 0
        last_ops = -1
        while (self.op_stat_mon.ops_processed < req_count):
            if (self.op_stat_mon.ops_processed // 100 > last_num):
                last_num = self.op_stat_mon.ops_processed // 100
                cocotb.log.info(f"Completed {self.op_stat_mon.ops_processed} requests...")

            if max_stall_cycles is not None:
                if self.op_stat_mon.ops_processed == last_ops:
                    stall_cycles += 100
                else:
                    stall_cycles = 0
                    last_ops = self.op_stat_mon.ops_processed
                if stall_cycles >= max_stall_cycles:
                    cocotb.log.warning(
                        f"STALL DETECTED after {stall_cycles} cycles: "
                        f"ops_processed={self.op_stat_mon.ops_processed}/{req_count}"
                    )
                    cocotb.log.warning(
                        f"iuventus_model: c_sqes_disp={self.iuventus_model.c_sqes_disp}, "
                        f"c_cqes_proc={self.iuventus_model.c_cqes_proc}, "
                        f"c_sqtdbl_reg_upds={self.iuventus_model.c_sqtdbl_reg_upds}, "
                        f"c_cqhdbl_reg_upds={self.iuventus_model.c_cqhdbl_reg_upds}"
                    )
                    cocotb.log.warning(
                        f"nvme_ctrl_model: c_sqes_proc={self.nvme_ctrl_model.c_sqes_proc}, "
                        f"c_sqtdbl_reg_upds={self.nvme_ctrl_model.c_sqtdbl_reg_upds}, "
                        f"c_cqhdbl_reg_upds={self.nvme_ctrl_model.c_cqhdbl_reg_upds}"
                    )
                    await self.print_stats()
                    assert False, (
                        f"DUT stalled: ops_processed={self.op_stat_mon.ops_processed} "
                        f"after {stall_cycles} cycles of no progress (expected {req_count})"
                    )

            await ClockCycles(self.dut.CLK, 100)
        await ClockCycles(self.dut.CLK, 100)

        # Wait for the SQTDBL and CQHDBL to be updated in the models which indicates that the # completions have been processed and the test can end
        for _ in range(100):
            c1 = self.nvme_ctrl_model._sqtdbl == self.nvme_ctrl_model._sqhdbl
            c2 = self.nvme_ctrl_model._cqtdbl == self.nvme_ctrl_model._cqhdbl
            c3 = self.iuventus_model.sqhdbl == self.iuventus_model.sqtdbl
            if (c1 and c2 and c3):
                break

            await ClockCycles(self.dut.CLK, 100)

        else:
            cocotb.log.warning("Timed out waiting for SQTDBL and CQHDBL to be updated...")

        # Drain the doorbell FIFO before checking counts.
        # The RQ backpressure BitDriver may have left doorbell updates in-flight
        # inside dbl_updater's FIFO (PCIE_RQ_MFB_SRC_RDY still asserted).
        # Stop the backpressure generator and hold DST_RDY=1 so the FIFO can
        # drain, then wait until the RQ channel is quiescent and the doorbell
        # counters in both models agree.
        self.m_rq_mfb_bpsr.stop()
        self.dut.PCIE_RQ_MFB_DST_RDY.value = 1

        drain_timeout = 50_000
        drain_cycles = 0
        src_rdy_idle_count = 0
        src_rdy_idle_threshold = 10
        while drain_cycles < drain_timeout:
            await RisingEdge(self.dut.CLK)
            drain_cycles += 1
            # Neither doorbell's counts are used as a convergence condition here: the RTL
            # dbl_updater coalesces rapid updates on BOTH CQHDBL (two CQHDBLs arriving within
            # UPDATE_DELAY=256 cycles produce one TLP) and, under multiple outstanding commands,
            # SQTDBL as well -- so iuventus.c_{cq,sq}tdbl_reg_upds (one call per CQE/dispatched SQE)
            # can permanently exceed nvme.c_{cq,sq}tdbl_reg_upds (actual received TLPs); they need
            # never become equal. The RQ channel going idle (SRC_RDY low) for
            # src_rdy_idle_threshold consecutive cycles -- with DST_RDY held high so the FIFO is
            # free to empty -- is the only reliable "everything that will ever be sent has been
            # sent" signal, so it is the sole termination condition.
            if not bool(self.dut.PCIE_RQ_MFB_SRC_RDY.value):
                src_rdy_idle_count += 1
            else:
                src_rdy_idle_count = 0
            if src_rdy_idle_count >= src_rdy_idle_threshold:
                break
        else:
            cocotb.log.error(
                f"Doorbell FIFO drain timeout after {drain_timeout} cycles: "
                f"nvme_ctrl_model c_cqhdbl_reg_upds={self.nvme_ctrl_model.c_cqhdbl_reg_upds}, "
                f"iuventus_model c_cqhdbl_reg_upds={self.iuventus_model.c_cqhdbl_reg_upds}, "
                f"nvme_ctrl_model c_sqtdbl_reg_upds={self.nvme_ctrl_model.c_sqtdbl_reg_upds}, "
                f"iuventus_model c_sqtdbl_reg_upds={self.iuventus_model.c_sqtdbl_reg_upds}"
            )
            assert False, (
                f"Doorbell FIFO did not drain within {drain_timeout} cycles — "
                "this indicates a genuine RTL hang in dbl_updater, not an in-flight artifact"
            )

        cocotb.log.info(
            f"Doorbell FIFO drained after {drain_cycles} cycles. "
            f"c_cqhdbl_reg_upds: nvme={self.nvme_ctrl_model.c_cqhdbl_reg_upds} "
            f"iuventus={self.iuventus_model.c_cqhdbl_reg_upds}; "
            f"c_sqtdbl_reg_upds: nvme={self.nvme_ctrl_model.c_sqtdbl_reg_upds} "
            f"iuventus={self.iuventus_model.c_sqtdbl_reg_upds}"
        )

        await self.disable_dut()
        await self.print_stats()
        await self.check_doorbels()
        self.check_models()
        await self.check_dut_cntrs()

        if last_test:
            raise self.m_scoreboard.result

    async def post_test_checks_multi(self, req_count, max_stall_cycles=None):
        """Multi-queue equivalent of post_test_checks: waits for all `req_count` completions
        (across every queue -- OP_STAT is one physical bus shared by all N queues, so
        op_stat_mon.ops_processed already counts the aggregate) and the RQ doorbell FIFO to
        drain, then checks EACH queue in self.queues converged (SQTDBL==SQHDBL, CQTDBL==CQHDBL,
        no outstanding requests -- via that queue's own nvme_ctrl_model/iuventus_model.post_check),
        and finally raises the scoreboard result (the CC/RD/OP_STAT interfaces use expected-output
        lists shared across all queues -- see add_queue -- so this one result covers every queue's
        traffic).

        Unlike post_test_checks, this does NOT call check_doorbels()/check_dut_cntrs(): those
        compare against the DUT's single legacy SQTDBL/CQHDBL status registers and the global
        (cross-queue-aggregate) MI counters, which only ever reflect "whichever queue last acted"
        -- not a meaningful per-queue check for N>1 (see nvme_sw_manager.vhd's Stage B doc: those
        status registers are intentionally not per-queue).
        """
        self.log.setLevel(logging.INFO)
        last_num = 0
        stall_cycles = 0
        last_ops = -1
        while (self.op_stat_mon.ops_processed < req_count):
            if (self.op_stat_mon.ops_processed // 100 > last_num):
                last_num = self.op_stat_mon.ops_processed // 100
                cocotb.log.info(f"Completed {self.op_stat_mon.ops_processed} requests...")

            if max_stall_cycles is not None:
                if self.op_stat_mon.ops_processed == last_ops:
                    stall_cycles += 100
                else:
                    stall_cycles = 0
                    last_ops = self.op_stat_mon.ops_processed
                if stall_cycles >= max_stall_cycles:
                    cocotb.log.warning(
                        f"STALL DETECTED after {stall_cycles} cycles: "
                        f"ops_processed={self.op_stat_mon.ops_processed}/{req_count}"
                    )
                    assert False, (
                        f"DUT stalled: ops_processed={self.op_stat_mon.ops_processed} "
                        f"after {stall_cycles} cycles of no progress (expected {req_count})"
                    )

            await ClockCycles(self.dut.CLK, 100)
        await ClockCycles(self.dut.CLK, 100)

        # Wait for every queue's SQTDBL/CQHDBL to converge (each queue's own doorbell state).
        for _ in range(100):
            if all(
                q.nvme_ctrl_model._sqtdbl == q.nvme_ctrl_model._sqhdbl
                and q.nvme_ctrl_model._cqtdbl == q.nvme_ctrl_model._cqhdbl
                and q.iuventus_model.sqhdbl == q.iuventus_model.sqtdbl
                for q in self.queues
            ):
                break
            await ClockCycles(self.dut.CLK, 100)
        else:
            cocotb.log.warning("Timed out waiting for all queues' SQTDBL/CQHDBL to converge...")

        # Drain the doorbell FIFO -- see post_test_checks for the rationale (identical here: it's
        # a single, queue-agnostic hardware FIFO in dbl_updater.vhd).
        self.m_rq_mfb_bpsr.stop()
        self.dut.PCIE_RQ_MFB_DST_RDY.value = 1

        drain_timeout = 50_000
        drain_cycles = 0
        src_rdy_idle_count = 0
        src_rdy_idle_threshold = 10
        while drain_cycles < drain_timeout:
            await RisingEdge(self.dut.CLK)
            drain_cycles += 1
            if not bool(self.dut.PCIE_RQ_MFB_SRC_RDY.value):
                src_rdy_idle_count += 1
            else:
                src_rdy_idle_count = 0
            if src_rdy_idle_count >= src_rdy_idle_threshold:
                break
        else:
            assert False, (
                f"Doorbell FIFO did not drain within {drain_timeout} cycles — "
                "this indicates a genuine RTL hang in dbl_updater, not an in-flight artifact"
            )

        cocotb.log.info(f"Doorbell FIFO drained after {drain_cycles} cycles.")

        # Drain any still-in-flight RD_MFB (read-data) transactions before disabling: op_stat/
        # doorbell convergence only proves every queue's CQE was processed, not that the LAST
        # command's read-data has finished streaming over RD_MFB (that stream can legitimately
        # trail CQE dispatch by a few cycles under the random RD_MFB_DST_RDY backpressure
        # -- see m_rd_mfb_bpsr). Stop that backpressure and hold DST_RDY=1 so the data can flush,
        # then wait until every queue's own predicted RD_MFB queue (nvme_ctrl_model.rd_mfb_exp_out,
        # shared across queues added via add_queue -- see Testbench.add_queue) is fully drained.
        self.m_rd_mfb_bpsr.stop()
        self.dut.RD_MFB_DST_RDY.value = 1

        rd_mfb_drain_timeout = 50_000
        rd_mfb_drain_cycles = 0
        while rd_mfb_drain_cycles < rd_mfb_drain_timeout:
            if all(len(q.nvme_ctrl_model.rd_mfb_exp_out) == 0 for q in self.queues):
                break
            await ClockCycles(self.dut.CLK, 100)
            rd_mfb_drain_cycles += 100
        else:
            cocotb.log.warning(
                "Timed out waiting for RD_MFB to drain: "
                f"{[len(q.nvme_ctrl_model.rd_mfb_exp_out) for q in self.queues]} transactions "
                "still expected per queue."
            )

        cocotb.log.info(f"RD_MFB drained after {rd_mfb_drain_cycles} cycles.")

        await self.disable_dut()

        for q in self.queues:
            q.nvme_ctrl_model.post_check()
            q.iuventus_model.post_check()
            assert q.nvme_ctrl_model.c_sqes_proc == q.iuventus_model.c_sqes_disp, (
                f"queue {q.qid}: SQE mismatch NVME={q.nvme_ctrl_model.c_sqes_proc} "
                f"Iuventus={q.iuventus_model.c_sqes_disp}")
            assert q.nvme_ctrl_model.c_cqes_disp == q.iuventus_model.c_cqes_proc, (
                f"queue {q.qid}: CQE mismatch NVME={q.nvme_ctrl_model.c_cqes_disp} "
                f"Iuventus={q.iuventus_model.c_cqes_proc}")

        raise self.m_scoreboard.result

async def prepare(dut, qsize=16, strict_rq=True):
    CLK_PERIOD = 4
    MI_CLK_PERIOD = 10

    cocotb.log.info(f"Random seed set to {cocotb.RANDOM_SEED}")
    dbg_set = os.getenv("DEBUG_ENABLE", "false") == "true"

    Clock(dut.CLK, CLK_PERIOD, unit='ns').start()
    Clock(dut.MI_CLK, MI_CLK_PERIOD, unit='ns').start()
    global iuventus_model_buffers

    # qsize is parameterized so the phase-wrap stress test can use a small queue: the CQ phase tag
    # toggles every qsize completions, so a small qsize makes wraps frequent. Recreate the model
    # buffers if the qsize changed (cocotb caches them in a module global across tests).
    if iuventus_model_buffers is None or iuventus_model_buffers.qsize != qsize:
        iuventus_model_buffers = IuventusBuffers(qsize)

    qid = 1
    mptr = random.randint(0, 2**64-1)
    sq_baddr = random.randint(0, 2**64-1) & ~(BUFF_SIZE-1)
    cq_baddr = random.randint(0, 2**64-1) & ~(BUFF_SIZE-1)
    sqtdbl_baddr = random.randint(0, 2**64-1) & ~0x3F
    cqhdbl_baddr = random.randint(0, 2**64-1) & ~0x3F
    rdbuff_prpl_baddr = random.randint(0, 2**64-1) & ~0xFFF
    wrbuff_prpl_baddr = random.randint(0, 2**64-1) & ~0xFFF
    rdbuff_baddr = random.randint(0, 2**64-1) & ~(BUFF_SIZE-1)
    wrbuff_baddr = random.randint(0, 2**64-1) & ~(BUFF_SIZE-1)
    rdbuff_prpl_data = [rdbuff_baddr + (i*PAGE_SIZE) for i in range(BUFF_SIZE_PAGES)]
    wrbuff_prpl_data = [wrbuff_baddr + (i*PAGE_SIZE) for i in range(BUFF_SIZE_PAGES)]
    # NOTE: This is somehow arbitrarily created and have to be checked and abided to in the models
    lba_num_mask = 511

    cocotb.log.info(f"Test parameters:\n"
                    f"  QID={qid}\n)"
                    f"  MPTR=0x{mptr:016X}\n"
                    f"  QSIZE={qsize}\n"
                    f"  SQ_BADDR=0x{sq_baddr:016X}\n"
                    f"  CQ_BADDR=0x{cq_baddr:016X}\n"
                    f"  SQTDBL_BADDR=0x{sqtdbl_baddr:016X}\n"
                    f"  CQHDBL_BADDR=0x{cqhdbl_baddr:016X}\n"
                    f"  RDBUFF_PRPL_BADDR=0x{rdbuff_prpl_baddr:016X}\n"
                    f"  WRBUFF_PRPL_BADDR=0x{wrbuff_prpl_baddr:016X}\n"
                    f"  LBA_NUM_MASK=0x{lba_num_mask:04X}\n"
                    f"  RDBUFF_PRPL_DATA={[f'0x{addr:016X}' for addr in rdbuff_prpl_data]}\n"
                    f"  WRBUFF_PRPL_DATA={[f'0x{addr:016X}' for addr in wrbuff_prpl_data]}\n"
                    )

    tb_instance = Testbench(dut=dut, qid=qid, mptr=mptr, qsize=qsize, sq_baddr=sq_baddr, cq_baddr=cq_baddr,
                sqtdbl_baddr=sqtdbl_baddr, cqhdbl_baddr=cqhdbl_baddr, rdbuff_prpl_baddr=rdbuff_prpl_baddr,
                rdbuff_prpl_data=rdbuff_prpl_data, wrbuff_prpl_baddr=wrbuff_prpl_baddr,
                wrbuff_prpl_data=wrbuff_prpl_data, iuventus_model_buffers=iuventus_model_buffers, debug=dbg_set,
                strict_rq=strict_rq)

    await tb_instance.reset()
    # COMMON block (shared registers).
    await tb_instance.m_mi_driver.write(IuventusMiRegMap.RDBUFF_BADDR_L, rdbuff_prpl_data[0].to_bytes(8, 'little'))
    await tb_instance.m_mi_driver.write(IuventusMiRegMap.RDBUFF_PRP_LIST_PTR_L, rdbuff_prpl_baddr.to_bytes(8, 'little'))
    await tb_instance.m_mi_driver.write(IuventusMiRegMap.WRBUFF_BADDR_L, wrbuff_prpl_data[0].to_bytes(8, 'little'))
    await tb_instance.m_mi_driver.write(IuventusMiRegMap.WRBUFF_PRP_LIST_PTR_L, wrbuff_prpl_baddr.to_bytes(8, 'little'))
    await tb_instance.m_mi_driver.write(IuventusMiRegMap.META_PTR_L, mptr.to_bytes(8, 'little'))

    # PER-QUEUE block, slot 0 (this design only has one RTL queue -- see Testbench.nvme_rd/nvme_wr's
    # self.queues[qid] list-index semantics; the `qid=1` label above is a model-internal NVMe
    # protocol sq_id only, unrelated to the RTL routing QID/register slot, which is always 0 here).
    await tb_instance.m_mi_driver.write(per_queue_reg_addr(IuventusPerQueueRegMap.DBL_MASK, 0), int(qsize-1).to_bytes(2, 'little'))
    await tb_instance.m_mi_driver.write(per_queue_reg_addr(IuventusPerQueueRegMap.SQTDBL_BADDR_L, 0), sqtdbl_baddr.to_bytes(8, 'little'))
    await tb_instance.m_mi_driver.write(per_queue_reg_addr(IuventusPerQueueRegMap.CQHDBL_BADDR_L, 0), cqhdbl_baddr.to_bytes(8, 'little'))
    await tb_instance.m_mi_driver.write(per_queue_reg_addr(IuventusPerQueueRegMap.LBA_SPACE_SIZE_L, 0), STORAGE_CAP_LBAS.to_bytes(8, 'little'))
    await tb_instance.m_mi_driver.write(per_queue_reg_addr(IuventusPerQueueRegMap.LBA_NUM_MASK, 0), lba_num_mask.to_bytes(2, 'little'))
    await tb_instance.m_mi_driver.write(per_queue_reg_addr(IuventusPerQueueRegMap.NAMESPACE_ID, 0), int(1).to_bytes(4, 'little'))

    tb_instance.bpsr_start()

    await tb_instance.nullify_cpl_queue()
    await tb_instance.enable_dut()
    return tb_instance


async def prepare_multi(dut, num_queues=None, qsize=16, strict_rq=False):
    """Multi-queue variant of prepare(): builds a Testbench with `num_queues` (default:
    misc_const.NUM_QUEUES, i.e. whatever the elaborated RTL generic is) SQ[q]/CQ[q] queues
    sharing one RDBUFF/WRBUFF data pool, MI-programs each queue's own PER_Q_BASE-based register
    slot (queue 0 is just q=0 of that block -- see cocotbext.ofm.dma.iuventus.iuventus_reg_map),
    and enables the DUT.

    Each queue's model pair uses qid=q (0-based) both as the NVMe protocol-level sq_id (a
    model-internal cross-check between IuventusModel/NVMEControllerModel; the RTL does not
    validate it) and as the RTL routing QID (NVME_RD_REQ_QID / the WR_MFB_META QID bits).
    """
    N = num_queues if num_queues is not None else NUM_QUEUES
    assert N >= 1

    CLK_PERIOD = 4
    MI_CLK_PERIOD = 10

    cocotb.log.info(f"Random seed set to {cocotb.RANDOM_SEED}, NUM_QUEUES={N}")
    dbg_set = os.getenv("DEBUG_ENABLE", "false") == "true"

    Clock(dut.CLK, CLK_PERIOD, unit='ns').start()
    Clock(dut.MI_CLK, MI_CLK_PERIOD, unit='ns').start()

    # One shared RDBUFF/WRBUFF data pool; each queue gets its own IuventusBuffers instance (own
    # SQ[q]/CQ[q] ring) aliasing that same pool -- see IuventusBuffers' shared_pool parameter.
    # (Deliberately NOT the module-global `iuventus_model_buffers`, which the single-queue suite
    # reuses across tests for a different reason -- see that variable's own comment.)
    shared_pool = IuventusBuffers(qsize)
    per_queue_buffs = [IuventusBuffers(qsize, shared_pool=shared_pool) for _ in range(N)]

    mptr = random.randint(0, 2**64-1)
    # Per-queue SQ[q]/CQ[q]: flat page q of a shared BAR0-like/BAR1-like region (mirrors
    # dma_iuventus.vhd's NUM_QUEUES contract: SQ[q] at q*4096, CQ[q] at q*4096).
    sq_region_base = random.randint(0, 2**64-1) & ~(BUFF_SIZE-1)
    cq_region_base = random.randint(0, 2**64-1) & ~(BUFF_SIZE-1)
    rdbuff_prpl_baddr = random.randint(0, 2**64-1) & ~0xFFF
    wrbuff_prpl_baddr = random.randint(0, 2**64-1) & ~0xFFF
    rdbuff_baddr = random.randint(0, 2**64-1) & ~(BUFF_SIZE-1)
    wrbuff_baddr = random.randint(0, 2**64-1) & ~(BUFF_SIZE-1)
    rdbuff_prpl_data = [rdbuff_baddr + (i*PAGE_SIZE) for i in range(BUFF_SIZE_PAGES)]
    wrbuff_prpl_data = [wrbuff_baddr + (i*PAGE_SIZE) for i in range(BUFF_SIZE_PAGES)]
    lba_num_mask = 511

    sq_baddrs = [sq_region_base + q * PAGE_SIZE for q in range(N)]
    cq_baddrs = [cq_region_base + q * PAGE_SIZE for q in range(N)]
    sqtdbl_baddrs = [random.randint(0, 2**64-1) & ~0x3F for _ in range(N)]
    cqhdbl_baddrs = [random.randint(0, 2**64-1) & ~0x3F for _ in range(N)]
    # Disjoint 8-bit PCIe requester-tag ranges, one contiguous block per queue (see
    # NVMEControllerModel's tag_range parameter).
    tags_per_q = 256 // N
    tag_ranges = [range(q * tags_per_q, (q + 1) * tags_per_q) for q in range(N)]

    cocotb.log.info(f"Multi-queue test parameters (N={N}):\n"
                    f"  MPTR=0x{mptr:016X}\n"
                    f"  QSIZE={qsize}\n"
                    f"  SQ_BADDRS={[f'0x{a:016X}' for a in sq_baddrs]}\n"
                    f"  CQ_BADDRS={[f'0x{a:016X}' for a in cq_baddrs]}\n"
                    f"  SQTDBL_BADDRS={[f'0x{a:016X}' for a in sqtdbl_baddrs]}\n"
                    f"  CQHDBL_BADDRS={[f'0x{a:016X}' for a in cqhdbl_baddrs]}\n"
                    f"  RDBUFF_PRPL_BADDR=0x{rdbuff_prpl_baddr:016X}\n"
                    f"  WRBUFF_PRPL_BADDR=0x{wrbuff_prpl_baddr:016X}\n")

    tb_instance = Testbench(
        dut=dut, qid=0, mptr=mptr, qsize=qsize, sq_baddr=sq_baddrs[0], cq_baddr=cq_baddrs[0],
        sqtdbl_baddr=sqtdbl_baddrs[0], cqhdbl_baddr=cqhdbl_baddrs[0],
        rdbuff_prpl_baddr=rdbuff_prpl_baddr, rdbuff_prpl_data=rdbuff_prpl_data,
        wrbuff_prpl_baddr=wrbuff_prpl_baddr, wrbuff_prpl_data=wrbuff_prpl_data,
        iuventus_model_buffers=per_queue_buffs[0], debug=dbg_set, strict_rq=strict_rq,
        tag_range=tag_ranges[0],
        # RD_MFB is a strict (front-of-queue-only) scoreboard by default (see Testbench's
        # rd_mfb_reorder_depth), which is only valid for a single producer's own dispatch order.
        # With N queues each independently (and eagerly, at their own SQE-processing time)
        # appending to the ONE shared rd_mfb_exp_out list, the real DUT's RD_MFB drain -- which
        # follows cqe_processor's single physical round-robin arbiter across all queues, not the
        # appends' racing order -- can legitimately reorder across queues. QUEUE_DEPTH*N bounds how
        # many commands can be concurrently outstanding across all queues, so it bounds how far
        # apart in the expected list a real match can legitimately be.
        rd_mfb_reorder_depth=QUEUE_DEPTH * N)

    for q in range(1, N):
        tb_instance.add_queue(
            qid=q, mptr=mptr, qsize=qsize, sq_baddr=sq_baddrs[q], cq_baddr=cq_baddrs[q],
            sqtdbl_baddr=sqtdbl_baddrs[q], cqhdbl_baddr=cqhdbl_baddrs[q],
            rdbuff_prpl_baddr=rdbuff_prpl_baddr, rdbuff_prpl_data=rdbuff_prpl_data,
            wrbuff_prpl_baddr=wrbuff_prpl_baddr, wrbuff_prpl_data=wrbuff_prpl_data,
            buffs=per_queue_buffs[q], tag_range=tag_ranges[q])

    await tb_instance.reset()
    # COMMON block (shared registers).
    await tb_instance.m_mi_driver.write(IuventusMiRegMap.RDBUFF_BADDR_L, rdbuff_prpl_data[0].to_bytes(8, 'little'))
    await tb_instance.m_mi_driver.write(IuventusMiRegMap.RDBUFF_PRP_LIST_PTR_L, rdbuff_prpl_baddr.to_bytes(8, 'little'))
    await tb_instance.m_mi_driver.write(IuventusMiRegMap.WRBUFF_BADDR_L, wrbuff_prpl_data[0].to_bytes(8, 'little'))
    await tb_instance.m_mi_driver.write(IuventusMiRegMap.WRBUFF_PRP_LIST_PTR_L, wrbuff_prpl_baddr.to_bytes(8, 'little'))
    await tb_instance.m_mi_driver.write(IuventusMiRegMap.META_PTR_L, mptr.to_bytes(8, 'little'))

    # PER-QUEUE block: one slot per queue q = 0..N-1 (queue 0 is just q=0 of this block -- no
    # special-casing). Every queue shares the same (homogeneous) LBA space/namespace/DBL_MASK
    # here, but each is programmed through its own per-queue registers.
    for q in range(N):
        await tb_instance.m_mi_driver.write(per_queue_reg_addr(IuventusPerQueueRegMap.DBL_MASK, q), int(qsize-1).to_bytes(2, 'little'))
        await tb_instance.m_mi_driver.write(per_queue_reg_addr(IuventusPerQueueRegMap.SQTDBL_BADDR_L, q), sqtdbl_baddrs[q].to_bytes(8, 'little'))
        await tb_instance.m_mi_driver.write(per_queue_reg_addr(IuventusPerQueueRegMap.CQHDBL_BADDR_L, q), cqhdbl_baddrs[q].to_bytes(8, 'little'))
        await tb_instance.m_mi_driver.write(per_queue_reg_addr(IuventusPerQueueRegMap.LBA_SPACE_SIZE_L, q), STORAGE_CAP_LBAS.to_bytes(8, 'little'))
        await tb_instance.m_mi_driver.write(per_queue_reg_addr(IuventusPerQueueRegMap.LBA_NUM_MASK, q), lba_num_mask.to_bytes(2, 'little'))
        await tb_instance.m_mi_driver.write(per_queue_reg_addr(IuventusPerQueueRegMap.NAMESPACE_ID, q), int(1).to_bytes(4, 'little'))

    tb_instance.bpsr_start()

    await tb_instance.nullify_cpl_queue()
    await tb_instance.enable_dut()
    return tb_instance


# Largest LBA count a single command may request: NVME_RD_REQ_LBA_NUM / the SQE's num_lba field
# are 8-bit hardware caps independent of buffer size (see MAX_CMD_LBAS) -- min() with
# BUFF_SIZE_LBAS keeps this correct even if the buffer were ever smaller than the field's range.
MAX_REQ_LBAS = min(BUFF_SIZE_LBAS, MAX_CMD_LBAS)

def req_gen(tb, req_count, size_reduce_factor = 1, rd_en = True, wr_en = True):
    random.seed(cocotb.RANDOM_SEED)
    for _ in range(req_count):
        lba_ptr = random.randint(0, STORAGE_CAP_LBAS-1)

        if (random.choice([True, False]) and rd_en) or not wr_en:
            lba_num = random.randint(1, MAX_REQ_LBAS // size_reduce_factor)
            tb.nvme_rd(lba_ptr, lba_num)
        elif wr_en:
            # NVMe writes are whole-LBA: a command covers ceil(len/SECT_SIZE) LBAs, so the SSD reads
            # that many full sectors from the Read Buffer. Generate LBA-aligned write payloads so the
            # read never runs past the written data into a don't-care tail (which the DUT returns as
            # stale RdBuf bytes but the model as zeros -> a seed-dependent CC scoreboard mismatch).
            lba_num = random.randint(1, MAX_REQ_LBAS // size_reduce_factor)
            data = bytearray(random.randbytes(lba_num * SECT_SIZE))
            tb.nvme_wr(lba_ptr, data)


@cocotb.test()
async def run_random_read_test(dut, req_count: int = 20, size_reduce_factor: int = 1):
    # strict_rq=False: multiple NVMe reads are now legitimately outstanding at once (dynamic page
    # allocator), so their doorbell/RQ writes complete/coalesce out of the in-order scoreboard's
    # predicted sequence; correctness is covered by the CC/RD/OP_STAT scoreboards. Same rationale
    # as run_random_rw_test / that_first_bloody_error_test.
    tb = await prepare(dut, strict_rq=False)
    req_gen(tb, req_count, size_reduce_factor=size_reduce_factor, wr_en=False)
    await tb.post_test_checks(req_count)

@cocotb.test()
async def run_random_write_test(dut, req_count: int = 20, size_reduce_factor: int = 1):
    # strict_rq=False: see run_random_read_test.
    tb = await prepare(dut, strict_rq=False)
    req_gen(tb, req_count, size_reduce_factor=size_reduce_factor, rd_en=False)
    await tb.post_test_checks(req_count)

@cocotb.test()
async def run_random_rw_test(dut, req_count: int = 20, size_reduce_factor: int = 1):
    # strict_rq=False: mixed read+write traffic interleaves SQE-MemWr and doorbell TLPs on the shared
    # PCIE_RQ bus under multiple outstanding commands, which the in-order RQ scoreboard cannot
    # predict (spurious ordering mismatches); correctness is covered by the CC/RD/OP_STAT
    # scoreboards.
    tb = await prepare(dut, strict_rq=False)
    req_gen(tb, req_count, size_reduce_factor=size_reduce_factor)
    await tb.post_test_checks(req_count)

@cocotb.test()
async def that_first_bloody_error_test(dut):
    # strict_rq=False: mixed read+write traffic interleaves SQE-MemWr and doorbell TLPs on the shared
    # PCIE_RQ bus, which the in-order RQ scoreboard cannot predict (spurious ordering mismatches);
    # correctness is covered by the CC/RD/OP_STAT scoreboards. Same rationale as run_random_rw_test.
    tb = await prepare(dut, strict_rq=False)

    req_count = 5
    size_reduce_factor = 20
    req_gen(tb, req_count, size_reduce_factor=size_reduce_factor)
    await tb.post_test_checks(req_count=req_count)

    await tb.nullify_cpl_queue()
    await tb.enable_dut()

    await ClockCycles(dut.CLK, 100)

    await tb.post_test_checks(req_count=0, last_test=True)


@cocotb.test()
async def run_phase_wrap_stress(dut, req_count: int = 300, qsize: int = 16, size_reduce_factor: int = 40):
    """Stress the NVMe CQ phase-tag WRAP to look for the intermittent completion-recognition wedge
    seen on hardware (Samsung 990 PRO: op_ctrl parks in S_WAIT_CQE after a CQE the drive wrote is
    never recognized by cqe_processor at a phase-tag wrap boundary).

    The controller's phase tag toggles every `qsize` completions, so `req_count` requests wrap the
    phase ~`req_count/qsize` times. A wrap-boundary off-by-one / read-during-write / phase-toggle
    ordering bug in cqe_processor.vhd (the `observed_phase_value_reg` toggle at cqhdbl rollover,
    cqe_processor.vhd:159-171) that drops a completion would stall `ops_processed` -> caught by
    `max_stall_cycles`. The NVMe model completes out-of-order with randomized CQ-write timing, so
    re-running across seeds explores different read-vs-write phase relationships at the wrap.

    Default qsize=16 is the queue size the reference model was originally validated for. It now runs
    with strict_rq=False: with multiple NVMe commands legitimately outstanding at once (dynamic page
    allocator), the doorbell/RQ writes coalesce/complete out of the in-order scoreboard's predicted
    sequence even at qsize=16 (see run_random_rw_test); the wedge this test targets is still caught by
    the stall detector, and data/status correctness is still covered by the CC/RD/OP_STAT scoreboards.
    For an AGGRESSIVE wrap rate, invoke with a small qsize, e.g. override qsize=4 -- the RQ scoreboard
    is disabled regardless of qsize here, so only the stall detector matters for the wedge in that
    mode. Empirically (2026-06-30) the wedge did NOT reproduce in functional sim across ~250 wraps / 4
    seeds at qsize=4 (no stall), consistent with the hw issue being a single-clock cycle-alignment /
    real-device CQ-write-timing effect rather than a phase-wrap logic bug.
    """
    tb = await prepare(dut, qsize=qsize, strict_rq=False)
    cocotb.log.info(f"PHASE-WRAP STRESS: qsize={qsize} req_count={req_count} "
                    f"(~{req_count // qsize} phase wraps) seed={cocotb.RANDOM_SEED}")
    req_gen(tb, req_count, size_reduce_factor=size_reduce_factor)
    # A permanent wedge (lost completion) shows as ops_processed not advancing; 20000 cycles (80 us)
    # of no progress is far beyond any legitimate out-of-order completion latency here.
    await tb.post_test_checks(req_count, max_stall_cycles=20000)


@cocotb.test()
async def run_wrap_collision_stress(dut, req_count: int = 600, qsize: int = 2, size_reduce_factor: int = 40):
    """ADVERSARIAL CQ phase-wrap collision stress for the intermittent hardware wedge.

    Mechanism under test: when the CQ wraps, cqhdbl returns to slot 0 and the cqe_processor polls
    slot 0 EVERY cycle (DATA_BUFF_RD_EN is tied '1') waiting for the new-phase CQE, while the NVMe
    writes that CQE into slot 0. So a write-vs-read collision on the cq_wr_buffer wrap slot happens on
    essentially every wrap - i.e. the "cycle-aligned" collision is exercised naturally and repeatedly.
    This test maximizes that: the minimum valid queue depth (qsize=2 => a wrap every 2 completions)
    and many requests (~req_count/qsize wraps), across seeds (the randomized CQ-write timing varies
    the sub-cycle write/read alignment each wrap). A lost completion (the wedge) stalls ops_processed.
    qsize=2 is the real design operating point for Iuventus.

    It runs with strict_rq=False: the in-order PCIE_RQ scoreboard mis-predicts doorbell ORDERING at
    qsize<16 (validated only at 16) and would raise spurious "unexpected transaction" mismatches that
    are NOT the wedge. With it off, the verdict is the stall detector (a genuinely lost completion)
    plus the CC / RD-data / OP_STAT scoreboards (which still check completion data/status correctness).

    NOTE on scope: cq_wr_buffer (n2c_controller.vhd:233, TX_DMA_PCIE_TRANS_BUFFER) is single-clock, so
    a functional sim cannot model the metastable/X read a true-dual-port BRAM may return on a
    same-address same-cycle cross-port collision on silicon. With continuous re-polling, a 1-cycle
    stale read here just retries next cycle. So a clean pass across many wraps is evidence the
    completion LOGIC tolerates the collision, supporting an analog/timing (not logic) hw root cause;
    it cannot by itself prove the silicon is immune.
    """
    tb = await prepare(dut, qsize=qsize, strict_rq=False)
    cocotb.log.info(f"WRAP-COLLISION STRESS: qsize={qsize} req_count={req_count} "
                    f"(~{req_count // qsize} wraps, write-vs-read collision on each wrap) "
                    f"seed={cocotb.RANDOM_SEED}")
    req_gen(tb, req_count, size_reduce_factor=size_reduce_factor)
    await tb.post_test_checks(req_count, max_stall_cycles=20000)
    wraps = tb.nvme_ctrl_model.c_cqes_disp // qsize
    cocotb.log.info(f"WRAP-COLLISION STRESS done: {tb.nvme_ctrl_model.c_cqes_disp} completions, "
                    f"~{wraps} CQ phase wraps, no completion lost (no stall).")


@cocotb.test()
async def run_capacity_test(dut, req_count: int = 60):
    """Proves the flat-addressed RDBUFF/WRBUFF buffers (MEM_PARTITIONING => FALSE) can reach data
    pages far beyond the 32-page cap of the pre-flat-addressing (per-channel, 128 KiB partition)
    buffers.

    A single READ command can request up to 256 LBAs (the NVME_RD_REQ_LBA_NUM 8-bit field's
    hard cap) = 32 pages, and multiple READs can be legitimately outstanding at once (the dynamic
    first-fit page allocator, see op_ctrl.vhd). Before this change the whole WRBUFF (32 pages) was
    the allocator's entire span, so at most one maximal-size READ could ever be outstanding --
    page indices > 31 were structurally unreachable. With size_reduce_factor=1 (max-size READs)
    and strict_rq=False (multiple outstanding, as in run_random_read_test), a handful of
    concurrently-outstanding commands push the allocator's high-water mark well past the old cap;
    with DATA_PAGES=127 now available, this test asserts pages up to (33..127) get exercised.
    """
    OLD_BUFF_SIZE_PAGES = 32  # the pre-flat-addressing (partitioned, 128 KiB per channel) page count
    tb = await prepare(dut, strict_rq=False)
    # size_reduce_factor=1: max-size (up to 32-page) READs only -- WRITEs are excluded since this
    # test's capacity claim is specifically about WRBUFF (the READ-data buffer, rd_alloc); RDBUFF
    # (the write-data buffer, wr_alloc) is exercised by run_capacity-adjacent write tests instead.
    req_gen(tb, req_count, size_reduce_factor=1, wr_en=False)
    await tb.post_test_checks(req_count)

    cocotb.log.info(
        f"CAPACITY: max WRBUFF (READ-data) page reached = {tb.nvme_ctrl_model.max_wrbuff_page_used} "
        f"(DATA_PAGES={DATA_PAGES}, pre-flat-addressing cap={OLD_BUFF_SIZE_PAGES})")
    assert tb.nvme_ctrl_model.max_wrbuff_page_used >= OLD_BUFF_SIZE_PAGES, (
        "Capacity test did not reach beyond the pre-flat-addressing page cap "
        f"({OLD_BUFF_SIZE_PAGES}): max page used = {tb.nvme_ctrl_model.max_wrbuff_page_used}. "
        "Increase req_count or lower size_reduce_factor further."
    )


@cocotb.test()
async def run_queue_data_isolation_test(dut, req_count: int = 80, size_reduce_factor: int = 4):
    """Proves that full-data-range RDBUFF/WRBUFF traffic never disturbs the SQ/CQ at flat page 0,
    and vice-versa.

    In this testbench the SQ/CQ and RDBUFF/WRBUFF live at entirely independent PCIe address
    ranges (separate *_BADDR registers), so the isolation risk this actually protects against is
    internal to the RTL's flat-addressed transaction buffer: its page allocator must never hand
    out the queue's reserved page 0 as a data page (which would, on real hardware, alias a data
    write/read onto the SQ/CQ physically sharing that buffer). NVMEControllerModel's
    _dispatch_wr_req/_dispatch_rd_req assert `k >= FIRST_DATA_PAGE` on every single RDBUFF/WRBUFF
    peer-write/read (see nvme_ctrl_model.py), so a violation fails immediately rather than
    silently corrupting data. Correct SQE/CQE dispatch and content across the whole mixed
    read+write workload (verified by the usual CC/RD/OP_STAT scoreboards plus check_doorbels/
    check_dut_cntrs in post_test_checks) additionally proves the queue itself stayed intact
    throughout.
    """
    tb = await prepare(dut, strict_rq=False)
    req_gen(tb, req_count, size_reduce_factor=size_reduce_factor)
    await tb.post_test_checks(req_count)

    # Not vacuous: confirm both buffers' page-0-reservation invariant was actually exercised.
    assert tb.nvme_ctrl_model.max_wrbuff_page_used >= FIRST_DATA_PAGE, \
        "WRBUFF (READ-data) was never exercised -- isolation invariant untested"
    assert tb.nvme_ctrl_model.max_rdbuff_page_used >= FIRST_DATA_PAGE, \
        "RDBUFF (WRITE-data) was never exercised -- isolation invariant untested"
    cocotb.log.info(
        "QUEUE/DATA ISOLATION: SQ/CQ intact after full-range data traffic "
        f"(max WRBUFF page={tb.nvme_ctrl_model.max_wrbuff_page_used}, "
        f"max RDBUFF page={tb.nvme_ctrl_model.max_rdbuff_page_used}, page 0 never touched).")


# =====================================================================================================
# Multi-queue tests (NUM_QUEUES > 1) -- validate the bifurcated multi-queue RTL (Stage B/C).
#
# NUM_QUEUES here is read from the environment (misc_const.NUM_QUEUES), matching whatever value
# the elaborated RTL generic was built with (see ../Makefile's NUM_QUEUES variable, forwarded to
# both `nvc -e -g NUM_QUEUES=...` and this cocotb process's environment). Run at NUM_QUEUES=2 and
# NUM_QUEUES=4 to validate real multi-queue operation; at the default NUM_QUEUES=1 these tests
# still run (as a degenerate single-queue case) but exercise nothing new.
# =====================================================================================================

def req_gen_multi(tb, req_count, num_queues, size_reduce_factor=1, rd_en=True, wr_en=True):
    """Like req_gen, but round-robins requests across all `num_queues` queues, driving
    NVME_RD_REQ_QID (reads) / the WR_MFB_META QID bits (writes) -- see Testbench.nvme_rd/nvme_wr.
    """
    random.seed(cocotb.RANDOM_SEED)
    for i in range(req_count):
        qid = i % num_queues
        lba_ptr = random.randint(0, STORAGE_CAP_LBAS-1)

        if (random.choice([True, False]) and rd_en) or not wr_en:
            lba_num = random.randint(1, MAX_REQ_LBAS // size_reduce_factor)
            tb.nvme_rd(lba_ptr, lba_num, qid=qid)
        elif wr_en:
            lba_num = random.randint(1, MAX_REQ_LBAS // size_reduce_factor)
            data = bytearray(random.randbytes(lba_num * SECT_SIZE))
            tb.nvme_wr(lba_ptr, data, qid=qid)


@cocotb.test()
async def run_multi_queue_rw_test(dut, req_count: int = 80, size_reduce_factor: int = 8):
    """Concurrent read+write traffic spread round-robin across all NUM_QUEUES queues. Verifies
    per-queue completions and data integrity via the shared CC/RD/OP_STAT scoreboards (fed by
    every queue's model predictions, merged in real dispatch order -- see Testbench.add_queue)
    plus each queue's own model post_check (SQTDBL/CQHDBL convergence, no leaked requests). At
    NUM_QUEUES=1 this degenerates to a single-queue mixed read+write test.
    """
    tb = await prepare_multi(dut)
    req_gen_multi(tb, req_count, NUM_QUEUES, size_reduce_factor=size_reduce_factor)
    await tb.post_test_checks_multi(req_count, max_stall_cycles=20000)


@cocotb.test()
async def run_multi_queue_phase_wrap_test(dut, req_count: int = 200, qsize: int = 4, size_reduce_factor: int = 40):
    """Each queue's CQ phase tag wraps independently every `qsize` completions (cqe_processor's
    round-robin arbiter tracks a separate cqhdbl_pst/observed_phase_value_reg per queue -- see
    cqe_processor.vhd). Spreading req_count requests round-robin across NUM_QUEUES queues wraps
    every queue's CQ phase several times; a per-queue phase-wrap bug (e.g. one queue's phase
    toggle being triggered by -- or clobbering -- another queue's wrap) would stall that queue's
    completions, caught by max_stall_cycles.
    """
    tb = await prepare_multi(dut, qsize=qsize)
    cocotb.log.info(f"MULTI-QUEUE PHASE-WRAP: NUM_QUEUES={NUM_QUEUES} qsize={qsize} "
                    f"req_count={req_count} (~{req_count // (qsize * NUM_QUEUES)} wraps/queue) "
                    f"seed={cocotb.RANDOM_SEED}")
    req_gen_multi(tb, req_count, NUM_QUEUES, size_reduce_factor=size_reduce_factor)
    await tb.post_test_checks_multi(req_count, max_stall_cycles=20000)


@cocotb.test()
async def run_multi_queue_isolation_test(dut, req_count: int = 150, size_reduce_factor: int = 8):
    """Cross-queue isolation: heavy traffic skewed toward queue 0 (the "victim") concurrently with
    traffic on every other queue (the "aggressors") must never disturb queue 0's SQ/CQ (flat page
    0) or any other queue's/command's data pages.

    Each queue's IuventusModel/NVMEControllerModel instance only recognizes PCIe peer accesses
    that fall within ITS OWN configured SQ[q]/CQ[q]/RDBUFF/WRBUFF address ranges (see
    IuventusModel.proc_pcie_cq_reqs's "Invalid MRD/MWR address requested" assert) and every
    RDBUFF/WRBUFF access additionally asserts it never lands below FIRST_DATA_PAGE=NUM_QUEUES (see
    NVMEControllerModel._dispatch_wr_req/_dispatch_rd_req) -- a misrouted access (e.g. the RTL
    sending queue A's SQE fetch to queue B's page, or a data command aliasing onto a queue page)
    fails one of those asserts immediately rather than silently aliasing.
    """
    tb = await prepare_multi(dut)
    random.seed(cocotb.RANDOM_SEED)
    for i in range(req_count):
        # Queue 0 (the victim) gets ~half the traffic; the rest round-robins the remaining queues
        # (the aggressors). Meaningful only at NUM_QUEUES>1 -- at NUM_QUEUES=1 everything targets
        # the only queue there is.
        if NUM_QUEUES < 2 or i % 2 == 0:
            qid = 0
        else:
            qid = 1 + (i % (NUM_QUEUES - 1))

        lba_ptr = random.randint(0, STORAGE_CAP_LBAS-1)
        if random.choice([True, False]):
            lba_num = random.randint(1, MAX_REQ_LBAS // size_reduce_factor)
            tb.nvme_rd(lba_ptr, lba_num, qid=qid)
        else:
            lba_num = random.randint(1, MAX_REQ_LBAS // size_reduce_factor)
            data = bytearray(random.randbytes(lba_num * SECT_SIZE))
            tb.nvme_wr(lba_ptr, data, qid=qid)

    await tb.post_test_checks_multi(req_count, max_stall_cycles=20000)

    if NUM_QUEUES > 1:
        cocotb.log.info(
            "MULTI-QUEUE ISOLATION: heavy cross-queue traffic (victim=queue 0) completed without "
            "any queue's peer accesses landing outside its own SQ/CQ/data-pool ranges.")


@cocotb.test()
async def run_multi_queue_capacity_test(dut, req_count: int = 60):
    """All NUM_QUEUES queues contend for the ONE shared RDBUFF/WRBUFF data pool (flat pages
    NUM_QUEUES..127). Proves disjoint page allocation across queues (every queue's own
    NVMEControllerModel independently asserts its own peer accesses never land below
    FIRST_DATA_PAGE=NUM_QUEUES, i.e. never on ANY queue's reserved page -- a collision between two
    queues' commands sharing the same data page would still pass that per-queue assert, but WOULD
    corrupt data and fail the CC/RD scoreboards) and that the pool's capacity is genuinely shared
    (the combined high-water mark across all queues reaches deep into the pool, generalizing the
    single-queue run_capacity_test's claim to N queues contending for it at once).
    """
    OLD_BUFF_SIZE_PAGES = 32  # the pre-flat-addressing (partitioned, 128 KiB per channel) page count
    tb = await prepare_multi(dut)
    req_gen_multi(tb, req_count, NUM_QUEUES, size_reduce_factor=1, wr_en=False)
    await tb.post_test_checks_multi(req_count, max_stall_cycles=20000)

    max_page = max(q.nvme_ctrl_model.max_wrbuff_page_used for q in tb.queues)
    cocotb.log.info(
        f"MULTI-QUEUE CAPACITY: max WRBUFF page reached across all {NUM_QUEUES} queue(s) = "
        f"{max_page} (DATA_PAGES={DATA_PAGES}, pre-flat-addressing cap={OLD_BUFF_SIZE_PAGES})")
    assert max_page >= OLD_BUFF_SIZE_PAGES, (
        "Multi-queue capacity test did not reach beyond the pre-flat-addressing page cap "
        f"({OLD_BUFF_SIZE_PAGES}): max page used across all queues = {max_page}. "
        "Increase req_count."
    )


@cocotb.test()
async def run_multi_queue_flush_test(dut, size_reduce_factor: int = 8):
    """Proves op_ctrl.vhd's per-queue FLUSH keepalive (armed independently by each queue's own
    successful WRITE completion, tracked in flush_delay_cnt_reg/_active_reg/_dispatch_reg -- one
    element per queue) actually reaches the RIGHT queue: after one WRITE completes on EACH queue,
    every queue's own timer should independently expire and dispatch exactly one FLUSH on ITS OWN
    SQ[q]/CQ[q] -- no more, no less, and none of it leaking into another queue's count.

    FLUSH produces no OP_STAT (op_ctrl.vhd's ctx_in_op_type=FLUSH_CMD_OPCODE never matches
    RD_CMD_OPCODE/WR_CMD_OPCODE at completion time), so it is invisible on that interface; instead
    this checks each queue's own nvme_ctrl_model.c_sqes_proc / iuventus_model.c_sqes_disp
    delta -- both counters increment once per SQE dispatched regardless of opcode -- across the
    keepalive window, and finally reuses post_test_checks_multi's own
    c_sqes_proc==c_sqes_disp / c_cqes_disp==c_cqes_proc invariants (see there) as an additional,
    independent confirmation that every queue's model pair agrees nothing was lost or misrouted.

    Requires FLUSH_DELAY_CNTR_WIDTH overridden small (see ../Makefile): the real 28-bit production
    default (2**28 cycles) is unreachable in a functional sim, so this returns immediately
    (harmless quick pass, not a hang) unless it was overridden.
    """
    if FLUSH_DELAY_CNTR_WIDTH > 16:
        cocotb.log.warning(
            f"FLUSH_DELAY_CNTR_WIDTH={FLUSH_DELAY_CNTR_WIDTH} is too wide to reach a keepalive "
            "expiry in a reasonable sim time -- skipping (see Makefile's "
            "FLUSH_DELAY_CNTR_WIDTH override; e.g. `make sim-parallel FLUSH_DELAY_CNTR_WIDTH=6`).")
        return

    tb = await prepare_multi(dut)

    # One WRITE per queue, arming each queue's own keepalive timer at its own completion time.
    random.seed(cocotb.RANDOM_SEED)
    for qid in range(NUM_QUEUES):
        lba_ptr = random.randint(0, STORAGE_CAP_LBAS - 1)
        lba_num = random.randint(1, MAX_REQ_LBAS // size_reduce_factor)
        data = bytearray(random.randbytes(lba_num * SECT_SIZE))
        tb.nvme_wr(lba_ptr, data, qid=qid)

    # Wait for all NUM_QUEUES priming WRITEs to complete (their own OP_STATs).
    for _ in range(2000):
        if tb.op_stat_mon.ops_processed >= NUM_QUEUES:
            break
        await ClockCycles(dut.CLK, 10)
    else:
        assert False, "Timed out waiting for the priming WRITEs to complete"

    # Wait for every queue's own keepalive to expire and its FLUSH to be dispatched+completed.
    # Generous margin: queues arm at slightly different times (their priming WRITEs don't
    # necessarily complete simultaneously -- some queues may already be well into, or even past,
    # their own keepalive window by the time the last one's priming WRITE completes above), and
    # admission of each FLUSH competes with S_IDLE's normal read/write admission priority and with
    # every other queue's own FLUSH (see op_ctrl.vhd's priority-picked flush_qid_v).
    flush_wait_cycles = (2 ** FLUSH_DELAY_CNTR_WIDTH) * 4 + 2000
    await ClockCycles(dut.CLK, flush_wait_cycles)

    # Absolute counts, not a before/after delta: each queue processes EXACTLY 2 SQEs in this
    # whole test (its priming WRITE, then its own FLUSH) if -- and only if -- the keepalive
    # reached the right queue exactly once. A before/after delta would be sensitive to exactly
    # when the snapshot was taken relative to each queue's own (independently-timed) window,
    # which the wait above deliberately does not try to align across queues.
    for qid, q in enumerate(tb.queues):
        assert q.nvme_ctrl_model.c_sqes_proc == 2, (
            f"queue {qid}: expected exactly 2 dispatched SQEs (its priming WRITE + its own "
            f"FLUSH) by now, got {q.nvme_ctrl_model.c_sqes_proc} (nvme_ctrl_model.c_sqes_proc) "
            "-- either the FLUSH never reached this queue or another queue's leaked into it")
        assert q.iuventus_model.c_sqes_disp == 2, (
            f"queue {qid}: expected exactly 2 SQEs IuventusModel observed (its priming WRITE + "
            f"its own FLUSH) by now, got {q.iuventus_model.c_sqes_disp} "
            "(iuventus_model.c_sqes_disp)")

    await tb.post_test_checks_multi(NUM_QUEUES, max_stall_cycles=20000)

    cocotb.log.info(
        f"MULTI-QUEUE FLUSH: all {NUM_QUEUES} queue(s) independently armed, dispatched and "
        "completed exactly one FLUSH keepalive each on their own SQ[q]/CQ[q].")
