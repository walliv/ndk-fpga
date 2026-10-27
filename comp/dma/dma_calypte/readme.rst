.. _dma_calypte:

DMA Calypte
===========

This module allows simple DMA access to the host memory over the PCI Express interface for both,
*Host-to-FPGA (H2F)* and *FPGA-to-Host (F2H)* directions.  The design was primarily focused on the
lowest latency possible.  The module contains two controllers for each direction: the F2H (formerly
named RX) and the H2F (formerly named TX) controller. These allow for the full-duplex transmission
of packet data from/to the host memory. The controllers connect to the surrounding infrastructure
using the :ref:`MFB bus<mfb_bus>`. The packet transmission is part of the Data Flow which is
distinguished from the Control Flow. The Control Flow is established using the :ref:`MI bus<mi_bus>`
that accesses internal Control and Status (C/S) registers. Each of the controllers contains multiple
virtual channels that share the same MFB bus but have separate address spaces in the host memory.
This allows for concurrent access from the host system. The block scheme of the DMA module is
provided in the following figure:

.. figure:: img/tx_calypte_block-dma_whole_alt.svg
    :align: center
    :scale: 150

    The block sheme of the DMA Calypte module and its integration into the NDK
    framework.

.. vhdl:autoentity:: DMA_CALYPTE

.. _dma_calyp_supp_pcie_configs:

Supported PCIe Configurations
-----------------------------

The design can be configured for two major PCIe IP configurations.
This corresponds to setting the input/output MFB bus
interfaces when configuring the DMA_CALYPTE entity.

#. Device: AMD UltraScale+ Architecture, Intel Avalon P-Tile

   PCI Express configuration: **Gen3 x8**

   Internal bus width: 256 bits

   Frequency: 250 MHz

   Input MFB configuration: 1,4,8,8

   Output MFB configuration: 1,1,8,32


#. Device: AMD UltraScale+ architecture, Intel Avalon P-Tile/R-Tile

   PCI Express configuration: **Gen3 x16 (AMD), Gen4 x16 (Intel)**, **Gen5 x8 (Intel)**

   Internal bus width: 512 bits

   Frequency: 250 MHz (AMD), 400 MHz (Intel)

   Input MFB configuration: 1,8,8,8

   Output MFB configuration: 2,1,8,32

Resource consumption
--------------------

The following tables show the resource utilization on the AMD Virtex UltraScale+
chip (``xcvu7p-flvb2104-2-i``) for *Gen3 x8* and *Gen3 x16* PCIe configurations.

+---------------+------------------+---------------+---------------+---------------+
|               | PCIe Gen3 x8                     | PCIe Gen3 x16                 |
+               +------------------+---------------+---------------+---------------+
|               | 16 channels      |64 channels    |16 channels    |64 channels    |
+===============+==================+===============+===============+===============+
| LUT as Logic  | 7650 (0.97%)     | 10441 (1.32%) | 16257 (2.06%) | 18571 (2.36%) |
+---------------+------------------+---------------+---------------+---------------+
| LUT as Memory | 1466 (0.37%)     | 2310 (0.59%)  | 1592 (0.40%)  | 2446 (0.62%)  |
+---------------+------------------+---------------+---------------+---------------+
| Registers     | 10156 (0.64%)    | 11614 (0.74%) | 16290 (1.03%) | 17929 (1.14%) |
+---------------+------------------+---------------+---------------+---------------+
| CARRY logic   | 141 (0.14%)      | 238 (0.24%)   | 145 (0.15%)   | 243 (0.25%)   |
+---------------+------------------+---------------+---------------+---------------+
| RAMB36 Tiles  | 32 (2.22%)       | 128 (8.89%)   | 0 (0.00%)     | 128 (8.89%)   |
+---------------+------------------+---------------+---------------+---------------+
| RAMB18 Tiles  | 8 (0.28%)        | 8 (0.28%)     | 72 (2.50%)    | 8 (0.28%)     |
+---------------+------------------+---------------+---------------+---------------+
| URAMs         | 8 (1.25%)        | 32 (5.00%)    | 8 (1.25%)     | 32 (5.00%)    |
+---------------+------------------+---------------+---------------+---------------+
| DSPs          | 4 (0.09%)        | 4 (0.09%)     | 4 (0.09%)     | 4 (0.09%)     |
+---------------+------------------+---------------+---------------+---------------+

