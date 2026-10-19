.. readme.rst: Documentation of the AMD Alveo V80 card support
.. Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
.. Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
..
.. SPDX-License-Identifier: CC-BY-4.0

.. _card_alveo_v80:

AMD Alveo V80
-------------

- Card information:
    - Vendor: AMD/Xilinx
    - Name: Alveo V80
    - Ethernet ports: 4x QSFP56 (not supported by the NDK yet)
    - PCIe connectors: Edge connector, Gen5 x8x8 (bifurcated) or Gen4 x16
    - `FPGA Card Website <https://www.amd.com/en/products/accelerators/alveo/v80.html>`_
- FPGA specification:
    - FPGA part number: ``xcv80-lsva4737-2MHP-e-S`` (Versal HBM series, overdrive speed grade)
    - PCIe Hard IP: CPM5 (two controllers)
    - Memory: 32 GB HBM2e in two stacks, reached through the NoC

NDK firmware support
^^^^^^^^^^^^^^^^^^^^

The card support covers what the :ref:`scratchpad application <ndk_app_scratchpad>` needs. There is
no ``src/fpga.vhd`` or ``src/Vivado.inc.tcl`` for the generic NDK top level (``FPGA_COMMON``), so
applications bring their own top level, as the scratchpad does.

- PCIe cores that are supported in the NDK firmware:
    - CPM5 in the :ref:`PCIe Module <ndk_pcie_mod>` (architecture ``CPM5``, ``pcie_core_cpm5.vhd``)
    - The only PCIe configuration is ``1xGen5x8x8``: two Gen5 x8 endpoints, each with PF0 (NDK MI
      bus, BAR0 64 MB) and PF1 (BAR0 1 GB, 64-bit prefetchable). ``config/card_const.tcl`` rejects
      anything else.
- What the card does not provide, and why:
    - Ethernet, DDR4 and the network module: unused by the first application.
    - Flash boot (``BOOT_TYPE`` 0): the PDI has no AMC/RPU firmware and no flash partition table,
      so AVED's ``ami_tool`` flash path cannot load it. Load it over JTAG.
    - SDM/SYSMON and HWID (``SDM_SYSMON_ARCH``/``CLOCK_GEN_ARCH`` ``EMPTY``): no Versal variants exist
      in the NDK yet. The DTB therefore has no card ID.
    - No DMA module (``DMA_TYPE`` 0 only): the CPM5 RC path is not converted to MFB.

Platform block designs
^^^^^^^^^^^^^^^^^^^^^^

``src/ip/v80_platform_bd.tcl`` creates the Versal platform as two block designs, which the build adds
through ``TYPE VIVADO_BD_TCL`` entries in ``MOD``:

- ``cpm5_cips`` (``create_v80_cips_bd``): the CIPS with both CPM5 controllers as 1024-bit straddled
  AXI4-Stream endpoints at 250 MHz, the PMC settings of the board (OSPI boot pins, PMC reference
  clock, PERST# on PMC MIO 24/25) and the 100 MHz PL0 clock. The ``CPM5`` architecture of
  ``PCIE_CORE`` instantiates its wrapper ``cpm5_cips_wrapper``. Controller 1 (edge lanes 0-7) is NDK
  endpoint 0, controller 0 (lanes 8-15) endpoint 1.
- ``v80_hbm`` (``create_v80_hbm_bd``): an ``axi_noc`` with HBM stack 0 channel 0 (PC0 at
  0x40_0000_0000, PC1 at 0x40_4000_0000, 1 GB each) and no AXI ports. The application instantiates
  it and connects its own ``xpm_nmu_mm`` NoC masters with a ``USED_IN {synthesis_pre}`` XDC.
- ``create_v80_platform_bd`` builds both into one block design, the layout the platform prototype
  was first proven with.

The settings that need the overdrive part (``-2MHP``): ``PS_CRL_CPM_TOPSW_REF_CTRL_FREQMHZ`` 1000, the
1024-bit AXI4-Stream width and Gen5 x8 on both controllers.

Constraints
^^^^^^^^^^^

- ``constr/general.xdc``: the HBM stack 0 reference clock pins. The CPM5 GT lanes, their reference
  clocks and PERST# are placed by the CIPS and need no constraints.
- The NoC connections are application specific, see ``apps/scratchpad/build/alveo-v80/src/noc_hbm.xdc``.

Programming the device
^^^^^^^^^^^^^^^^^^^^^^

1. Build the firmware of an application (e.g. ``make`` in ``apps/scratchpad/build/alveo-v80``); the
   build writes a PDI (``write_device_image``).
2. Connect the card's JTAG (USB) and open the Vivado Hardware Manager.
3. Program the device with the PDI, then rescan the PCIe bus (or reboot the host).

.. note::
    To build the NDK firmware for this card, you must have the Xilinx Vivado installed, including a valid license.

.. warning::
    The card support has not been tested on hardware yet: link training at Gen5 x8x8, enumeration,
    PERST# handling and HBM calibration are unproven.
