# Copyright 2025 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import sys
from pprint import pformat
from dataclasses import dataclass, fields
from typing import Optional, List

import nfb
from cocotbext.ofm.dma.iuventus import CQEntry
from cocotbext.ofm.dma.iuventus import IuventusMiRegMap, CtrlRegBits, StatRegBits
from cocotbext.ofm.dma.iuventus import IuventusPerQueueCntrRegMap, per_queue_cntr_reg_addr

# WRBUFF peer-write 32B-alignment statistics (empirical HW measurement of NVMe peer-write fit to
# a 32B-aligned, <=16-beat AXI burst). Not in IuventusMiRegMap, which lists only SSD
# throughput/HW-debug addresses.
CQ_WR_TOTAL_CNTR_L_ADDR         = 0x0CC
CQ_WR_UNALIGN_START_CNTR_L_ADDR = 0x0D4
CQ_WR_UNALIGN_SIZE_CNTR_L_ADDR  = 0x0DC
CQ_WR_OVER16BEATS_CNTR_L_ADDR   = 0x0E4

@dataclass
class DMAIuventusConfig:
    ctrl_reg                : int
    status_reg              : int
    sqtdbl                  : int
    sqhdbl                  : int
    cqhdbl                  : int
    dbl_mask                : int
    sqtdbl_baddr            : int
    cqhdbl_baddr            : int
    rdbuff_baddr            : int
    rdbuff_prp_list_ptr     : int
    wrbuff_baddr            : int
    wrbuff_prp_list_ptr     : int
    last_cq_entry           : CQEntry
    sqes_dispatched         : int
    cqes_processed          : int
    sq_pcie_rds             : int
    sq_pcie_rds_bytes       : int
    lba_mask                : int
    succ_cpls               : int
    unsucc_cpls             : int
    err_mask                : int
    lba_space_size          : int
    cqhdbl_reg_upd          : int
    sqtdbl_reg_upd          : int
    meta_ptr                : int
    nvme_rd_cmd_bytes       : int
    nvme_wr_cmd_bytes       : int
    tag_fifo_status         : int
    nvme_flush_disp         : int
    cq_wr_total             : int
    cq_wr_unalign_start     : int
    cq_wr_unalign_size      : int
    cq_wr_over16beats       : int

    ERROR_CODES = [
        ("000", "01", "Invalid Opcode"),
        ("000", "02", "Invalid Field"),
        ("000", "03", "Command ID Conflict"),
        ("000", "04", "Data Transfer Error"),
        ("000", "05", "Aborted by Power Loss"),
        ("000", "06", "Internal Error"),
        ("000", "07", "Abort Requested"),
        ("000", "08", "Abort Due to SQ Deletion"),
        ("000", "09", "Abort Failed Due to Missing Fused Command"),
        ("000", "0A", "Abort Missing Fused Command"),
        ("000", "0B", "Invalid Namespace or Format"),
        ("000", "0C", "Command Sequence Error"),
        ("000", "0D", "Invalid SGL Segment"),
        ("000", "0E", "Invalid Number of SGL Descriptors"),
        ("000", "0F", "Data SGL Length Invalid"),
        ("000", "10", "Metadata SGL Length Invalid"),
        ("000", "11", "SGL Descriptor Type Invalid"),
        ("000", "12", "Invalid Use of CMB"),
        ("000", "13", "PRP Offset Invalid"),
        ("000", "14", "Atomic Write Unit Exceeded"),
        ("000", "80", "LBA Out of Range"),
        ("000", "81", "Capacity Exceeded"),
        ("000", "82", "Namespace Not Ready"),
        ("000", "83", "Reservation Conflict"),
        ("000", "84", "Format In Progress"),
        ("001", "80", "Conflicting Attributes"),
        ("001", "81", "Invalid Protection Information"),
        ("001", "82", "Attempted Write to Read-Only Range"),
        ("010", "80", "Write Fault"),
        ("010", "81", "Unrecovered Read Error"),
        ("010", "82", "E2E Guard Check Error"),
        ("010", "83", "E2E Application Tag Error"),
        ("010", "84", "E2E Reference Tag Error"),
        ("010", "85", "Compare Failure"),
        ("010", "86", "Access Denied"),
        ("010", "87", "Deallocated or Unwritten LBA"),
        ("111", "XX",  "Vendor Specific Error")
    ]

    def process_error_mask(self):
        # print(f"🔍 Processing error mask: {mask:#0{66}b}")  # Print in binary (64+2 chars)
        err_list = []
        for i, (sct, sc, description) in enumerate(self.ERROR_CODES):
            bit_set = (self.err_mask >> i) & 1
            status = "❌ Error Present" if bit_set else "✅ No Error"
            err_list.append(f"[{i:02}] SCT={sct:<5} SC={sc:<4} → {description:<42} --> {status}")

        return '\n'.join(err_list)

    def ctrl_reg_str(self):
        reg_bin = '{:08b}'.format(self.ctrl_reg)
        fmt = 'ENABLE: {}\n\t\t\t |  RPT_UPD_EN: {}\n\t\t\t '.format(reg_bin[-1], reg_bin[-5])
        return fmt

    def status_reg_str(self):
        reg_bin = '{:08b}'.format(self.status_reg)
        fmt = 'RDY: {}\n\t\t\t | RST_DONE: {}\n\t\t\t | TAG_INIT_DONE: {}\n\t\t\t'.format(reg_bin[-1], reg_bin[-2], reg_bin[-3])
        return fmt

    def __str__(self) -> str:
        # Items to be printed in order. We use fields(self) to ensure
        # the order is kept as defined in the dataclass.
        items = [(f.name, getattr(self, f.name)) for f in fields(self)]

        # Determine maximum name length for alignment
        max_len = max(len(name) for name, _ in items) if items else 0
        res = []

        for name, val in items:
            # Check for a custom formatter method: {name}_str.
            # For example, ctrl_reg_str or status_reg_str.
            formatter = getattr(self, f"{name}_str", None)
            if callable(formatter):
                try:
                    formatted_val = formatter(val)
                except TypeError:
                    formatted_val = formatter()
            # Hardware-specific formatting for common patterns.
            elif name in ["sqtdbl", "sqhdbl", "cqhdbl", "lba_mask"]:
                formatted_val = f"{val}\t\t({hex(val)})"
            elif name == "dbl_mask":
                formatted_val = f"{hex(val)}\t({val})"
            elif name == "lba_space_size":
                formatted_val = f"{hex(val)}\t ({val} blocks = {val * 512 / (1024**3):.2f} GB)"
            elif name == "last_cq_entry":
                # Align multi-line output for deserialized CQEntry
                formatted_val = pformat(str(val), indent=4, width=80).replace("\n", "\n" + " " * (max_len + 3))
            elif name == "tag_fifo_status":
                formatted_val = f"{val}/2048"
            elif name in ["cq_wr_unalign_start", "cq_wr_unalign_size", "cq_wr_over16beats"]:
                pct = (val / self.cq_wr_total * 100) if self.cq_wr_total else 0.0
                formatted_val = f"{val}\t({pct:.2f}% of cq_wr_total={self.cq_wr_total})"
            elif isinstance(val, int) and ("addr" in name or "ptr" in name):
                formatted_val = hex(val)
            else:
                formatted_val = str(val)

            res.append(f"{name:<{max_len}} : {formatted_val}")

        return "\n".join(res)