Latency report
--------------

.. NOTE::
   Unless given explicitly, all measured values are in microseconds.

Since this module has been designed for low latency, this is our primary concern. Even though its
RTL design reaches the minimum latency, the PCI Express protocol remains the biggest contributor to
the overall latency. From our observations, the latency is also influenced by the vendor
of the CPU where Intel devices perform slightly better than AMD devices. Some PCIe IPs for FPGAs
provide a special low-latency mode such as the PCIE4 block used in *AMD UltraScale+* architecture, which
is enabled on all AMD cards whose measurements we provide. The latency is always measured as a
*Round-Trip-Time (RTT)* latency either on the path: *Host -> H2F Controller -> FPGA -> F2H Controller
-> Host (HFH)*, or *FPGA -> F2H Controller -> Host -> H2F Controller -> FPGA (FHF)*, which will be
denoted for specific results. Every time the data are looped back, either in the Host for the FHF path
or in the FPGA for the HFH path, the loopback is established with the shortest path possible (E.g., for the
HFH to directly connect *USR_TX_MFB* to the *USR_RX_MFB* interface).

AMD FPGA Gen3x8
^^^^^^^^^^^^^^^

* Card: Silicom fb2CGhh (Chip: ``xcku15p-ffve1760-2-e``)

  CPU: Intel Xeon CPU E5-2630 v4 @ 2.20GHz

  RAM: 32 GB

  PCIe configuration: Gen3x8 (low latency configuration)

* FHF latency (16384 repetitions)

  The following table summarizes the measured results. The form of a distribution function has been
  chosen as the most suitable since the measured latency values have a normal distribution across
  the set. The quantiles are labeled with a letter "P" followed by its value, meaning P1 the
  0.01-quantile, P50 the 0.5-quantile (or median), etc.

    +-------------+-------+--------+---------+---------+---------+--------+
    | Packet size |  Min  | P1-lat | P50-lat | P80-lat | P99-lat |  Max   |
    +=============+=======+========+=========+=========+=========+========+
    | 60B         | 0.796 | 0.825  | 0.842   | 0.855   | 0.892   | 24.676 |
    +-------------+-------+--------+---------+---------+---------+--------+
    | 64B         | 0.796 | 0.820  | 0.837   | 0.847   | 0.887   | 17.284 |
    +-------------+-------+--------+---------+---------+---------+--------+
    | 128B        | 0.804 | 0.831  | 0.843   | 0.855   | 0.892   | 18.768 |
    +-------------+-------+--------+---------+---------+---------+--------+
    | 256B        | 0.832 | 0.857  | 0.874   | 0.886   | 0.924   | 19.168 |
    +-------------+-------+--------+---------+---------+---------+--------+
    | 512B        | 0.900 | 0.928  | 0.939   | 0.952   | 0.990   | 18.440 |
    +-------------+-------+--------+---------+---------+---------+--------+
    | 1024B       | 1.052 | 1.078  | 1.095   | 1.105   | 1.143   | 19.640 |
    +-------------+-------+--------+---------+---------+---------+--------+
    | 1500B       | 1.228 | 1.254  | 1.271   | 1.281   | 1.324   | 18.236 |
    +-------------+-------+--------+---------+---------+---------+--------+

    .. figure:: img/latency_fb2cghh_oliver.svg
            :align: center
            :scale: 10

* HFH latency (64 B packets, 1000000 repetitions)

  822 ns (median), 1241 ns (0.99-quantile)

* HFH latency (1500 B packets, 1000000 repetitions)

  1340 ns (median), 1401 ns (0.99-quantile)

Intel FPGA Gen3x8
^^^^^^^^^^^^^^^^^

.. NOTE::
   This 8-lane PCIe configuration is not officially provided by the NDK
   framework. It has been published here to only provide a comparison with the
   equally configured AMD-based FPGA card.

