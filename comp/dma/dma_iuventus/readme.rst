.. readme.rst: DMA Iuventus documentation
.. Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
.. Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
..
.. SPDX-License-Identifier: CC-BY-4.0

.. _dma_iuventus:

DMA Iuventus
============

DMA Iuventus turns the FPGA into an **NVMe requester** (host controller) over PCI Express. Instead of
being driven by a host CPU, the FPGA itself composes NVMe commands, posts them to a Submission Queue
(SQ), rings the target SSD's doorbell, and consumes the Completion Queue (CQ). This lets the FPGA
drive a commercial NVMe SSD directly and move data between the SSD and the FPGA without the host CPU
in the data path.

The NVMe queues and data buffers live in the **FPGA's BAR memory**, and the SSD accesses them
peer-to-peer over PCIe: it *reads* the Submission Queue and the Read Buffer from the FPGA BAR, and it
*writes* the Completion Queue and the Write Buffer into the FPGA BAR. The module is configured and
observed through internal Control and Status (C/S) registers on the :ref:`MI bus<mi_bus>` (Control
Flow); the NVMe traffic uses the :ref:`MFB bus<mfb_bus>` connected to the PCIe **RQ** (requester
request, FPGA → PCIe) and **CQ** (completer request, PCIe → FPGA) interfaces (Data Flow).

.. vhdl:autoentity:: DMA_IUVENTUS

How it works
------------

An NVMe I/O operation driven by DMA Iuventus proceeds as follows:

1. **Trigger.** ``OP_CTRL`` (operation control) receives a read/write request — from the user logic /
   test generator or from the arrival of a write-data frame on the ``WR_MFB`` interface — and emits
   the command parameters (opcode, LBA pointer, LBA count, PRP pointers).
2. **Compose the SQE.** ``C2N_CONTROLLER`` (card-to-NVMe) builds the 64-byte Submission Queue Entry:
   ``NVME_CMD_DISPATCHER`` obtains a unique **command identifier (CID)** from
   ``IUVENTUS_CMD_TAG_MANAGER`` and tracks the SQ tail pointer, and the command composer assembles the
   SQE fields (opcode, NSID, CID, PRP1/PRP2, starting LBA, LBA count). The SQE is placed into the
   Submission Queue region of the FPGA BAR.
3. **Ring the doorbell.** ``DBL_UPDATER`` writes the SSD's SQ-tail doorbell register (``SQTDBL``) — and
   the CQ-head doorbell (``CQHDBL``) — via a PCIe RQ MemWr to the doorbell base addresses programmed in
   the C/S registers. It also contains an optional *repeat* mechanism (see below).
4. **SSD fetches and executes.** On the doorbell, the SSD peer-**reads** the new SQE from the FPGA-BAR
   Submission Queue, and — for a WRITE command — peer-reads the write-data from the FPGA-BAR Read
   Buffer (referenced by the PRP pointers). It then performs the media access.
5. **Completion.** The SSD peer-**writes** a Completion Queue Entry into the FPGA CQ BAR (and, for a
   READ command, the read-data into the Write Buffer BAR). ``NVME_CQ_META_EXTRACTOR`` parses the
   incoming write's header/BAR and ``N2C_CONTROLLER`` (NVMe-to-card) validates the CQE, advances the
   SQ head, updates the CQ-head doorbell, and increments the success/error completion counters.

**Queue / buffer placement.** SQ, CQ, Read Buffer and Write Buffer all reside in the FPGA BAR
(``iuventus_bar_map_pkg``: ``SQ_BAR_ID`` / ``CQ_BAR_ID`` / ``RDBUFF_BAR_ID`` / ``WRBUFF_BAR_ID``); the
SSD reaches them peer-to-peer.

.. note::

   A variant that moves the SQ and Read Buffer into **host DRAM** (a two-BAR PF1 layout, with the FPGA
   posting SQEs via PCIe RQ MemWr instead of the SSD peer-reading them) was investigated to work
   around the Samsung 990 PRO idle-eviction wedge. It is **not** the design documented here: it kept
   an SK hynix drive working but broke the Samsung 990 PRO's first-op fetch (the SSD would not act on
   the FPGA's peer doorbell for a host-DRAM SQ), so the FPGA-BAR placement above is retained. The
   host-DRAM experiment is preserved on a separate branch. See the P2P compatibility notes below.

Control and Status (C/S) registers
-----------------------------------

