.. _dma_hyperion:

DMA Hyperion
============

DMA Hyperion (``DMA_TYPE = 6``) is the open-source, HBM-centric DMA engine of the
:ref:`SparkleV application <ndk_app_sparklev>`. Instead of streaming network packets, it moves bulk
data between **host memory and the card's 16 GB HBM**. It is implemented in
``apps/sparklev/comp/comp/dma/dma_hyperion.vhd`` and connects to the PCIe endpoint, a single HBM AXI
port (port 31) and the :ref:`MI bus <mi_bus>`.

It is composed of three sub-engines::

   DMA_HYPERION  (DMA_TYPE = 6)

       H2C DMA Hyperion  │  host → HBM   │  PCIe BAR2 writes ─► AXI W ─► HBM (port 31)
       C2H HBM reader    │  HBM → host   │  AXI R ─► MFB ─► RX DMA Calypte
       RX DMA Calypte    │  card → host  │  delivers C2H stream to NDP RX queues

   MI (BAR0): control + statistics for all three engines

* **H2C DMA Hyperion** — host→HBM. The host writes directly into a BAR2 memory window; the engine
  turns those PCIe writes into HBM AXI write bursts.
* **C2H HBM reader** — HBM→host. A register-programmed engine that issues HBM AXI read bursts and
  streams the result to RX DMA Calypte.
* **RX DMA Calypte** — the open-source low-latency DMA controller that delivers the C2H reader's
  stream into host memory via the standard NDP receive queues.

The host→HBM (H2C) write path
-----------------------------

The host writes to HBM through a **16 GB prefetchable BAR2 window**, partitioned into **32 channels
of 0.5 GB each** (channel ``N`` occupies BAR2 offset ``N × 0x20000000``; 32 × 0.5 GB = 16 GB).
Because the window sits above the 4 GB boundary it is **64-bit and prefetchable**, and the driver
maps it **write-combined**; a fence is issued after each bulk write to order writes within a chunk.

Key properties:

* **Write-only.** The H2C path implements no read completions on BAR2.

  .. warning::
      **Never read from BAR2.** A read has no completion source, so it raises a PCIe completion
      timeout that escalates to an AER fatal error and a host reset. Software (and the OS) must treat
      BAR2 as write-only; do not let anything prefetch or `memcpy`-read it.

* **Non-blocking input.** The shared PCIe CQ stream is never back-pressured: if the engine's input
  FIFO fills, whole frames are dropped (and counted) rather than stalling the endpoint.
* **Statistics.** A software-manager block exposes status flags and 64-bit counters over MI
  (node ``ziti,sparklev,h2c_dma_hyperion``).

H2C control / statistics registers (8-bit ``CONTROL``/``STATUS``, 64-bit counters as L/H pairs):

.. list-table::
    :header-rows: 1
    :widths: 18 14 68

    * - Register
      - Offset
      - Meaning
    * - ``CONTROL``
      - ``0x00``
      - bit0 = SAMPLE_CNTRS (latch counters), bit1 = RST_CNTRS (clear counters)
    * - ``STATUS``
      - ``0x04``
      - bit0 = PCIE_BLOCK, bit1 = HBM_W_BLOCK, bit2 = HBM_AW_BLOCK (back-pressure flags)
    * - ``PCIE_WR_REQS``
      - ``0x08``
      - PCIe write requests received
    * - ``PCIE_WR_REQ_BYTES``
      - ``0x10``
      - bytes received from PCIe writes
    * - ``PCIE_RD_REQS`` / ``_BYTES``
      - ``0x18`` / ``0x20``
      - PCIe read requests / bytes (should stay 0 — BAR2 is write-only)
    * - ``HBM_WR_TRS``
      - ``0x28``
      - HBM AXI write transactions issued
    * - ``HBM_WR_BYTES``
      - ``0x30``
      - bytes written to HBM (matches ``PCIE_WR_REQ_BYTES`` in steady state)
    * - ``PCIE_MFB_BLOCK``
      - ``0x38``
      - cycles the internal MFB stream was blocked
    * - ``HBM_W_BLOCK`` / ``HBM_AW_BLOCK``
      - ``0x40`` / ``0x48``
      - cycles blocked on HBM W / AW channels
    * - ``PCIE_DROP`` / ``_BYTES``
      - ``0x50`` / ``0x58``
      - frames / bytes dropped on input-FIFO overflow

Host access uses ``HBMWriteWindow`` (the BAR2 window, mapped directly) and
``H2CDMAHyperionRegAccess`` (the counters):

.. code-block:: python

    from ofm.comp.dma.hyperion.h2c_hyperion_reg_access import HBMWriteWindow, H2CDMAHyperionRegAccess

    win = HBMWriteWindow(dev, index=5)     # H2C channel 5 -> HBM [5*0.5GB .. 6*0.5GB)
    win.write(0x1000, payload)             # offset within the 0.5 GB window

    stats = H2CDMAHyperionRegAccess(dev).get_statistics()
    print(stats)                           # pcie_wr_bytes, hbm_wr_bytes, drops, ...

The HBM→host (C2H) read path
----------------------------

The C2H HBM reader is a single MI-controlled engine that reads an arbitrary HBM region and streams
it to RX DMA Calypte. The host programs a start address and size, pulses ``START``, and the engine
issues INCR AXI read bursts (≤ 16 × 32 B, single outstanding burst) until the transfer completes.