* Card: Silicom FPGA SmartNIC N6010 (Chip: ``AGFB014R24A2E2V``)

  CPU: Intel Xeon CPU E5-2630 v4 @ 2.20GHz

  RAM: 32 GB

  PCIe configuration: Gen3x8

* FHF latency (16384 repetitions)

     +-------------+-------+--------+---------+---------+---------+--------+
     | Pakcet size | Min   | P1-lat | P50-lat | P80-lat | P99-lat |  Max   |
     +=============+=======+========+=========+=========+=========+========+
     | 60B         | 0.876 | 0.897  | 0.910   | 0.923   | 0.965   | 17.836 |
     +-------------+-------+--------+---------+---------+---------+--------+
     | 64B         | 0.872 | 0.890  | 0.907   | 0.921   | 0.959   | 20.972 |
     +-------------+-------+--------+---------+---------+---------+--------+
     | 128B        | 0.888 | 0.906  | 0.922   | 0.935   | 0.973   | 17.908 |
     +-------------+-------+--------+---------+---------+---------+--------+
     | 256B        | 0.920 | 0.938  | 0.954   | 0.966   | 1.006   | 18.028 |
     +-------------+-------+--------+---------+---------+---------+--------+
     | 512B        | 0.980 | 1.001  | 1.016   | 1.026   | 1.070   | 19.660 |
     +-------------+-------+--------+---------+---------+---------+--------+
     | 1024B       | 1.128 | 1.155  | 1.169   | 1.182   | 1.219   | 18.452 |
     +-------------+-------+--------+---------+---------+---------+--------+
     | 1500B       | 1.300 | 1.329  | 1.342   | 1.357   | 1.401   | 18.236 |
     +-------------+-------+--------+---------+---------+---------+--------+

    .. figure:: img/latency_n6010_oliver.svg
            :align: center
            :scale: 10

AMD FPGA Gen3x16
^^^^^^^^^^^^^^^^

* Card: Silicom fb2CGhh (Chip: ``xcku15p-ffve1760-2-e``)

  CPU: Intel Xeon CPU E5-2630 v4 @ 2.20GHz

  RAM: 32 GB

  PCIe configuration: Gen3x16

* FHF latency (16384 repetitions)

    +-------------+-------+--------+---------+---------+---------+--------+
    | Packet size |  Min  | P1-lat | P50-lat | P80-lat | P99-lat |  Max   |
    +=============+=======+========+=========+=========+=========+========+
    |   60B       | 0.800 | 0.819  | 0.839   | 0.856   | 0.894   | 17.828 |
    +-------------+-------+--------+---------+---------+---------+--------+
    |   64B       | 0.792 | 0.814  | 0.830   | 0.846   | 0.886   | 17.752 |
    +-------------+-------+--------+---------+---------+---------+--------+
    |   128B      | 0.804 | 0.819  | 0.834   | 0.845   | 0.885   | 18.444 |
    +-------------+-------+--------+---------+---------+---------+--------+
    |   256B      | 0.828 | 0.839  | 0.857   | 0.872   | 0.910   | 18.856 |
    +-------------+-------+--------+---------+---------+---------+--------+
    |   512B      | 0.880 | 0.898  | 0.910   | 0.923   | 0.959   | 17.832 |
    +-------------+-------+--------+---------+---------+---------+--------+
    |   1024B     | 0.984 | 1.000  | 1.016   | 1.027   | 1.070   | 18.020 |
    +-------------+-------+--------+---------+---------+---------+--------+
    |   1500B     | 1.076 | 1.094  | 1.114   | 1.133   | 1.184   | 20.216 |
    +-------------+-------+--------+---------+---------+---------+--------+

    .. figure:: img/latency_x16_fb2cghh_oliver.svg
            :align: center
            :scale: 10

Intel FPGA Gen4x16
^^^^^^^^^^^^^^^^^^

* Card: Silicom FPGA SmartNIC N6010 (Chip: ``AGFB014R24A2E2V``)

* CPU: Intel Xeon Gold 6342 CPU @ 2.80GHz

* RAM: 128 GB

* PCIe configuration: Gen4x16

