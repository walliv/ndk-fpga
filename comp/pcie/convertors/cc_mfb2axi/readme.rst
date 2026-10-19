.. readme.rst: PCIE_CC_MFB2AXI in the Versal CPM5 1024-bit mode
.. Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
.. Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
..
.. SPDX-License-Identifier: CC-BY-4.0

CC: Versal CPM5 1024-bit mode
=============================

``PCIE_CC_MFB2AXI`` converts MFB (4,1,8,32) to the straddled 1024-bit CPM5 completer
completion interface (PG346 v3.4, Tables 25 and 26). Generics: ``MFB_REGIONS = 4``,
``MFB_REGION_SIZE = 1``, ``MFB_BLOCK_SIZE = 8``, ``MFB_ITEM_WIDTH = 32``,
``AXI_CCUSER_WIDTH = 165``, ``AXI_DATA_WIDTH = 1024`` and ``STRADDLING = true``.

- The n-th SOF of a word becomes ``is_sop[n]`` with its region in ``is_sopN_ptr``; the n-th EOF
  becomes ``is_eop[n]`` with region and ``EOF_POS`` in ``is_eopN_ptr``.
- The core ignores ``TKEEP`` and ``TLAST`` in straddle mode; ``TKEEP`` is all ones.
  ``discontinue`` and parity are zero.
- The input must have no ``SRC_RDY`` gap inside a TLP (PG346 needs ``TVALID`` held for a whole
  TLP), and a word not continuing a TLP must start its first TLP in region 0 (PG346 p.88). The
  converter is combinational and cannot repair either, so PCIE_ADAPTER puts
  ``PCIE_CPM5_TX_COND`` in front of it. PSL checks the conditioned stream.

The bench in ``cocotb/`` (``make`` there) has two parts. ``sim-conv`` drives contract-compliant
completions into the converter. ``sim-cond`` drives any legal MFB through conditioner and converter.
Both run under random ``TREADY``.
