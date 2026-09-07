.. README.rst: DMA Iuventus host-side test and measurement tooling
   Copyright (C) 2025 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
   Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
   SPDX-License-Identifier: CC-BY-4.0

==========================================
DMA Iuventus host-side tooling
==========================================

Scripts here drive the FPGA's USER_CORE test generator over ``nfb`` while ``fzc``
(``fpga_zero_copy``) holds the P2P NVMe queues open. ``fzc`` sets up the SQ/CQ and buffers and
enables the design; it does **not** generate traffic itself.

Prerequisites
=============

* A Python environment with ``nfb``, ``fdt``, ``numpy``, ``ofm`` and ``cocotbext.ofm``.
* ``fzc`` built from the SPDK checkout.
* The SSDs and the FPGA's PF1 bound to ``uio_pci_generic`` with bus-master set.
* For the stall profile (``--profile``): firmware built with **PROFILE_EN**. Without it every profiling
  counter reads zero.

.. warning::

   Never run ``nfb-*`` / ``ndp-*`` tools with ``sudo`` -- they work as a normal user. ``sudo`` is
   only for ``setpci``, the uio binds, and ``fzc`` (SPDK hugepages).

.. warning::

   Stop ``fzc`` with **SIGINT only**. Any other kill can leave operations in flight whose pages are
   never freed; the design then cannot complete its stop sequence and needs a firmware reload.
   After a clean teardown the free-page counters should read full again.

Files
=====

``iuventus_rw_test.py``
    The main CLI. Read/write dispatch, the throughput sweep (``-t``), the latency measurement
    (``-l``), plots and tables.

``iuventus_reg_status.py``
    Register dump / status, including ``--rst``.

``integ_run.py``
    FPGA-driven SSD write/read-back integrity self-test.

Throughput
==========

The built-in sweep walks mode x addressing x request size (0..255 LBAs) in one invocation and is
the preferred entry point -- prefer it over ad-hoc scripts:

.. code-block:: bash

   # one fzc must already be running per queue
   python iuventus_rw_test.py -d 0 -t --queues 1 \
       --throughput-results-file ~/temp/throughput_q1.json

Every point is measured on a **contiguous** stream (``contig_test`` is set on both the read and
write paths). Plots are written to the current directory with a per-run timestamp, so repeated
sweeps accumulate instead of overwriting each other. Run into a scratch directory and promote only
the results worth keeping into ``doc/measurements/`` under the dated convention used there.

Replot an existing result set without touching hardware:

.. code-block:: bash

   python iuventus_rw_test.py -d 0 --throughput-from-file \
       --throughput-results-file ~/temp/throughput_q1.json

Latency
=======

.. code-block:: bash

   python iuventus_rw_test.py -d 0 -l rd 2000 rand 7   # TYPE ITERATIONS ADDRESSING LBA_NUM

Latency mode drives **one command in flight** regardless of queue depth: ``LATENCY_METER`` pairs
starts to completions positionally and carries no tag, so any concurrency would pair a completion
with the wrong start. The generator is throttled by ``lat_meas_mode`` (TST_SEQ_RAND_SEL bit 4),
armed and confirmed before traffic starts and cleared afterwards. The queue itself stays at QD64;
only issue is serialised. This is therefore a QD1 latency figure and must not be compared against
the streaming throughput numbers above.

``ITERATIONS`` must be >= 1000.

Stall profile
=============

.. code-block:: bash

   python iuventus_rw_test.py -d 0 --profile --queues 1 \
       --profile-results-file ~/temp/profile_q1.json

The five classes are ``DISP_SQ`` / ``ALLOC_WAIT`` / ``DISP_TAG`` / ``DATA_WAIT`` / ``BUSY``. They
do **not** partition a cycle -- an idle cycle sets no bit and is never counted -- so percentages
are shares of *classified* cycles, i.e. of the time the DMA had work in hand. That is the
quantity that locates a bottleneck.

``DATA_WAIT`` is reachable only on the write path, so a read-only workload must show it at zero.

Sweeping several SSD counts
===========================

Bring up one ``fzc`` per SSD, then pass ``--queues N``. Repeat per SSD count, tearing ``fzc`` down
with SIGINT in between. ``-t`` and ``--profile`` both take ``--queues``.

.. note::

   The ``-t`` sweep walks 9 request sizes x 2 modes x 2 addressings, so it takes minutes per SSD
   count. If you wrap it in a timeout, make it generous -- a short one truncates the sweep silently
   and leaves a partial dataset that still looks like a successful run.

Reading device state
====================

``iuventus_reg_access.py`` (``DMAIuventusRegAccess``) is the supported way to read the IP's
counters -- prefer it over raw ``nfb-bus`` offsets. Beyond the completion counters it exposes
``rd_pages_free`` / ``wr_pages_free``, ``drain_admit`` / ``drain_fence_wait`` / ``drain_hbm_wait``,
and ``fence_clip`` / ``fence_afull_cycles``.

Those diagnose a drain-fence wedge; see the DMA core's own documentation for the diagnostic
recipe. ``rd_pages_free`` at 0 on its own is normal under load.

Generating the documentation plots
==================================

``doc/measurements/`` holds dated PNG + RST pairs and the scripts that render them
(``plot_throughput.py``, ``plot_lba_sweep.py``, ``plot_stall_profile.py``). Each has a ``DATE`` and
a ``DATA`` block near the top: paste in the new numbers, update ``DATE`` and ``CONFIG``, run it,
and keep the previous dated files so runs stay comparable.

State the firmware configuration in ``CONFIG``. Results from the URAM and HBM buffer builds are
**not** interchangeable, and consecutive dates otherwise read as a progression when they are
measuring different designs.
