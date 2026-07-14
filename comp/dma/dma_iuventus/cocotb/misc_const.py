# misc_const.py: Important constants for the global configuration plus some helper functions
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import os
from enum import IntEnum

# Number of independent SQ/CQ queues (one per SSD), must match the RTL's NUM_QUEUES generic for
# the elaborated design (see ../Makefile's NUM_QUEUES variable / NVC_ELAB_ARGS="-g NUM_QUEUES=...").
# Read from the environment so `make sim-parallel NUM_QUEUES=4` elaborates and runs consistently.
NUM_QUEUES = int(os.environ.get("NUM_QUEUES", "1"))

# Width of OP_CTRL's per-queue FLUSH keepalive delay counter, must match the RTL's
# FLUSH_DELAY_CNTR_WIDTH generic for the elaborated design (see ../Makefile's
# FLUSH_DELAY_CNTR_WIDTH variable / NVC_ELAB_ARGS="-g FLUSH_DELAY_CNTR_WIDTH=..."). Defaults to
# 28, the real production value -- far too slow (2**28 cycles) for a FLUSH test to reach; a
# flush-specific test overrides this via the Makefile to a small value.
FLUSH_DELAY_CNTR_WIDTH = int(os.environ.get("FLUSH_DELAY_CNTR_WIDTH", "28"))

SQE_SIZE = 64
CQE_SIZE = 16
# Width of the LBA-pointer field carried in WR_MFB_META (nvme_meta_pack.vhd's SQE_LBA_PTR_W).
# The Queue Identifier a write request targets is appended above these bits -- see
# dma_iuventus.vhd's WR_MFB_META port comment.
SQE_LBA_PTR_W = 64
MPS = 512
MRRS = 4096
PAGE_SIZE = 4096
SECT_SIZE = 512
STORAGE_CAP = 10 # in MB
STORAGE_CAP_LBAS = (STORAGE_CAP * 1024**2) // SECT_SIZE
STORAGE_CAP_PAGES = (STORAGE_CAP * 1024**2) // PAGE_SIZE
# The RDBUFF/WRBUFF transaction buffer is flat-addressed (RTL MEM_PARTITIONING => FALSE): the
# queue (SQ/CQ) and the data buffer (RDBUFF/WRBUFF) each occupy one flat 512 KiB space, with the
# queue at page 0 and data at pages FIRST_DATA_PAGE..BUFF_SIZE_PAGES-1.
BUFF_SIZE = 2**19 # 512 KiB (flat: 1 queue page + 127 data pages)
BUFF_SIZE_LBAS = BUFF_SIZE // SECT_SIZE
BUFF_SIZE_PAGES = BUFF_SIZE // PAGE_SIZE

# Hardware cap on a SINGLE command's LBA count: NVME_RD_REQ_LBA_NUM (RTL top-level port) and the
# SQE's own num_lba field are 8-bit, 0-based, so a single command can never move more than 256
# LBAs (32 pages) regardless of buffer size. Before this change BUFF_SIZE_LBAS (256) happened to
# equal this cap exactly (the whole old 32-page buffer *was* one command's max); now that the
# buffer holds up to DATA_PAGES=127 pages, this must be a separate, buffer-size-independent bound.
MAX_CMD_LBAS = 256

# Number of NVMe Command Identifiers / outstanding commands, matching the RTL QUEUE_DEPTH
# generic (op_ctrl / tag manager). Also the number of buffer slots the model tracks. Read from
# the environment so `make sim-parallel QUEUE_DEPTH=8` keeps RTL and model in agreement (used to
# validate the timing-tuned QD8 multi-queue build).
QUEUE_DEPTH = int(os.environ.get("QUEUE_DEPTH", "16"))
# Bytes of Read/Write buffer per allocatable command region is decided dynamically by the RTL
# page allocator; SLOT/PAGE granularity is PAGE_SIZE.

# Flat pages 0..NUM_QUEUES-1 hold the N queues' SQ[q]/CQ[q] (SQ[q]/CQ[q] at page q); data pages
# start at FIRST_DATA_PAGE, matching op_ctrl's IUVENTUS_PAGE_ALLOCATOR RESERVED_PAGES generic
# (=NUM_QUEUES). At NUM_QUEUES=1 this is page 1, identical to the original single-queue layout.
FIRST_DATA_PAGE = NUM_QUEUES
# Number of data pages actually available to the allocators (excludes the reserved queue pages),
# shared by all queues.
DATA_PAGES = BUFF_SIZE_PAGES - FIRST_DATA_PAGE