* FHF latency (16384 repetitions)

    +-------------+-------+--------+---------+---------+---------+--------+
    | Packet size |  Min  | P1-lat | P50-lat | P80-lat | P99-lat |  Max   |
    +=============+=======+========+=========+=========+=========+========+
    | 60B         | 0.965 | 1.049  | 1.069   | 1.084   | 1.116   | 4.240  |
    +-------------+-------+--------+---------+---------+---------+--------+
    | 64B         | 0.968 | 1.044  | 1.066   | 1.082   | 1.118   | 3.822  |
    +-------------+-------+--------+---------+---------+---------+--------+
    | 128B        | 0.968 | 1.052  | 1.073   | 1.087   | 1.112   | 3.645  |
    +-------------+-------+--------+---------+---------+---------+--------+
    | 256B        | 1.030 | 1.068  | 1.087   | 1.101   | 1.128   | 3.420  |
    +-------------+-------+--------+---------+---------+---------+--------+
    | 512B        | 1.052 | 1.094  | 1.112   | 1.124   | 1.148   | 3.717  |
    +-------------+-------+--------+---------+---------+---------+--------+
    | 1024B       | 1.115 | 1.145  | 1.162   | 1.176   | 1.224   | 3.675  |
    +-------------+-------+--------+---------+---------+---------+--------+
    | 1500B       | 1.177 | 1.223  | 1.264   | 1.356   | 1.408   | 4.765  |
    +-------------+-------+--------+---------+---------+---------+--------+

    .. figure:: img/latency_x16_n6010_mourvedre.svg
            :align: center
            :scale: 10

* HFH latency (64 B packets, 1000000 repetitions)

  866 ns (median), 1340 ns (0.99-quantile)

* HFH latency (1500 B packets, 1000000 repetitions)

  1292 ns (median), 2241 ns (0.99-quantile)

Comparison of FPGA vendors
^^^^^^^^^^^^^^^^^^^^^^^^^^

* Cards: Silicom FPGA SmartNIC N6010 and Silicom fb2CGhh

  CPU: Intel Xeon CPU E5-2630 v4 @ 2.20GHz

  RAM: 32 GB

  PCIe configuration: Gen3x8

* FHF latency (16384 repetitions)

  The graph beneath the table picks only some of the packet lengths showed in the table.

    +-------------+-------+--------+---------+---------+---------+--------+
    | Packet size |  Min  | P1-lat | P50-lat | P80-lat | P99-lat |  Max   |
    +=============+=======+========+=========+=========+=========+========+
    | amd_60B     | 0.796 | 0.825  | 0.842   | 0.855   | 0.892   | 24.676 |
    +-------------+-------+--------+---------+---------+---------+--------+
    | intel_60B   | 0.876 | 0.897  | 0.910   | 0.923   | 0.965   | 17.836 |
    +-------------+-------+--------+---------+---------+---------+--------+
    | amd_64B     | 0.796 | 0.820  | 0.837   | 0.847   | 0.887   | 17.284 |
    +-------------+-------+--------+---------+---------+---------+--------+
    | intel_64B   | 0.872 | 0.890  | 0.907   | 0.921   | 0.959   | 20.972 |
    +-------------+-------+--------+---------+---------+---------+--------+
    | amd_128B    | 0.804 | 0.831  | 0.843   | 0.855   | 0.892   | 18.768 |
    +-------------+-------+--------+---------+---------+---------+--------+
    | intel_128B  | 0.888 | 0.906  | 0.922   | 0.935   | 0.973   | 17.908 |
    +-------------+-------+--------+---------+---------+---------+--------+
    | amd_256B    | 0.832 | 0.857  | 0.874   | 0.886   | 0.924   | 19.168 |
    +-------------+-------+--------+---------+---------+---------+--------+
    | intel_256B  | 0.920 | 0.938  | 0.954   | 0.966   | 1.006   | 18.028 |
    +-------------+-------+--------+---------+---------+---------+--------+
    | amd_512B    | 0.900 | 0.928  | 0.939   | 0.952   | 0.990   | 18.440 |
    +-------------+-------+--------+---------+---------+---------+--------+
    | intel_512B  | 0.980 | 1.001  | 1.016   | 1.026   | 1.070   | 19.660 |
    +-------------+-------+--------+---------+---------+---------+--------+
    | amd_1024B   | 1.052 | 1.078  | 1.095   | 1.105   | 1.143   | 19.640 |
    +-------------+-------+--------+---------+---------+---------+--------+
    | intel_1024B | 1.128 | 1.155  | 1.169   | 1.182   | 1.219   | 18.452 |
    +-------------+-------+--------+---------+---------+---------+--------+
    | amd_1500B   | 1.228 | 1.254  | 1.271   | 1.281   | 1.324   | 18.236 |
    +-------------+-------+--------+---------+---------+---------+--------+
    | intel_1500B | 1.300 | 1.329  | 1.342   | 1.357   | 1.401   | 18.236 |
    +-------------+-------+--------+---------+---------+---------+--------+

    .. figure:: img/fb2cghh_n6010_compare.svg
            :align: center
            :scale: 10

