.. readme.rst: Documentation of the scratchpad application
.. Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
.. Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
..
.. SPDX-License-Identifier: CC-BY-4.0

.. _ndk_app_scratchpad:

Scratchpad application (AMD Alveo V80)
======================================

The scratchpad turns HBM of the :ref:`Alveo V80 <card_alveo_v80>` into memory the host and PCIe
peers read and write with plain MemWr/MemRd. Each of the card's two CPM5 endpoints (Gen5 x8x8) has a
PF1 with a 1 GB 64-bit prefetchable BAR0, and **both BARs map the same 1 GB of HBM** (stack 0,
pseudo-channel 0, NoC address 0x40_0000_0000). Data written through endpoint 0 is read back through
endpoint 1 and vice versa. There is no DMA: the app brings up the card's CIPS, CPM5 and HBM
configuration.

Architecture
------------

::

    edge lanes 0-7  ── CPM5 ctrl 1 ── EP0 ─┐                       ┌── EP1 ── CPM5 ctrl 0 ── lanes 8-15
                                           │  cpm5_cips (CIPS BD)  │
    PCIE (CPM5 arch): per endpoint PCIE_ADAPTER (1024 b straddle <-> MFB 4 regions) and PCIE_CTRL
                                           │                       │
                  PF0 BAR0 ── MTC ── MI ───┤                       ├─── PF0 BAR0 ── MTC ── MI test space
    MI splitter: test space, PCIe debug,   │                       │
    status of EP0 and EP1 (MI_ASYNC)       │                       │
                  PF1 BAR0 ── PCIE_BAR2AXI ┤                       ├ PCIE_BAR2AXI ── PF1 BAR0
                              AXI4 256 b   │                       │   AXI4 256 b
                              xpm_nmu_mm ──┴── NoC ── HBM PC0 ─────┴── xpm_nmu_mm
                                               (v80_hbm BD, axi_noc HBM only)

- ``CORE_LOGIC`` (``comp/core_logic.vhd``) instantiates the PCIe module, the MI tree and per endpoint
  a ``PCIE_BAR2AXI`` on the DMA CQ/CC port with an ``xpm_nmu_mm`` (``SCRATCHPAD_NMU``) behind it, plus
  the HBM block design. Nothing issues requests, so the PCIe module runs with ``RQ_ENABLE = false``:
  its RQ path is tied off and RC is unused.
- The PCIe module hands PF0 BAR0 (target function 0, BAR ID 0) to its MTC; everything else arrives on
  the DMA CQ port. ``PCIE_BAR2AXI`` serves target function 1, BAR ID 0 (PF1 BAR0) and answers other
  non-posted requests with UR. The 1 GB window starts at AXI address 0x40_0000_0000 on both
  endpoints.
- Clocks: each endpoint's PCIe path, ``PCIE_BAR2AXI`` and NMU run on that endpoint's 250 MHz CPM5 user
  clock. The MI bus runs on the 100 MHz PL0 clock of the CIPS, which the CPM5 PCIe core hands out
  on ``MISC_PCIE2TOP(0)`` (bit 0 clock, bit 1 its active-low reset).
- The NoC connections (each NMU to its own NSU of PC0 and of PC1, 4000 MB/s read and write per path)
  are in ``build/alveo-v80/src/noc_hbm.xdc``, read with ``USED_IN {synthesis_pre}``.

MI address space (endpoint 0, PF0 BAR0)
---------------------------------------

=============== =============================================================================
Address         Content
=============== =============================================================================
0x0000_0000     MI test space (64 words, aliased up to 0x013F_FFFF)
0x0140_0000     PCIe module debug space (empty unless ``PCIE_DEBUG_ENABLE``)
0x0200_0000     Status of endpoint 0: 0x00 accepted MemWr, 0x04 accepted MemRd, 0x08 UR answers,
                0x0C dropped posted requests, 0x10 non-OKAY AXI responses, 0x14 INFO (bit 0 link up,
                bits 7:4 endpoint), 0x18 ID 0x53504144
0x0200_0100     Status of endpoint 1, same layout
=============== =============================================================================

Endpoint 1's PF0 BAR0 ends in its own test space. The DevTree (``comp/DevTree.tcl``) is readable
from both PF0s through the DTB VSEC at 0x600.

Building
--------

.. code-block:: shell

    cd apps/scratchpad/build/alveo-v80
    make                 # full flow to the PDI alveo-v80-scratchpad-pcie1xGen5x8x8.pdi
    SYNTH_ONLY=1 make    # stop after synthesis (runs the NoC compiler)

Simulation
----------

``comp/cocotb`` is an integration bench of the real ``CORE_LOGIC``: simulation stand-ins replace the
CIPS block design, the HBM block design and ``xpm_nmu_mm``. The CPM5 straddle driver plays both
endpoints' CQ, the straddle monitor checks both CC streams and one AXI memory model per NMU shares a
single memory. ``make`` runs it (nvc, cocotb 2), ``SPAD_TLPS`` sets the TLPs per endpoint.

Host test
---------

``sw/scratchpad_test.py`` (Python 3.9+, standard library only) maps PF1 BAR0 of both endpoints through
sysfs, writes through one and reads back through the other: page and 128 B chunk boundaries, random
offsets, lengths and patterns, and write-after-write from both sides. It prints a summary and exits
with 0 (pass), 1 (data mismatch) or 2 (usage or I/O error).

Prerequisites on the host (as root):

.. code-block:: shell

    lspci -d 18ec:c020 ; lspci -d 18ec:c022       # PF1 of endpoint 0 and endpoint 1
    setpci -s <ep0 PF1 BDF> COMMAND=0x02           # enable memory decoding (no driver binds PF1)
    setpci -s <ep1 PF1 BDF> COMMAND=0x02
    ls -l /sys/bus/pci/devices/<BDF>/resource0     # 1 GB, readable and writable by the tester

Then run it with the two PF1 addresses:

.. code-block:: shell

    sudo python3 apps/scratchpad/sw/scratchpad_test.py <ep0 PF1 BDF> <ep1 PF1 BDF>
    sudo python3 apps/scratchpad/sw/scratchpad_test.py <ep0 PF1 BDF> <ep1 PF1 BDF> --access qword --iterations 20000 --seed 1

Notes:

- Mapping ``resource0`` needs root (or a matching file mode); no driver may own PF1.
- The memory decode bit is lost on a rescan or reset of the function; set it again afterwards.
- ``sw/test_scratchpad_test.py`` unit-tests the tool against ordinary files
  (``python3 -m unittest test_scratchpad_test`` in ``sw/``).

Not proven on hardware
----------------------

Link training at Gen5 x8x8, enumeration of the four functions, PERST# through PMC MIO 24/25, HBM
calibration, NoC data correctness and throughput, and the DTB VSEC base 0x600 have only been simulated
or checked by the tools.