# Per-queue configuration/doorbell registers live in the PER_Q_BASE-based 2D register block (see
# cocotbext.ofm.dma.iuventus.iuventus_reg_map.IuventusPerQueueRegMap/PER_Q_BASE/PER_Q_STRIDE/
# per_queue_reg_addr, which must match nvme_sw_manager.vhd's PER_Q_BASE/PER_Q_STRIDE/PQ_OFFSETS
# exactly). Queue 0 is q=0 of that block -- there is no separate/legacy register set for queue 0.

# Number of pages a WRITE command reserves in RDBUFF, matching op_ctrl's MAX_WR_PAGES generic
# (32: the largest single-command write, since NVME_WR_REQ_FRAME_LNG derives from an 8-bit LBA
# count, i.e. <=256 LBAs). READs always allocate their exact page count and can be
# multiple-outstanding.
MAX_WR_PAGES = 32

# --- Write-combining (WC) emulation for the CQ-side MFB write generator -------------------
# The NVMe controller model writes CQEs and read-data into the FPGA BARs like a CPU storing to a
# write-combined memory region: each MemWr is split into randomly sized, byte-granular bursts (down
# to a single byte, expressed via the PCIe first/last byte enables) and those bursts are emitted
# weakly ordered (out of address order).
# WC_MAX_FRAGS bounds how many bursts a single MPS-sized segment is broken into (>=1); a 16-byte CQE
# can therefore be split into up to 16 one-byte writes. Larger values mean finer fragmentation and
# more TLPs (slower sim).
WC_MAX_FRAGS = 16
# WC_WEAK_ORDER toggles the out-of-order emission. For CQ (CQE) writes the burst carrying the Phase
# Tag byte -- the byte that makes the CQE visible to the FPGA -- is always emitted last (a real
# controller fences before that flag store, so every other CQE byte is written no later); read-data
# bursts carry no in-transfer flag and are fully reordered, the subsequent CQE write being their
# ordering barrier.
WC_WEAK_ORDER = True
# Byte offset of the Phase Tag within a CQE. CQEntry lays the phase_tag bit at bit 112
# (cmd_specific 32 + rsv1 32 + sqhdbl 16 + sq_id 16 + cmd_id 16), i.e. bit 0 of byte 14.
CQE_PHASE_TAG_BYTE = 14

class IuventusBuffers:
    """
    SQ/CQ are per-queue (each queue owns a disjoint region of the flat buffer, page q); RDBUFF/
    WRBUFF are the shared data pool (pages NUM_QUEUES..127, contended by all queues). Pass
    `shared_pool` (another IuventusBuffers instance) to alias this instance's rd_buff/wr_buff onto
    that instance's arrays, giving N per-queue instances (their own sq/cq) a common data pool. At
    NUM_QUEUES=1 (shared_pool=None, the default) this is exactly the original single-queue layout.
    """

    def __init__(self, qsize, shared_pool=None):
        self.qsize = qsize
        self.sq = bytearray(qsize * SQE_SIZE)
        self.cq = bytearray(qsize * CQE_SIZE)
        self._shared_pool = shared_pool
        if shared_pool is not None:
            self.rd_buff = shared_pool.rd_buff
            self.wr_buff = shared_pool.wr_buff
        else:
            self.rd_buff = bytearray(BUFF_SIZE)
            self.wr_buff = bytearray(BUFF_SIZE)

    def reset(self):
        self.sq = bytearray(self.qsize * SQE_SIZE)
        self.cq = bytearray(self.qsize * CQE_SIZE)
        # In-place clear (not rebind): if this instance's rd_buff/wr_buff are aliased by other
        # per-queue IuventusBuffers instances (shared_pool=), rebinding here would leave those
        # aliases stale (still pointing at the old, pre-reset array).
        self.rd_buff[:] = bytes(BUFF_SIZE)
        self.wr_buff[:] = bytes(BUFF_SIZE)