``NVME_SW_MANAGER`` implements the register file reached over the MI bus. The main registers:

- ``R_CONTROL`` — control bits: ``DESIGN_EN`` (bit 0, enable the controller FSM), ``SAMPLE_CNTRS``
  (bit 1), ``CLR_ERR_MASK`` (bit 2), ``RST_CNTRS`` (bit 3), and ``RPT_PTR_UPDATE`` (bit 4, enable the
  doorbell-repeat logic — **off by default**).
- ``R_STATUS`` — run/ready status of the controller.
- ``R_SQTDBL`` / ``R_SQHDBL`` / ``R_CQHDBL`` — the FPGA's view of the SQ tail, SQ head and CQ head.
- ``R_*_BADDR_{L,H}`` — 64-bit base addresses programmed at init (the SSD's ``SQTDBL`` / ``CQHDBL``
  doorbell registers, the Read Buffer and Write Buffer, and their PRP-list pointers).
- ``R_DBL_MASK`` — doorbell mask.
- Statistics counters (``R_SQE_DISP_CNTR``, ``R_CQE_PROC_CNTR`` and the successful/unsuccessful
  completion, PCIe read/write and byte counters) used to observe operation and diagnose stalls, e.g.
  ``sqes_dispatched``, ``cqes_processed``, ``succ_cpls``, ``unsucc_cpls``, ``sq_pcie_rds`` (SSD peer
  reads of the SQ), ``rdbuff_pcie_rds`` (SSD peer reads of the Read Buffer).

