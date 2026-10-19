.. _convertors:

PCIE CONVERSION UNITS
=====================

.. vhdl:autoentity:: PCIE_CQ_AXI2MFB

.. vhdl:autoentity:: PCIE_CC_MFB2AXI

Versal CPM5 1024-bit interfaces
-------------------------------

The CQ and CC convertors also handle the straddled 1024-bit interfaces of the Versal CPM5 in
controller-only (PCIE) mode, with up to four TLPs per beat, as MFB (4,1,8,32). ``PCIE_RQ_MFB2AXI``
covers RQ. The RC interface (up to eight TLPs per beat) is not converted: with
``DEVICE = "VERSAL"`` and ``AXI_DATA_WIDTH = 1024`` PCIE_ADAPTER keeps ``RC_AXI_READY`` high,
drops anything arriving on RC (a PSL assertion reports it in simulation) and leaves its RC MFB
output idle. This suits applications that issue no requests. CC and RQ pass through
``PCIE_CPM5_TX_COND`` first. It accepts any legal MFB and emits one TLP per word, starting in
region 0 and without pauses, as CPM5 requires.

.. toctree::
   :maxdepth: 1

   cq_axi2mfb/readme
   cc_mfb2axi/readme
   rq_mfb2axi/readme
   cpm5_tx_cond/readme