Registers (node ``ziti,sparklev,c2h_hbm_reader``):

.. list-table::
    :header-rows: 1
    :widths: 20 12 68

    * - Register
      - Offset
      - Meaning
    * - ``CTRL`` (RW)
      - ``0x00``
      - bit0 = START, bit1 = CLEAR_DONE
    * - ``STATUS`` (RO)
      - ``0x04``
      - bit0 = BUSY, bit1 = DONE, bit2 = ERROR (AXI RRESP), bit3 = RANGE_ERR
    * - ``ADDR_L`` / ``ADDR_H``
      - ``0x08`` / ``0x0C``
      - 34-bit HBM start address (low 5 bits are 32 B-aligned)
    * - ``SIZE_L`` / ``SIZE_H``
      - ``0x10`` / ``0x14``
      - transfer size in bytes (64-bit)
    * - ``REQ_CNT_L`` / ``_H``
      - ``0x18`` / ``0x1C``
      - issued AXI read requests (monotonic)
    * - ``REQ_BYTES_L`` / ``_H``
      - ``0x20`` / ``0x24``
      - total requested bytes (monotonic)

**Range check.** On ``START`` the request is validated *before* any AXI read is issued. It is
rejected (``RANGE_ERR`` set, engine stays idle, ``REQ_CNT`` unchanged) if the size is zero, if
``ADDR + SIZE`` exceeds the 16 GB end of HBM, or if the transfer would cross the channel's 2 GB
region (because the channel is derived from the running address — see below). ``CLEAR_DONE`` clears
``DONE``/``RANGE_ERR``.

**Channel routing.** The destination RX DMA Calypte channel is encoded in the **top 3 bits of the
HBM address**: ``araddr[33:31] → ARID[2:0]``, the HBM echoes it on ``RID``, and the reader copies
``RID[2:0]`` into the MFB ``CHAN`` metadata that selects the RX channel. This gives **8 C2H channels
of 2 GB each** spanning the 16 GB space (channel ``c`` = HBM region ``[c × 2 GB .. (c+1) × 2 GB)``).

Host access uses ``C2HHBMReaderRegAccess`` together with the NDP receive queue:

.. code-block:: python

    from ofm.comp.dma.c2h_hbm_reader.c2h_hbm_reader_reg_access import C2HHBMReaderRegAccess

    ch = 3
    rx = dev.ndp.rx[ch]; rx.start()                 # start the RX queue first
    rdr = C2HHBMReaderRegAccess(dev)
    rdr.read(hbm_addr=ch * (2 << 30), size=4096)    # clears DONE, sets ADDR/SIZE, START, waits DONE
    frame = rx.recv(timeout=1.0)

.. note::
    RX DMA Calypte back-pressures the reader if software does not ``recv()`` fast enough: the ring
    fills, ``HBM_AXI_RREADY`` deasserts and the reader stalls — it never drops data or wedges the
    host. Always start the RX queue before triggering a read.

Addressing model: H2C windows vs C2H channels
---------------------------------------------

The two directions partition the same 16 GB differently, which lets the round-trip be exercised
per channel:

.. list-table::
    :header-rows: 1
    :widths: 25 20 55

    * - Path
      - Granularity
      - Mapping
    * - H2C (write)
      - 32 × 0.5 GB
      - BAR2 window ``N`` → HBM ``[N × 0.5 GB, …)``
    * - C2H (read)
      - 8 × 2 GB
      - HBM ``araddr[33:31]`` → RX channel

So one C2H channel covers exactly **four** consecutive H2C write windows
(C2H channel ``c`` ↔ H2C windows ``4c … 4c+3``). To round-trip C2H channel ``c``, write through
``HBMWriteWindow(dev, index=4*c)`` and read it back on ``dev.ndp.rx[c]``.

Configuration
-------------

DMA Hyperion is parameterized in ``apps/sparklev/build/alveo-u55c/app_conf.tcl``:

.. list-table::
    :header-rows: 1
    :widths: 30 15 55

    * - Parameter
      - Default
      - Meaning
    * - ``DMA_TYPE``
      - ``6``
      - selects DMA Hyperion (set by the Makefile)
    * - ``H2C_DMA_CHANNELS``
      - ``32``
      - number of 0.5 GB BAR2 write windows
    * - ``C2H_DMA_CHANNELS``
      - ``8``
      - number of RX DMA Calypte read channels (top 3 HBM address bits)
    * - ``DMA_PKT_SIZE_MAX``
      - ``4096``
      - maximum DMA frame size in bytes
    * - ``C2H_DMA_GEN_EN`` / ``H2C_DMA_GEN_EN``
      - ``true``
      - enable each direction independently

The PCIe BAR2 size (16 GB, prefetchable, 64-bit) is enabled in the card's PCIe IP only when
``DMA_TYPE == 6``; without it the window defaults to 16 MB and the HBM cannot be mapped.

Limitations
-----------

* **BAR2 is write-only** — reading it triggers a host reset (see the warning above). HBM contents
  are read back exclusively through the C2H reader + RX DMA Calypte path.
* The C2H reader uses a single outstanding burst; it is built for correctness and bring-up rather
  than peak read throughput.