Verification
------------

``cocotb/`` holds a cocotb bench of the whole ``DMA_CALYPTE`` with RX and TX traffic running at
the same time. It ports the stimulus, models, scoreboards and properties of the RX and TX UVM benches
(``comp/rx/uvm``, ``comp/tx/uvm``) and adds a check of the RQ merger. The combinations of
``cocotb/ver_settings.py`` cover every enabled combination of both UVM ``ver_settings.py``, each with
the cocotb tests its ``TEST_FILTER`` selects; a Jenkins build runs two of them at random.

.. code-block:: sh

    cd comp/dma/dma_calypte/cocotb
    make                                          # the "default" combination, in Questa or with SIM=nvc in nvc
    make suite                                    # every combination, in parallel nvc runs through pytest-xdist
    python3 ../../../../build/scripts/multi_ver/multi_ver_cocotb.py ver_settings.py -r 100  # all, one after another
    make sim-run CONFIG=default TEST=run_dma_calypte_speed_test
    make suite SUITE_REPEAT=10                    # every shard ten times with random seeds
    make sim-run CONFIG=2reg TEST=run_dma_calypte_test RANDOM_SEED=1101 WAVES=1   # one seed, with waves

Every combination is elaborated in the suite (``test_elaboration``), but the Intel ones (``intel_*``) run
there only when selected with ``CONFIG``: nvc has no usable model of the Agilex DSP atom behind ``DSP_COMPARATOR``
(encrypted) nor of ``altera_syncram`` (SystemVerilog only), so their pointer comparators and 1-region
transaction buffer do not work there. ``NVC_LIBPATH`` puts a directory of substitute simulation
libraries ahead of the installed ones in every nvc step. The Intel memories and DSP blocks are
exercised by the RX and TX UVM benches and by the Intel combinations of this bench under Questa with the
Altera simulation libraries.

The stop logic of both directions depends on the latency of ``DSP_COMPARATOR``. On every vendor it is
set by ``INPUT_REGS_EN`` alone: an input register stage when it is true, plus one output register
(``CMP_DSP`` registers on AMD, the input and output registers of the Agilex and Stratix 10 DSP atoms,
or the behavioural branch). The testbenches in ``comp/base/dsp/dsp_comparator*/sim`` check every
branch against one reference with this delay, so the AMD configurations exercise the same comparator
timing as an Intel device.

Checked: every RX RQ write against the RX DMA model (field by field, MPS and 4 KiB page rules), every
USR_TX packet and its metadata against the TX DMA model, every pointer update of both directions
against the pointer-updater model, the merger output against its two inputs, the per-channel packet
and byte counters, MFB rules on all MFB interfaces, the frame layout of the RQ streams, the
pointer-updater request interfaces and the RTL's PSL assertions. Every test also checks that an RX
stop is acknowledged only with the channel's HDP/HHP equal to its SDP/SHP, that neither moves again
before the channel's next start request, and that every RX pointer update on ``PCIE_RQ_MFB`` covers
only data blocks and DMA headers whose writes left before it; for each violation, and for each stop
acknowledged with a write of the channel still on its way, the log names where that write was (merger
input 0, the RX DMA RQ output, the header insertor or the header manager FIFO) and how late it left.
Stimulus size knobs:
``RX_SIM_TIME_US``, ``RX_BATCH_MIN``/``RX_BATCH_MAX``, ``TX_TRANSACTIONS_MIN``/``TX_TRANSACTIONS_MAX``.

