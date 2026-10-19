.. readme.rst: Documentation of the PCIE_BAR2AXI component
.. Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
.. Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
..
.. SPDX-License-Identifier: CC-BY-4.0

.. _pcie_bar2axi:

PCIE_BAR2AXI (PCIe BAR to AXI4 bridge)
--------------------------------------

.. vhdl:autoentity:: PCIE_BAR2AXI

Placement
^^^^^^^^^

The component connects to one pair of the NDK PCIe module's DMA CQ/CC MFB ports, where a DMA
engine would sit. The PCIe module sends BAR0 of function 0 to its MTC and everything else to these
ports, so ``BAR_ID``/``FUNC_FILTER_EN``/``FUNC_ID`` select the window served here. The CQ/CC format
is the Xilinx one: the 16-byte CQ descriptor in-band at SOF with First/Last BE in the CQ META, and
the 12-byte CC descriptor in-band. ``DEVICE`` "ULTRASCALE" and "VERSAL" share this format. The
AXI4 master runs on the MFB clock; a Versal NoC NMU provides its own clock-domain crossing.

Internal structure
^^^^^^^^^^^^^^^^^^

- **CQ intake**: an ``MFB_PIPE``, an ``MFB_TRANSFORMER`` down to one 8-DW region per word and a
  second pipe. The descriptor is decoded with ``PCIE_CQ_HDR_DEPARSER`` and ``PCIE_BYTE_COUNT``.
  Each TLP is classified once, at its SOF word.
- **Write engine** (``PCIE_BAR2AXI_WR``): a MemWr payload is stored in one of two staging halves,
  already rotated onto the AXI lanes. It leaves as INCR bursts of full data width (``AxSIZE`` =
  log2 of the bus bytes). Bursts are aligned to the data width, split at 4 KB pages and never longer
  than 4096/bytes-per-beat beats, i.e. at most 128. WSTRB carries First/Last BE and blanks lanes
  outside the payload. All writes use one AWID, so B returns in order.
- **Read engine** (``PCIE_BAR2AXI_RD``): keeps non-posted requests in arrival order. Each entry
  counts the write TLPs accepted before it that still wait for B. A MemRd issues its AXI reads only
  when that count is zero and room for all its 128 B chunks is reserved in the read buffer
  (``RD_BUFFER_BYTES``). RREADY is therefore constant '1'. Reads cover the whole 128 B chunks the
  request touches.
- **Completion engine** (``PCIE_BAR2AXI_CC``): returns one CplD per 128 B address chunk, so only
  the first completion of a request can be shorter. Byte Count, Lower Address, tag, requester ID,
  completer function, TC, attributes and address type follow the request. Every CC TLP starts in
  region 0 of a new MFB word and fills its words alone, which suits straddling and non-straddling
  CC converters.

Ordering and flow control
^^^^^^^^^^^^^^^^^^^^^^^^^

- A MemRd observes every MemWr accepted before it: its first AR is issued only after their last B.
  PSL ``assert_ar_after_earlier_writes`` checks this against a second, independent counter pair.
- MemWr is posted. It keeps flowing to AXI while reads wait for the fence, for read data or for CC
  credit. A read may therefore return data of a write that arrived after it, which PCIe ordering
  allows.
- Completions leave in request order. ``RD_OUTSTANDING`` bounds the non-posted requests between CQ
  acceptance and their last completion. Only when that budget is used up does a non-posted
  request, and everything behind it, wait in the CQ.
- A zero-length read (1 DW, First BE 0000) is executed as a 1-DW read behind the write fence, so it
  works as a flush. Its CplD carries one DW with Byte Count 1.

Unsupported requests
^^^^^^^^^^^^^^^^^^^^

Requests to another BAR or function, MemWr longer than ``MAX_WR_BYTES``, MemRd longer than
``MAX_RD_BYTES``, and any type other than MemRd/MemWr are rejected. Posted ones (MemWr, messages)
are dropped and counted in ``CNT_DROP``. Non-posted ones get a Cpl with status UR and no data,
counted in ``CNT_UR``. For MemRd and MRdLk the UR carries the request's Byte Count and Lower
Address; for every other type it carries Byte Count 4 and Lower Address 0.

AXI attributes
^^^^^^^^^^^^^^

``AXI_CACHE`` defaults to ``0010`` (normal, non-cacheable, non-bufferable). PG313 requires
AxCACHE[1] (modifiable) for HBM bursts with AxSIZE < 4 and AxLEN > 0. This component always uses
the full width (AxSIZE 5 or 6), so the rule does not strictly apply, but the bit is set anyway. The
bufferable bit stays clear so that B comes from the end point, which the read-after-write fence
relies on. Bursts are INCR only. ``AXI_PROT`` and ``AXI_QOS`` are constants. Error responses (any
BRESP/RRESP other than OKAY, counted per B and per R beat) are counted in ``CNT_ERR``; the
affected data are still written or returned.

Verification
^^^^^^^^^^^^

The cocotb suite in ``cocotb/`` runs on nvc. The cocotbext.ofm MFB driver feeds random Xilinx-format
TLPs. MFB monitors and conformance checkers watch CQ and CC. An AXI4 slave model randomises every
ready/valid, write-commit and read latency. A reference model checks every AXI write byte and
strobe, the read-after-write fence at each AR, every completion field, segment size, order, and
read data byte by byte. ``make`` runs one configuration; ``./run_configs.sh N`` runs the four
required configurations (2 or 4 regions, 256 or 512 data bits, both devices) N times with random
seeds.