**Command-ID (tag) management.** ``IUVENTUS_CMD_TAG_MANAGER`` is a free-list FIFO seeded at reset with
the unique tags ``0 .. 2047``. A tag is popped when a command is composed and pushed back when its
completion returns (via the CQE's command-ID field), guaranteeing that command IDs are unique among
outstanding commands, as required by NVMe.

**Doorbell-repeat (anti-idle) mechanism.** ``DBL_UPDATER`` can re-issue a doorbell write if the
doorbell value has been unchanged for ``REPEAT_DELAY`` clock cycles (top-level default ``2**28`` ≈ 1 s
at the PCIe user clock). It is gated by ``R_CONTROL`` bit 4 (``RPT_PTR_UPDATE``) and is **off after
reset**; software (e.g. the control application) enables it during operation. It is intended to keep
an idle-sensitive SSD's queue-fetch engine alive by periodically re-ringing the doorbell.

Verification and test results
-----------------------------

DMA Iuventus is verified both in simulation (cocotb, ``nvc``) and on hardware (an SPDK-based control
application on an Alveo U55C):

- **Cocotb** — the suite (random read / write / read-write, phase-wrap and wrap-collision stress, and
  the completion-queue nullification test) passes; re-run across multiple random seeds with 0 failures
  (repeatable). Fast iteration is provided by the ``sim-elab`` / ``sim-run`` and parallel-runner
  targets and by gating the ``nvc`` waveform dump behind ``DEBUG_ENABLE``.
- **Hardware, SK hynix PC611** — fully works and is repeatable for both slow-paced (paced writes +
  reads) and high-throughput workflows.
- **Hardware, Samsung 990 PRO** — see the P2P compatibility notes: this consumer SSD is unreliable as
  a P2P target; it is not a supported drive for DMA Iuventus.

.. _dma_iuventus_p2p_compat:

NVMe Peer-to-Peer (SSD) Compatibility
-------------------------------------

Because the FPGA acts as an NVMe requester and the queues/buffers live in the FPGA BAR, DMA Iuventus
depends on **PCIe peer-to-peer (P2P)** transactions with the SSD (the FPGA writing the SSD's doorbell,
and the SSD reading its SQ / Read Buffer from — and writing its CQ / Write Buffer into — the FPGA
BAR). P2P support is **strongly device- and platform-dependent**, and *consumer / client* NVMe SSDs
are the least reliable class for this use. Verified drives should be qualified individually; do not
assume an arbitrary NVMe SSD will work as a P2P target. On the ZITI test host an SK hynix PC611 works
fully while both Samsung 990 PRO drives fail.

The following summary of the state of the art was **researched and sourced by Claude** (AI assistant)
and reflects public sources as of July 2026:

- **Cross-root-complex P2P is blocked by default** in the Linux kernel; it is only permitted for host
  bridges present in the ``pci_p2pdma_whitelist`` or for devices behind a common PCIe switch. Many
  root complexes route P2P inefficiently, and placing the devices behind a real PCIe switch
  (e.g. Microsemi/PLX) is the recommended topology; AMD EPYC is noted as one of the few root complexes
  with good P2P capability. (Linux kernel *PCI Peer-to-Peer DMA Support* docs; Eideticom.)
- **Standard NVMe P2PDMA requires the drive to expose a Controller Memory Buffer (CMB)** to be a P2P
  source/target — a feature that most consumer SSDs (including the 990 PRO) do not advertise, placing
  this use outside the standard-supported envelope. (SPDK *Peer-2-Peer DMAs*; NVM Express CMB/PMR.)
- **Placing NVMe queues in peer/device memory and ringing the SSD doorbell from the peer** (exactly
  the FPGA-BAR queue model) is the approach used by the GPU-driven NVMe projects **BaM / libnvm /
  ssd-gpu-dma**. Those projects explicitly maintain **allow-/block-lists of NVMe devices** that do and
  do not work correctly in this mode — i.e. it is expected that some SSDs simply misbehave when their
  queues/doorbells are driven peer-to-peer. (``enfiskutensykkel/ssd-gpu-dma``; BaM, arXiv:2203.04910.)
- **NVIDIA GPUDirect Storage is officially qualified only on datacenter-class drives**, not consumer
  SSDs; vendor stacks do not certify client drives for direct/P2P storage paths.
  (NVIDIA GPUDirect Storage.)

*Caveat:* no public source names the Samsung 990 PRO specifically as failing this P2P mode; that
attribution is a local hardware finding. The *general* phenomenon — consumer NVMe SSDs being
unreliable/unsupported for P2P, particularly for queues-in-peer-memory and peer-originated doorbells —
is firmly established and consistent with the local observations.

Host-bypass acceleration reports the same limitations
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

DMA Iuventus belongs to the hardware-acceleration category commonly called **host-bypass** (or
*host-bypassing* / *CPU-bypass*) storage: an accelerator (FPGA, GPU or SmartNIC) drives the NVMe SSD
**directly** — it owns the Submission/Completion Queues, rings the SSD's doorbell, and consumes
completions itself — so the host CPU is out of both the control and the data path. Placing the NVMe
queues and buffers in the accelerator's BAR memory (as this design does) and ringing the doorbell from
the accelerator is exactly the mechanism used by that whole body of work:

- **GPU-initiated I/O — BaM / libnvm / ssd-gpu-dma.** BaM "manages NVMe Submission and Completion
  Queues directly in GPU memory so that GPU kernels can enqueue commands, ring the NVMe doorbell, and
  observe completions entirely from device code." That is the GPU analogue of what DMA Iuventus does
  from the FPGA. (BaM, arXiv:2203.04910; ``enfiskutensykkel/ssd-gpu-dma``.)
- **FPGA/SoC NVMe host accelerators** — e.g. the AMD *NVMe Host Accelerator* (NVMeHA), iWave and
  BittWare NVMe-on-FPGA IP — offload IO-queue management and doorbell ringing into the FPGA fabric,
  bypassing the (embedded or host) CPU. (AMD NVMeHA; iWave; BittWare.)
- **GPUDirect Storage (GDS)** — the vendor productisation of GPU↔SSD host-bypass DMA. (NVIDIA GDS.)

The published experience in this category reports **the same class of incompatibilities observed
here**, and treats them as an inherent property of driving commodity NVMe SSDs outside their intended
usage — not as isolated bugs:

- **Current NVMe / SSDs are not designed for accelerator-driven access.** The problem is recognised at
  the standards level: SNIA's session *"Why does NVMe Need to Evolve for Efficient Storage Access from
  GPUs?"* takes as its premise that today's queue/doorbell model and controller behaviour are
  inadequate for host-bypass, and a companion session addresses the access-control gaps of GPU-Direct.
  The root mismatch — the SSD's expectations vs. an accelerator managing its queues/doorbells — is the
  same one that manifested here as the Samsung 990 PRO refusing to act on the FPGA's peer doorbell.
  (SNIA sessions 19283, 19591.)
- **Compatibility is per-device, and the field manages it with allow-/block-lists.** The GPU-SSD
  host-bypass projects explicitly maintain lists of NVMe drives that do and do not work in this mode,
  and FPGA NVMe host-IP vendors document that the design must be *tuned per SSD model* (queue depth,
  outstanding-command count, on-chip buffer allocation). This mirrors the local result exactly: on the
  same host and PCIe path an SK hynix PC611 works while both Samsung 990 PRO drives fail — a
  device-specific outcome, not a property of the FPGA design. (ssd-gpu-dma; iWave.)
- **The two pain points the literature centres on are the two that failed here.** (1) *The doorbell.*
  BaM describes device-side doorbell ringing as a first-class difficulty and a "high cost" operation;
  our Samsung failure is precisely a doorbell that the SSD honours from the root complex but not from
  the FPGA peer. (2) *Queues/buffers in non-host memory.* Standard NVMe P2PDMA is only defined for
  drives exposing a Controller Memory Buffer (CMB); placing queues in a *peer's* BAR and having the
  SSD fetch them peer-to-peer is outside the standardised envelope, and is exactly where consumer SSD
  behaviour becomes unreliable (fetch stalls, idle-queue eviction). (BaM; SPDK Peer-2-Peer; NVM
  Express CMB/PMR.)
- **Host-bypass work overwhelmingly relies on enterprise/CMB-class drives.** Published GPU/FPGA-SSD
  systems are built and benchmarked on datacenter NVMe or Intel Optane and CMB-capable devices — a
  tacit acknowledgement that client/consumer drives are the unreliable class for this access pattern.
  (BaM; NVIDIA GDS.)

Additionally, host-bypass deliberately steps around the OS storage stack, which the security
literature flags as a hazard in its own right (direct queue/doorbell access bypasses kernel-level
protection and namespace-level reservations). (*Pandora's Box in Your SSD*, arXiv:2411.00439.)

**Reconciling with the local observations.** Two honest qualifications. First, no public source names
the **Samsung 990 PRO specifically**; the device attribution is a local hardware finding — but it is a
concrete *instance* of the documented pattern, not an anomaly. Second, both local drives are
client-class (SK hynix PC611, Samsung 990 PRO) and only one works, which fits the *per-device
allow-list* framing better than a clean consumer-vs-enterprise split: host-bypass compatibility must be
qualified drive-by-drive.

**Practical guidance:** treat P2P SSD support as a per-device qualification step, and prefer
datacenter/enterprise NVMe SSDs (ideally with CMB) and a topology that keeps the FPGA and SSD under a
common PCIe switch or a P2P-capable root complex.

Sources (compiled by Claude):

- Linux kernel — *PCI Peer-to-Peer DMA Support*: https://docs.kernel.org/driver-api/pci/p2pdma.html
- SPDK — *Peer-2-Peer DMAs*: https://spdk.io/doc/peer_2_peer.html
- Eideticom — *P2PDMA in Linux Kernel 4.20*:
  https://www.eideticom.com/media-news/blog/33-p2pdma-in-linux-kernel-4-20-rc1-is-here.html
- NVM Express — *Enabling the NVMe CMB and PMR Ecosystem*:
  https://nvmexpress.org/wp-content/uploads/Enabling-the-NVMe-CMB-and-PMR-Ecosystem.pdf
- ssd-gpu-dma (libnvm): https://github.com/enfiskutensykkel/ssd-gpu-dma
- BaM — *GPU-Initiated On-Demand High-Throughput Storage Access* (arXiv:2203.04910):
  https://arxiv.org/pdf/2203.04910
- NVIDIA — *GPUDirect Storage*: https://developer.nvidia.com/blog/gpudirect-storage/
- SNIA — *Why does NVMe Need to Evolve for Efficient Storage Access from GPUs?*:
  https://www.snia.org/sniadeveloper/session/19283
- SNIA — *NVMe LBA Access Control for GPU-Direct Storage in AI/HPC Workloads*:
  https://www.snia.org/sniadeveloper/session/19591
- AMD — *NVMe Host Accelerator (NVMeHA)* IP:
  https://www.amd.com/en/products/adaptive-socs-and-fpgas/intellectual-property/ef-di-nvmeha.html
- iWave — *Unlocking High Speed NVMe SSD Access on FPGAs*:
  https://iwave-global.com/articles/high-speed-nvme-ssd-access-on-fpgas/
- BittWare — *FPGA-Accelerated NVMe Storage*: https://www.bittware.com/resources/nvme-storage/
- *Pandora's Box in Your SSD: The Untold Dangers of NVMe* (arXiv:2411.00439):
  https://arxiv.org/html/2411.00439v1