class DMAIuventusRegAccess(nfb.BaseComp):
    DT_COMPATIBLE = "ziti,dma_iuventus"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)

    def enable(self) -> None:
        self._comp.set_bit(IuventusMiRegMap.CONTROL.value, CtrlRegBits.ENABLE.value)
        self._comp.wait_for_bit(IuventusMiRegMap.STATUS.value, StatRegBits.READY.value, level=True)

    def disable(self) -> None:
        """Graceful stop + drain barrier. Clearing ENABLE stops the design from accepting new
        traffic and drains every outstanding command; STATUS.READY only drops once the design is
        fully idle, so this call BLOCKS until the drain has completed. Always call this (never a
        bare CONTROL=0 write) and let it return BEFORE tearing down the host NVMe queues -- otherwise
        the SSD's outstanding P2P fetches are stranded and its controller state is corrupted."""
        self._comp.clr_bit(IuventusMiRegMap.CONTROL.value, CtrlRegBits.ENABLE.value)
        self._comp.wait_for_bit(IuventusMiRegMap.STATUS.value, StatRegBits.READY.value, level=False)

    def sample_cntrs(self) -> None:
        self._comp.set_bit(IuventusMiRegMap.CONTROL.value, CtrlRegBits.SAMPLE_CNTRS.value)

    def rst_cntrs(self) -> None:
        self._comp.set_bit(IuventusMiRegMap.CONTROL.value, CtrlRegBits.RST_CNTRS.value)

    def op_soft_rst(self) -> None:
        """Pulses the operational (per-command) soft-reset: clears the DMA's dispatch/completion/
        doorbell FSMs, FIFOs, buffers and tags, WITHOUT resetting this component's own
        per-queue configuration (SQ/CQ/doorbell base addresses stay programmed)."""
        self._comp.set_bit(IuventusMiRegMap.CONTROL.value, CtrlRegBits.OP_SOFT_RST.value)

    def enable_rpt_upd(self) -> None:
        self._comp.set_bit(IuventusMiRegMap.CONTROL.value, CtrlRegBits.EN_UPD_RPT.value)

    def clr_err_mask(self) -> None:
        self._comp.set_bit(IuventusMiRegMap.CONTROL.value, CtrlRegBits.CLR_ERR_MASK.value)

    @property
    def ctrl_reg(self) -> int:
        return self._comp.read8(IuventusMiRegMap.CONTROL.value)

    @property
    def ready(self) -> bool:
        return self._comp.get_bit(IuventusMiRegMap.STATUS.value, StatRegBits.READY.value)
    @property
    def rst_done(self) -> bool:
        return self._comp.get_bit(IuventusMiRegMap.STATUS.value, StatRegBits.RST_DONE.value)

    @property
    def tag_init_done(self) -> bool:
        return self._comp.get_bit(IuventusMiRegMap.STATUS.value, StatRegBits.TAG_INIT_DONE.value)
    @property
    def status_reg(self) -> int:
        return self._comp.read8(IuventusMiRegMap.STATUS.value)

    @property
    def sqtdbl(self) -> int:
        return self._comp.read16(IuventusMiRegMap.SQTDBL.value)
    @property
    def sqhdbl(self) -> int:
        return self._comp.read16(IuventusMiRegMap.SQHDBL.value)
    @property
    def cqhdbl(self) -> int:
        return self._comp.read16(IuventusMiRegMap.CQHDBL.value)
    @property
    def dbl_mask(self) -> int:
        return self._comp.read16(IuventusMiRegMap.DBL_MASK.value)
    @dbl_mask.setter
    def dbl_mask(self, value: int) -> None:
        self._comp.write16(IuventusMiRegMap.DBL_MASK.value, value)

    @property
    def sqtdbl_baddr(self) -> int:
        return self._comp.read64(IuventusMiRegMap.SQTDBL_BADDR_L.value)
    @sqtdbl_baddr.setter
    def sqtdbl_baddr(self, value: int) -> None:
        self._comp.write64(IuventusMiRegMap.SQTDBL_BADDR_L.value, value)

    @property
    def cqhdbl_baddr(self) -> int:
        return self._comp.read64(IuventusMiRegMap.CQHDBL_BADDR_L.value)
    @cqhdbl_baddr.setter
    def cqhdbl_baddr(self, value: int) -> None:
        self._comp.write64(IuventusMiRegMap.CQHDBL_BADDR_L.value, value)

    @property
    def rdbuff_baddr(self) -> int:
        return self._comp.read64(IuventusMiRegMap.RDBUFF_BADDR_L.value)
    @rdbuff_baddr.setter
    def rdbuff_baddr(self, value: int) -> None:
        self._comp.write64(IuventusMiRegMap.RDBUFF_BADDR_L.value, value)

    @property
    def rdbuff_prp_list_ptr(self) -> int:
        return self._comp.read64(IuventusMiRegMap.RDBUFF_PRP_LIST_PTR_L.value)
    @rdbuff_prp_list_ptr.setter
    def rdbuff_prp_list_ptr(self, value: int) -> None:
        self._comp.write64(IuventusMiRegMap.RDBUFF_PRP_LIST_PTR_L.value, value)

    @property
    def wrbuff_baddr(self) -> int:
        return self._comp.read64(IuventusMiRegMap.WRBUFF_BADDR_L.value)
    @wrbuff_baddr.setter
    def wrbuff_baddr(self, value: int) -> None:
        self._comp.write64(IuventusMiRegMap.WRBUFF_BADDR_L.value, value)

    @property
    def wrbuff_prp_list_ptr(self) -> int:
        return self._comp.read64(IuventusMiRegMap.WRBUFF_PRP_LIST_PTR_L.value)
    @wrbuff_prp_list_ptr.setter
    def wrbuff_prp_list_ptr(self, value: int) -> None:
        self._comp.write64(IuventusMiRegMap.WRBUFF_PRP_LIST_PTR_L.value, value)

    @property
    def last_cq_entry(self) -> CQEntry:
        cq_ent_read = int.from_bytes(self._comp.read(IuventusMiRegMap.LAST_CQ_ENTRY_0.value, 16), sys.byteorder)
        return CQEntry.deserialize(cq_ent_read)

    @property
    def sqes_dispatched(self) -> int:
        return self._comp.read64(IuventusMiRegMap.SQE_DISP_CNTR_L.value)

    @property
    def cqes_processed(self) -> int:
        return self._comp.read64(IuventusMiRegMap.CQE_PROC_CNTR_L.value)

    # sq_pcie_rds/sq_pcie_rds_bytes stay aggregate-only; no per-queue breakdown is available.
    @property
    def sq_pcie_rds(self) -> int:
        return self._comp.read64(IuventusMiRegMap.SQ_PCIE_RDS_CNTR_L.value)

    @property
    def sq_pcie_rds_bytes(self) -> int:
        return self._comp.read64(IuventusMiRegMap.SQ_PCIE_RD_BYTES_CNTR_L.value)
    @property
    def lba_mask(self) -> int:
        return self._comp.read16(IuventusMiRegMap.LBA_NUM_MASK.value)

    @lba_mask.setter
    def lba_mask(self, value: int) -> None:
        self._comp.write16(IuventusMiRegMap.LBA_NUM_MASK.value, value)

    # succ_cpls/unsucc_cpls below are COMMON aggregates (all queues summed); pq_* counters further
    # down expose the per-queue breakdown (PER_Q_CNTR_BASE) for HW debug, e.g. localizing a stall.
    @property
    def succ_cpls(self) -> int:
        return self._comp.read64(IuventusMiRegMap.SUCC_COMPL_CNTR_L.value)
    @property
    def unsucc_cpls(self) -> int:
        return self._comp.read64(IuventusMiRegMap.UNSUCC_COMPL_CNTR_L.value)

    @property
    def err_mask(self) -> int:
        return self._comp.read64(IuventusMiRegMap.CPL_ERR_MASK_L.value)
    @property
    def lba_space_size(self) -> int:
        return self._comp.read64(IuventusMiRegMap.LBA_SPACE_SIZE_L.value)

    @lba_space_size.setter
    def lba_space_size(self, value: int) -> None:
        self._comp.write64(IuventusMiRegMap.LBA_SPACE_SIZE_L.value, value)

    @property
    def cqhdbl_reg_upd (self) -> int:
        return self._comp.read64(IuventusMiRegMap.CQHDBL_REG_UPDS_CNTR_L.value)
    @property
    def sqtdbl_reg_upd (self) -> int:
        return self._comp.read64(IuventusMiRegMap.SQTDBL_REG_UPDS_CNTR_L.value)

    @property
    def meta_ptr(self) -> int:
        return self._comp.read64(IuventusMiRegMap.META_PTR_L.value)
    @meta_ptr.setter
    def meta_ptr(self, value: int) -> None:
        self._comp.write64(IuventusMiRegMap.META_PTR_L.value, value)

    @property
    def nvme_rd_cmd_bytes(self) -> int:
        return self._comp.read64(IuventusMiRegMap.NVME_RD_BYTES_CNTR_L.value)
    @property
    def nvme_wr_cmd_bytes(self) -> int:
        return self._comp.read64(IuventusMiRegMap.NVME_WR_BYTES_CNTR_L.value)

    @property
    def tag_fifo_status(self) -> int:
        return self._comp.read16(IuventusMiRegMap.TAG_FIFO_STATUS.value)

    # --- Per-queue SSD-facing stat counters (PER_Q_CNTR_BASE block) ---
    # Read-only; qid is the queue index (0..NUM_QUEUES-1) -- see IuventusPerQueueCntrRegMap's
    # docstring for why sq_pcie_rds has no per-queue counterpart.
    def pq_succ_cpls(self, qid: int) -> int:
        return self._comp.read64(per_queue_cntr_reg_addr(IuventusPerQueueCntrRegMap.SUCC_CPLS_L, qid))

    def pq_unsucc_cpls(self, qid: int) -> int:
        return self._comp.read64(per_queue_cntr_reg_addr(IuventusPerQueueCntrRegMap.UNSUCC_CPLS_L, qid))

    def pq_sqe_disp(self, qid: int) -> int:
        return self._comp.read64(per_queue_cntr_reg_addr(IuventusPerQueueCntrRegMap.SQE_DISP_L, qid))

    def pq_cqe_proc(self, qid: int) -> int:
        return self._comp.read64(per_queue_cntr_reg_addr(IuventusPerQueueCntrRegMap.CQE_PROC_L, qid))

    @property
    def nvme_flush_disp(self) -> int:
        return self._comp.read64(IuventusMiRegMap.NVME_FLUSH_DISP_CNTR_L.value)

    # --- WRBUFF peer-write 32B-alignment statistics (empirical HW measurement) -----------------
    @property
    def cq_wr_total(self) -> int:
        return self._comp.read64(CQ_WR_TOTAL_CNTR_L_ADDR)

    @property
    def cq_wr_unalign_start(self) -> int:
        return self._comp.read64(CQ_WR_UNALIGN_START_CNTR_L_ADDR)

    @property
    def cq_wr_unalign_size(self) -> int:
        return self._comp.read64(CQ_WR_UNALIGN_SIZE_CNTR_L_ADDR)

    @property
    def cq_wr_over16beats(self) -> int:
        return self._comp.read64(CQ_WR_OVER16BEATS_CNTR_L_ADDR)

    def get_configuration(self) -> DMAIuventusConfig:
        """Returns the full configuration of the DMA Iuventus (all properties)."""
        self.sample_cntrs()

        # Build the configuration object dynamically based on dataclass fields.
        # This ensures consistency even if attributes are added or removed.
        conf_kwargs = {}
        for f in fields(DMAIuventusConfig):
            if hasattr(self, f.name):
                conf_kwargs[f.name] = getattr(self, f.name)
            else:
                # Field in dataclass but no matching property/attribute in component?
                # Setting to 0 as a safe default for numeric fields.
                conf_kwargs[f.name] = 0

        return DMAIuventusConfig(**conf_kwargs)

    def configure(self, conf: DMAIuventusConfig) -> None:
        """Configures the DMA Iuventus on write properties"""
        for f in fields(conf):
            if hasattr(self, f.name):
                # Only write to properties that have a setter defined in the class.
                prop = getattr(self.__class__, f.name, None)
                if isinstance(prop, property) and prop.fset is not None:
                    setattr(self, f.name, getattr(conf, f.name))

    def get_fconfiguration(self) -> dict:
        """Returns formatted configuration of the generator as a dictionary"""
        conf = self.get_configuration()
        lst = {}
        for field in fields(conf):
            value = getattr(conf, field.name)
            # Convert booleans to strings for tabulation
            if isinstance(value, bool):
                value = str(value)
            lst.update({field.name: value})
        return lst