class PageAllocator:
    """
    First-fit contiguous page allocator, mirroring IUVENTUS_PAGE_ALLOCATOR (RTL) exactly: pages
    are allocated as the lowest-address contiguous run of free pages, and freed back individually.
    Used to predict, on the model side, the same buffer page (`k`) the RTL will hand out for each
    command, so that PRP addresses / data placement stay in sync between RTL and model.

    `reserved` mirrors the RTL's RESERVED_PAGES generic: the first `reserved` pages (the queue's
    page 0 in the flat-addressed buffer) are permanently marked occupied and never handed out.
    """

    def __init__(self, pages, reserved=0):
        self.pages = pages
        self.reserved = reserved
        self.occupancy = [i < reserved for i in range(pages)]

    def alloc(self, npages):
        """Return the lowest page index `k` of a free contiguous run of `npages` pages, marking
        it occupied, or None if no such run exists."""
        if npages <= 0 or npages > self.pages:
            return None

        for k in range(self.pages - npages + 1):
            if not any(self.occupancy[k:k + npages]):
                for i in range(k, k + npages):
                    self.occupancy[i] = True
                return k

        return None

    def free(self, k, npages):
        for i in range(k, k + npages):
            if i >= self.reserved:
                self.occupancy[i] = False

    def reset(self):
        self.occupancy = [i < self.reserved for i in range(self.pages)]


class IuventusBarSelection(IntEnum):
    # Logical selector used by the SSD model to pick a buffer. Kept as four distinct values so the
    # model logic can still tell SQ from RDBUFF (and CQ from WRBUFF); the *physical* PCIe BAR_ID
    # driven on the wire is derived via PHYS_BAR_ID below.
    SQ_BAR = 0
    CQ_BAR = 1
    WR_BUFF_BAR = 2
    RD_BUFF_BAR = 3


# Flat-addressed 2-BAR peer layout (matches iuventus_bar_map_pkg.vhd): SQ and RDBUFF share BAR0,
# CQ and WRBUFF share BAR1. The queue vs data datum within a BAR is located by the flat address.
PHYS_BAR_ID = {
    IuventusBarSelection.SQ_BAR:      0,
    IuventusBarSelection.RD_BUFF_BAR: 0,
    IuventusBarSelection.CQ_BAR:      1,
    IuventusBarSelection.WR_BUFF_BAR: 1,
}


class IuventusOpStatCode(IntEnum):
    # These should be 4 bit values
    SUCC = 0x0
    GEN_FAILURE = 0x1
    LBA_OUT_OF_RANGE = 0x2


class PcieReqType(IntEnum):
    MWR = 0x1
    MRD = 0x0


def pcie_byte_count(dword_count, first_be, last_be):
    """
    Calculates Total Byte Count based on AMD's PCIe logic table.
    Handles First BE and Last BE bit positions to determine 'span'.
    """
    if dword_count == 0:
        return 0

    # Find the index of the lowest set bit in first_be (0 to 3)
    # This corresponds to the starting byte offset.
    if first_be == 0:
        assert last_be == 0, "If First BE is 0, Last BE must also be 0."
        assert dword_count == 1, "If First BE is 0, Dword Count must also be 1."
        # Special case: Zero-length read is often treated as 1 byte in some
        # logic tables or specifically handled by the controller.
        # Table 59 shows 0000/0000 = 1 byte.
        return 1

    # Get position of the lowest '1' (e.g., 1100 -> bit 2)
    first_bit_low = (first_be & -first_be).bit_length() - 1

    # Case 1: Single Dword Transaction (Dword Count = 1)
    if dword_count == 1:
        assert last_be == 0, "For Dword Count = 1, Last BE must be 0."
        # In a single DW, the 'span' is from the first bit to the highest bit
        first_bit_high = first_be.bit_length() - 1
        return (first_bit_high - first_bit_low) + 1

    # Case 2: Multi-Dword Transaction (Dword Count > 1)
    else:
        assert last_be != 0, "For Dword Count > 1, Last BE must not be 0."
        # Find the index of the highest set bit in last_be (0 to 3)
        last_bit_high = last_be.bit_length() - 1

        # Logic from Table 59 (cont'd):
        # Total = (Dword_count * 4) - (unenabled bytes at start) - (unenabled bytes at end)
        start_gap = first_bit_low               # Bytes skipped at the beginning
        end_gap = 3 - last_bit_high             # Bytes skipped at the very end

        return (dword_count * 4) - start_gap - end_gap