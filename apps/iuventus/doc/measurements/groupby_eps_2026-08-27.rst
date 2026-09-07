GROUP BY entries-per-second, 1/2/4 SSDs
=======================================

:Date: 2026-08-27
:Firmware: ``USR_CORE_ARCH=GROUPBY``, built 2026-08-27 00:59:58, WNS +0.038 ns
:Card: Alveo U55C, PCIe Gen4 x8, DMA Iuventus with four SSD-backed queues
:Drives: four Samsung 990 PRO, one queue each

What was measured
-----------------

The GROUP BY user core reads 16 B ``{key, value}`` records straight from the SSDs
over the P2P path, sums the values per key in a 16384-entry on-chip table, and
writes the dense result back to a drive. No record ever reaches the host. The
figure of merit is **entries per second (Eps)**: records retired by the engine
per second, taken from the core's own event counter as
``TOTAL_EVENTS / (TOTAL_CYCLES x 4 ns)``. No host clock enters the rate.

Every drive holds its own 1 TiB dataset (2^31 sectors, 2^36 records) generated
from its own seed, so an N-drive run aggregates N TiB of distinct data and a
queue reading another queue's range would show up as a mismatch rather than be
masked by identical data.

Full sweeps over the whole dataset
----------------------------------

One run per queue count, reading every record on every enabled drive.

======  ==========  ================  ===========  ========  =========  ============
Queues  Data read   Records           Eps          GB/s      Wall       Bins
======  ==========  ================  ===========  ========  =========  ============
1       1 TiB       68 719 476 736    463.0 M/s    7.41      168.3 s    0 mismatches
2       2 TiB       137 438 953 472   451.5 M/s    7.22      306.2 s    0 mismatches
4       4 TiB       274 877 906 944   464.7 M/s    7.44      592.6 s    0 mismatches
======  ==========  ================  ===========  ========  =========  ============

Every run counted exactly the records its drives hold, reported ``OOR_CNT`` 0,
and produced a table matching the reference in all 16384 groups.

Repeatability
-------------

Ten repetitions per queue count over a 64 GiB window per drive.

======  ===========  =====================  ========  ========  ===================
Queues  Eps median   Range                  Spread    GB/s      Count mismatches
======  ===========  =====================  ========  ========  ===================
1       463.5 M/s    463.5 - 463.7 M/s      0.05 %    7.42      0 / 10
2       451.4 M/s    451.3 - 451.5 M/s      0.05 %    7.22      0 / 10
4       464.6 M/s    464.6 - 464.7 M/s      0.02 %    7.43      0 / 10
======  ===========  =====================  ========  ========  ===================

A 4 GiB window gives the same medians to within 0.2 %, so the rate does not
depend on how much of the dataset a run covers.

Eps does not scale with drive count
-----------------------------------

Four drives deliver what one delivers. A single 990 PRO already saturates the
DMA's read path at ~7.4 GB/s, which is the same ceiling the raw-throughput
campaign of 2026-08-25 found at 7.83 GB/s, so adding drives adds no records per
second. The engine itself is nowhere near its limit: four lanes retiring four
records per 250 MHz beat could absorb 1000 M/s, a little over twice what the
read path supplies.

The N=2 point is reproducibly ~2.5 % below N=1 and N=4 rather than between them.
The effect is far outside the 0.05 % run-to-run spread, so it is real, but it is
not explained here.

Trusting the number
-------------------

The event counter was checked against records divided by wall time, which it has
no part in: it reads 0.8-1.9 % high across the three queue counts, in the
direction expected since wall time also contains MI programming and the DONE
poll. The counter is a periodic-window counter, so a run shorter than one
4.19 ms window closes none and the rate is reported as unmeasured rather than as
zero.

Correctness
-----------

``kv_fill`` accumulates each drive's expected bins while generating its records
and writes them to a sidecar; ``groupby --verify`` reads the result table back
over an ordinary NVMe queue pair and compares it against the wrapped elementwise
sum of the participating drives' sidecars. The FPGA is not in that path, so what
is compared is the table as the drive holds it. All three full sweeps and the
earlier 4 GiB runs passed with zero mismatched groups.

Data
----

``data/full_sweep_n{1,2,4}.json`` -- the full-dataset runs.
``data/eps_windowed_64gib.json`` -- ten repetitions per queue count.
``data/eps_4gib.json`` -- the same at a 4 GiB window.
