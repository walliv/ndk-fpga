.. _ndk_app_sparklev:

SparkleV NDK application
========================

SparkleV is an NDK-based application for the **AMD Alveo U55C** that turns the card into a
**host-attached HBM accelerator shell**. Unlike the :ref:`Minimal application <ndk_app_minimal>`,
which forwards network packets, SparkleV has no Ethernet data path: its purpose is to give a
user-supplied processing core direct access to the card's **16 GB of HBM2** while the host moves
data into and out of that memory over PCIe. It is the reference design for accelerators that keep
their working set in HBM and are controlled from the host through registers.

SparkleV is built around three things a new user needs to understand:

* the **user core** (``USER_CORE``) — the place where you instantiate your own IP;
* the **HBM** — 16 GB exposed through 32 AXI4 ports, 31 of which are yours;
* the **DMA Hyperion** engine — how the host writes to and reads back from HBM
  (see :ref:`DMA Hyperion <dma_hyperion>`).

Architecture
------------

The application core (``CORE_LOGIC``) wires together the PCIe endpoint, the :ref:`MI configuration
bus <mi_bus>`, the DMA Hyperion engine, the HBM IP, clocking/reset and the user core::

   Host ── PCIe (Gen4 x4) ──►  CORE_LOGIC

       PCIe endpoint  ──►  MI configuration bus (BAR0)  ──►  control plane (your MI registers)
       DMA Hyperion   ──►  BAR2: 16 GB host window      ──►  HBM via port 31      (host <-> HBM)
       USER_CORE      ──►  your custom IP               ──►  HBM via ports 0..30  +  MI bus

       HBM IP : 16 GB · 32 × AXI4 ports (256-bit)
                port 31 → DMA   ·   ports 0..30 → user core

* **PCIe** — one endpoint. The Makefile default is **PCIe Gen4 x4**; the design also supports
  Gen3 x16, Gen3 x8 and Gen4 x8x8 (see ``app_conf.tcl``).
* **HBM** — the Alveo U55C HBM stack provides **16 GB** reachable through **32 AXI4 ports**
  (256-bit data, 34-bit address). Port **31** is reserved for the DMA engine; ports **0–30** are
  routed to the user core, so you have **31 independent AXI4 master ports** into HBM.
* **DMA Hyperion** (``DMA_TYPE = 6``) — moves data between host memory and HBM. The host→HBM
  (H2C) path is a direct BAR2 memory window; the HBM→host (C2H) path is a register-driven reader
  feeding RX DMA Calypte. It uses HBM port 31 only and never touches the user ports. Full details
  in :ref:`DMA Hyperion <dma_hyperion>`.
* **MI** — the 32-bit control bus on BAR0; the user core gets its own region (see
  `MI address map`_).

The user application core
-------------------------

``USER_CORE`` is the entity you fill in. It is selected at build time by the ``USR_CORE_ARCH``
variable and ships with two architectures:

``FULL`` (``apps/sparklev/comp/user_core_full_arch.vhd``)
    The **production template**. It is a documented, synthesizable, completely inert skeleton:
    all HBM ports are tied to a safe idle state and the MI slave acknowledges every request so the
    bus never hangs. Clearly delimited ``=== CONNECT YOUR CUSTOM IP HERE ===`` sections mark where
    to wire your AXI masters (HBM ports 0–30) and your register decode (the MI bus). **Start here.**

``TEST`` (``apps/sparklev/comp/user_core_test_arch.vhd``)
    A bring-up/self-test architecture that instantiates the :ref:`HBM Tester <mem_tester>` on every
    HBM port. Use it to validate a freshly built or freshly flashed card before dropping in your
    own logic.

The ``USER_CORE`` entity (``user_core_ent.vhd``) exposes only what an accelerator needs:

* ``USR_CLK`` / ``USR_RST`` — application clock domain;
* ``MI_CLK`` / ``MI_RST`` + the MI slave bus — your control/status registers;
* ``HBM_AXI_*`` for all 32 ports (drive **0–30**; leave 31 alone, it is tied off in ``CORE_LOGIC``)
  plus ``HBM_INIT_DONE`` (assert your transactions only after this is ``'1'``);
* ``FPGA_ID`` / ``FPGA_ID_VLD`` — board-unique identifier.

.. note::
    The legacy per-packet H2C/C2H DMA MFB streams are **not** part of the contract. In SparkleV the
    host↔HBM data path goes entirely through DMA Hyperion (BAR2 + the C2H reader), so the user core
    only ever talks to HBM and MI.

Building the bitstream
----------------------

The build directory is ``apps/sparklev/build/alveo-u55c``. The Makefile fixes the card,
``DMA_TYPE=6`` and a default ``PCIE_CONF``; you choose the user-core architecture:

.. code-block::

    cd apps/sparklev/build/alveo-u55c

    # Production build with your own logic in the FULL architecture:
    make USR_CORE_ARCH=FULL

    # Bring-up build with the HBM tester:
    make USR_CORE_ARCH=TEST

    # Override the PCIe configuration (default is 1xGen4x4):
    make USR_CORE_ARCH=FULL PCIE_CONF=1xGen3x16

