.. readme.rst: PCIE_CPM5_TX_COND, the CC/RQ input conditioner of the Versal CPM5 1024-bit mode
.. Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
.. Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
..
.. SPDX-License-Identifier: CC-BY-4.0

CPM5 TX conditioner
===================

``PCIE_CPM5_TX_COND`` turns any legal MFB (4,1,8,32) stream into the stream the straddled CPM5 CC
and RQ interfaces accept (PG346 v3.4): no ``SRC_RDY`` gap inside a TLP, and a word with no TLP to
continue starts its first TLP in region 0. ``PCIE_ADAPTER`` puts one in front of
``PCIE_CC_MFB2AXI`` and one in front of ``PCIE_RQ_MFB2AXI`` when ``DEVICE = "VERSAL"`` and
``AXI_DATA_WIDTH = 1024``. The UltraScale+ paths do not use it.

- ``MFB_RECONFIGURATOR`` merges the four regions into one, which aligns every frame to the start
  of a word.
- An ``MFB_FIFOX`` of ``2**log2(2*ceil(MAX_TLP_BYTES/128))`` words (32 for the default 1040 B)
  stores the frames. A counter of complete frames in the FIFO lets the head frame out only once its
  EOF is stored, so the frame then leaves in one burst.
- The output carries one TLP per word, from region 0. Straddling is given up on TX, which suits
  the low completion and doorbell rate of the target applications.
- ``MAX_TLP_BYTES`` must cover the largest TLP. A longer frame never completes, and the conditioner
  then stalls.

The CC and RQ benches (``make sim-cond`` in their ``cocotb/``) drive gappy, misaligned MFB through
conditioner and converter.

.. vhdl:autoentity:: PCIE_CPM5_TX_COND