``run_rx_stop_at_eof_test`` and ``run_rx_stop_at_sof_test`` sweep RX channel stops and starts cycle
by cycle against the end and the start of a single packet with no other RX traffic. Every request
must complete, and the sweep must hit the cycle in which the header manager takes the request as that
packet's EOF passes (its header is decided); with 8 or more channels a start must also meet a pointer
write before the software manager acknowledges it. Passes are added, re-centred on the least delayed
hazard offset measured, until every such cycle was hit (``CALYPTE_SWEEP_PASSES_MAX``, 32). Once a
channel reports stopped, no RQ write may target its buffers, no block or DMA header of it may get an
address, and the last pointer update sent to the host must carry the final hardware pointers. Without
the header manager's request queue the tests take a stop on ``STOP_REQ_VLD`` and a start on
``START_REQ_VLD`` in its channel FSM's ``S_IDLE``.

``run_rx_start_discard_test`` sweeps only starts, against the header decision of a 2 to 4 KiB packet. A
packet whose header is decided with the old status is dropped, and the start may complete only after its
end: the channel's discarded packets counter, sampled as soon as STATUS reports the start and again once
the packet left, must not change.

The directed RX tests drive the software as the ndp tools do through libnfb and the ndp kernel driver
(``cocotb/rx_driver.py``): each queue runs in kernel or userspace mode, picked per queue and logged;
consumers find packets by the DMA header valid flag and write SDP | SHP as one 64-bit write (two
32-bit MI writes) per burst, or in userspace mode only after 32 packets; a stop is the driver's loop of
SDP | SHP from the update buffer (0 until the first stop update), CONTROL = STOP, SDP and SHP again and
up to 101 STATUS reads. ``run_dma_calypte_test`` and ``run_dma_calypte_speed_test`` keep the UVM
register sequence.

``run_rx_full_resume_test``, ``run_rx_full_stop_test`` and ``run_rx_full_idle_stop_test`` fill the
data or header ring of a channel X so that its next request is held, which holds every channel's
requests behind it, and stop another channel c: with a packet of c queued behind X and X then freed by
its consumer, with X stopped as well by the stop loop, or with c idle. Every stop must complete and
keep the stop contract; grey-box counters prove the hold and the queueing.
``run_rx_full_resume_no_timeout_test`` repeats the first with ``R_UPDATE_TIMEOUT`` 0 on every channel,
so pointers of c that moved after its stop sent them reach the host only if the stop sends them again
without a timeout.

``run_rx_stale_stop_test`` stops a just started channel against its smallest packet swept cycle by
cycle so that the packet's pointer write lands inside the stop comparator latency on the channel's
round-robin slot; with up to 8 channels that cycle must be hit. ``run_rx_stale_sdp_test`` stops one
channel whose consumer moved SDP close to the ring end while a long packet of it enters: the stop loop's
stale SDP write fills the channel's own ring with that packet in progress. ``run_rx_ndptool_test``
models ndptool's exit: all RX queues run with their consumers under random traffic, then every queue
stops at once after its consumer while traffic continues; three rounds.

``run_rx_stop_livelock_test`` (32 and 16 channels) stops an idle channel while the header manager
waits for the EOF of another channel's dropped packet to finish that channel's start, so stepping that
EOF by one cycle per stop moves the stop's first pointer update dispatch over every phase of the
channel's round-robin slot. ``R_UPDATE_TIMEOUT`` is set so that the re-dispatch period, measured as
timeout + 1 + dispatch length, divides the channel count. Every stop must be acknowledged within
4 x channels x period cycles of its pointers matching, and one dispatch must fall on the slot with
the pointers matching.

Local Subcomponents
-------------------

.. toctree::
   :maxdepth: 1

   comp/rx/readme
   comp/tx/readme

Maintainers
-----------

* Vladislav Valek <valekv@cesnet.cz>
