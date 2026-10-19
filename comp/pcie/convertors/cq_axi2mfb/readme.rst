.. readme.rst: PCIE_CQ_AXI2MFB in the Versal CPM5 1024-bit mode
.. Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
.. Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
..
.. SPDX-License-Identifier: CC-BY-4.0

CQ: Versal CPM5 1024-bit mode
=============================

``PCIE_CQ_AXI2MFB`` converts the straddled 1024-bit CPM5 completer request interface
(PG346 v3.4, Tables 23 and 24) to MFB (4,1,8,32). Generics: ``MFB_REGIONS = 4``,
``MFB_REGION_SIZE = 1``, ``MFB_BLOCK_SIZE = 8``, ``MFB_ITEM_WIDTH = 32``,
``AXI_CQUSER_WIDTH = 465``, ``AXI_DATA_WIDTH = 1024`` and ``STRADDLING = true`` (the core's
CQ/CC straddle option must be on as well).

- Up to four TLPs per beat. Every TLP starts on a 256-bit boundary, so ``is_sopN_ptr`` names the
  MFB region of the n-th SOF and ``is_eopN_ptr[4:3]``/``[2:0]`` give region and ``EOF_POS``.
- The 16-byte descriptor stays in-band at SOF, as on UltraScale+. ``first_be``/``last_be`` of
  TLP n and the region's ``byte_en`` slice go to ``CQ_FBE``/``CQ_LBE``/``CQ_BE`` of the SOF
  region, so ``PCIE_ADAPTER`` fills ``PCIE_CQ_META`` exactly as for UltraScale+.
- CPM5 has no TPH, so the TPH outputs are zero. ``discontinue``, parity, PASID and
  ``poisoned_tlp`` are not forwarded (UltraScale+ ignores ``discontinue`` too).
- ``last_be`` is taken per SOP, like ``first_be``; PG346 Table 24 also ties it to ``is_eop``,
  which looks like a copy error but has not been confirmed on silicon.

The bench in ``cocotb/`` (``make`` there) drives random MemRd/MemWr TLPs in legal straddle form
under random ``DST_RDY`` and checks frames, meta, the straddle rules and corner-case coverage.
