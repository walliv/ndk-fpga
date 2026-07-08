<!--
README.md: DMA Iuventus QD16 P2P throughput characterization
Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>

SPDX-License-Identifier: CC-BY-4.0
-->

# DMA Iuventus QD16 P2P throughput — SK hynix (2026-07-08)

Throughput of the Iuventus queue-depth-16 multiple-outstanding design driving NVMe peer-to-peer I/O
against an **SK hynix PC611** (PCIe Gen3 x4, ~3.9 GB/s link) on an Alveo U55C. Measured three ways —
which give three very different answers, so the method matters.

## Results (peak, GBps)

| Source | Read | Write | What it measures |
|---|---|---|---|
| FPGA **MFB speed meter** (`iuventus_rw_test.py -t`) | ~14.8 | ~9.0 | **Overstated** — internal WRBUFF→user_core drain (re-reads buffered data); exceeds the drive's link |
| FPGA **completion-based** (`fpga_cpl_throughput.py`) | ~0.79 | ~1.09 | **Effective** P2P throughput (actual NVMe completions) |
| host **`spdk_nvme_perf`** | ~3.47 | ~2.76 | The drive's real capability |

**Conclusion:** the FPGA P2P datapath is the bottleneck (~0.8 GB/s), **~4x below** what the drive can
do (~3.5 GB/s, host). The MFB speed meter overstates the effective rate by ~10-19x and must **not** be
reported as P2P throughput. Likely limiters: op_ctrl's dispatch/completion loop and the single shared
WRBUFF-drain MFB bus. All runs had 0 unsuccessful completions (a rate limit, not errors). Sub-finding:
the sequential-address generator is ~10x slower than random at 512 B (`rd_seq` 59k IOPS vs `rd_rand`
618k) — a read-path optimization target.

## Files
- `fpga_mfb_meter.json` — FPGA MFB speed-meter sweep (`throughput_bps`), from `iuventus_rw_test.py -t`.
- `fpga_completion.json` — FPGA completion-based sweep (`throughput_gbps`, `completions`).
- `host_spdk_nvme_perf.json` — host `spdk_nvme_perf` sweep (`throughput_bps`, `iops`).
- `fpga_effective_vs_host.png` — three-way comparison, log-y (the key figure).
- `fpga_mfb_all_modes.png` — the FPGA `-t` GBps-vs-LBA plot (MFB meter only).
- `fpga_vs_host_linear.png` — FPGA MFB meter vs host, linear-y.

All sweeps: QD16, request sizes 1..256 LBAs (512 B .. 128 KiB), read/write x sequential/random, 3 s/point.

## Reproduce
- FPGA MFB meter: run fzc on the hynix (see the `fzc-run` skill), then
  `iuventus_rw_test.py -d /dev/nfbN -t`.
- FPGA effective: with fzc running, `fpga_cpl_throughput.py <nfb-index> <secs>`.
- host `spdk_nvme_perf` on the hynix requires: `nvme format /dev/nvme0n1 -s1` (rebind uio->nvme first),
  the **FPGA design disabled** (`CONTROL=0` — an enabled design conflicts on the drive's queues ->
  `cpl does not map to outstanding cmd`), and **`-D`** (SQ in host memory, not the drive CMB ->
  fixes `sq_tail passing sq_head`). Then e.g.
  `spdk_nvme_perf -q 16 -o <bytes> -w <read|randread|write|randwrite> -t 3 -c 0x1 -D -r 'trtype:PCIe traddr:0000:61:00.0'`.
