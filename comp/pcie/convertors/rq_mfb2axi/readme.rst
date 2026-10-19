.. readme.rst: PCIE_RQ_MFB2AXI, the Versal CPM5 1024-bit RQ convertor
.. Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
.. Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
..
.. SPDX-License-Identifier: CC-BY-4.0

RQ: Versal CPM5 1024-bit mode
=============================

``PCIE_RQ_MFB2AXI`` converts MFB (4,1,8,32) with the request descriptor in-band to the straddled
1024-bit CPM5 requester request interface (PG346 v3.4, Tables 27 and 28). UltraScale+ RQ
interfaces keep using ``PTC_MFB2PCIE_AXI``; ``PCIE_ADAPTER`` picks this entity when
``DEVICE = "VERSAL"`` and ``AXI_DATA_WIDTH = 1024``. Only ``AXI_RQUSER_WIDTH = 373`` with
``STRADDLING = true`` is supported.

- Framing as on CC: the n-th SOF/EOF of a word becomes ``is_sop[n]``/``is_eop[n]`` with its
  pointer.
- ``first_be``/``last_be`` of TLP n come from ``PCIE_RQ_META_FBE``/``LBE`` of the region holding
  the n-th SOF. ``addr_offset`` (Dword-aligned mode), ``seq_num``, PASID, ``discontinue`` and
  parity are zero; ``TKEEP`` is all ones.
- Same input contract as CC, met by the ``PCIE_CPM5_TX_COND`` that PCIE_ADAPTER puts in front.

The bench in ``cocotb/`` (``make`` there) runs ``sim-conv`` (converter alone, compliant input)
and ``sim-cond`` (conditioner + converter, any legal MFB) under random ``TREADY``.

.. vhdl:autoentity:: PCIE_RQ_MFB2AXI