The output bitstream is ``alveo-u55c-sparklev-pcie<conf>.nfw`` (preferred for flashing) and
``.bit``. A successful run reports 0 errors and meets all timing constraints.

.. _sparklev_filelist:

Including SparkleV in your own repository
-----------------------------------------

If you maintain SparkleV (or your customized fork) inside another repository — for example a larger
project that instantiates the design from its own Vivado flow — use the generated **file list**
instead of duplicating the NDK build system.

From the build directory, regenerate it at any time with:

.. code-block::

    cd apps/sparklev/build/alveo-u55c
    make filelist

This produces ``filelist.tcl`` — a stand-alone Tcl script that emits ``read_vhdl`` / ``read_verilog``
/ ``read_xdc`` / ``read_ip`` (and IP-generation ``source``) commands for **every** source of the
design, in dependency order. All paths are expressed relative to the repository root through a
single ``${shell_git_root}`` variable. The checked-in ``filelist.tcl`` is generated for the
``USR_CORE_ARCH=FULL`` configuration.

To consume it from your own Vivado project, define ``shell_git_root`` to point at the NDK-FPGA
checkout and source the list:

.. code-block::

    # In your project's Vivado Tcl flow:
    set shell_git_root /path/to/ndk-fpga
    source $shell_git_root/apps/sparklev/build/alveo-u55c/filelist.tcl

The script ``error``\ s out early if ``shell_git_root`` is not defined. Re-run ``make filelist``
(and commit the result) whenever you change the source set — e.g. after adding files to your user
core or switching ``USR_CORE_ARCH``.

Accessing the design from the host
----------------------------------

SparkleV is driven with the standard ``nfb-*`` tools and the ``ofm`` Python package.

**Flash and identify the card** (the firmware project name is ``SPARKLEV``):

.. code-block::

    nfb-boot -f0 alveo-u55c-sparklev-pcie1xGen4x4.nfw   # then reboot the host
    nfb-info -l                                          # confirm project "SPARKLEV"
    nfb-bus  -l                                          # dump the MI address space / device tree

**Python API.** The ``ofm`` package locates each block by its device-tree ``compatible`` string, so
host code never hardcodes MI addresses:

.. code-block:: python

    import nfb
    from ofm.comp.dma.hyperion.h2c_hyperion_reg_access import HBMWriteWindow
    from ofm.comp.dma.c2h_hbm_reader.c2h_hbm_reader_reg_access import C2HHBMReaderRegAccess

    dev = nfb.open("/dev/nfb0")

    # Host -> HBM: write into the BAR2 window of H2C channel 0 (a 0.5 GB region)
    win = HBMWriteWindow(dev, index=0)
    win.write(0, b"\xde\xad\xbe\xef" * 16)

    # HBM -> host: read it back through the C2H reader + RX DMA Calypte channel 0
    rx = dev.ndp.rx[0]; rx.start()
    rdr = C2HHBMReaderRegAccess(dev)
    rdr.read(hbm_addr=0x0, size=64)        # programs ADDR/SIZE, pulses START, waits for DONE
    data = rx.recv(timeout=1.0)

See :ref:`DMA Hyperion <dma_hyperion>` for the addressing model (H2C 0.5 GB windows vs C2H 2 GB
channels) and the register-level details.

**Ready-made tests.** The ``apps/sparklev/sw`` directory contains runnable end-to-end checks:

* ``hbm_h2c_write_test.py`` — host→HBM write path and its statistics counters;
* ``hbm_bidir_test.py`` — write a pattern (H2C) and read it back (C2H) per channel, plus the
  range-check negative test;
* ``hbm_consistency_test.py`` — strided write/verify sweep across the full 16 GB.

.. _sparklev_mi_map:

MI address map
--------------

The MI control space lives on **BAR0**; the full layout is always discoverable with ``nfb-bus -l``.
The fixed top-level offsets are:

.. list-table::
    :header-rows: 1
    :widths: 30 25 45

    * - Block
      - BAR0 base
      - Device-tree ``compatible``
    * - User application core
      - ``0x02000000``
      - ``ziti,sparklev,conf_space`` (FULL) / HBM tester (TEST)
    * - DMA module
      - ``0x01000000``
      - see below
    * - Boot / MI test space / SDM / HWID
      - core defaults
      - NDK core nodes

Within the DMA module, RX DMA Calypte controllers sit at the base, the H2C Hyperion
control/counters node (``ziti,sparklev,h2c_dma_hyperion``) at ``+0x100000`` and the C2H HBM reader
(``ziti,sparklev,c2h_hbm_reader``) at ``+0x200000``.

**BAR2** is not a register space: it is the **16 GB host-side write window** into HBM used by the
H2C path (mapped write-combined). It must only ever be written — see the warning in
:ref:`DMA Hyperion <dma_hyperion>`.
