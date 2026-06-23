#!/usr/bin/env python3
# hbm_h2c_write_test.py: Hardware bring-up test driver for the H2C DMA Hyperion WRITE path (host → HBM)
# Copyright 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import logging
import random
import sys
from argparse import ArgumentParser
from time import sleep

import nfb
from ofm.comp.dma.hyperion import H2CDMAHyperionRegAccess, HBMWriteWindow

log = logging.getLogger(__name__)


def discover(dev):
    """Build the H2CDMAHyperionRegAccess singleton and a dict of HBMWriteWindow keyed by channel."""
    reg = H2CDMAHyperionRegAccess(dev=dev)

    buf_nodes = dev.fdt_get_compatible(HBMWriteWindow.DT_COMPATIBLE)
    n = len(buf_nodes)
    log.info("Discovered %d H2C HBM buffer window(s)", n)

    windows = {}
    for i, node in enumerate(buf_nodes):
        channel = node.get_property("channel").value
        windows[channel] = HBMWriteWindow(dev=dev, index=i)
        log.debug("Buffer node index=%d → channel=%d", i, channel)

    return reg, windows, n


def within(actual, expected, rel_tol=0.05, abs_tol=64):
    """Return True when |actual - expected| is within rel_tol fraction or abs_tol bytes."""
    tolerance = max(abs_tol, expected * rel_tol)
    return abs(actual - expected) <= tolerance


def poll_counter(getter, tries=10, delay=0.01):
    """Re-read a counter getter up to `tries` times if it returns 0 (covers in-fabric propagation latency).

    Note: get_statistics() already pulses SAMPLE, so this helper is for cases
    where a raw property is polled directly.
    """
    for _ in range(tries):
        val = getter()
        if val != 0:
            return val
        sleep(delay)
    return 0


def scenario_a(reg, windows, n):
    """Write 64 random bytes to channel 0 at offset 0; verify basic PCIe and HBM write activity."""
    log.info("--- Scenario A: 64-byte write to channel 0 offset 0 ---")
    data = random.randbytes(64)

    reg.rst_cntrs()
    windows[0].write(0, data)
    s = reg.get_statistics()
    log.debug("Scenario A stats:\n%s", s)

    assert s.pcie_wr_reqs > 0, f"Expected pcie_wr_reqs > 0, got {s.pcie_wr_reqs}"
    assert s.hbm_wr_trs > 0, f"Expected hbm_wr_trs > 0, got {s.hbm_wr_trs}"
    assert within(s.hbm_wr_bytes, 64), \
        f"hbm_wr_bytes={s.hbm_wr_bytes} not within tolerance of 64"
    assert s.pcie_rd_reqs <= 4, \
        f"Pure write path: expected pcie_rd_reqs <= 4, got {s.pcie_rd_reqs}"

    log.info("Scenario A PASSED")


def scenario_b(reg, windows, n):
    """Write increasing sizes to channel 0; verify byte counts are monotonically non-decreasing."""
    log.info("--- Scenario B: multi-size write to channel 0 ---")
    sizes = [4096, 8192, 16384]
    prev_bytes = -1

    for size in sizes:
        data = random.randbytes(size)

        reg.rst_cntrs()
        windows[0].write(0, data)
        s = reg.get_statistics()
        log.debug("Scenario B size=%d stats:\n%s", size, s)

        assert within(s.hbm_wr_bytes, size), \
            f"size={size}: hbm_wr_bytes={s.hbm_wr_bytes} not within tolerance"
        assert s.hbm_wr_bytes >= prev_bytes, \
            f"size={size}: hbm_wr_bytes={s.hbm_wr_bytes} decreased from previous {prev_bytes}"
        assert s.pcie_rd_reqs <= 4, \
            f"size={size}: pure write path: expected pcie_rd_reqs <= 4, got {s.pcie_rd_reqs}"

        prev_bytes = s.hbm_wr_bytes

    log.info("Scenario B PASSED")


def scenario_c(reg, windows, n):
    """Write 128 bytes to every discovered channel; verify aggregate HBM write activity.

    Note: per-channel independence is NOT observable via the single aggregate control node —
    the counters accumulate writes across all channels into one sum.
    """
    log.info("--- Scenario C: 128-byte write to all %d channels ---", n)
    data = random.randbytes(128)

    reg.rst_cntrs()
    for channel, window in windows.items():
        window.write(0, data)
        log.debug("Wrote 128 bytes to channel %d", channel)

    s = reg.get_statistics()
    log.debug("Scenario C stats:\n%s", s)

    assert s.hbm_wr_trs > 0, f"Expected aggregate hbm_wr_trs > 0, got {s.hbm_wr_trs}"
    assert within(s.hbm_wr_bytes, 128 * n), \
        f"Aggregate hbm_wr_bytes={s.hbm_wr_bytes} not within tolerance of {128 * n}"
    assert s.pcie_rd_reqs <= 4, \
        f"Pure write path: expected pcie_rd_reqs <= 4, got {s.pcie_rd_reqs}"

    log.info("Scenario C PASSED")


def scenario_d(reg, windows, n):
    """Write 256 bytes to channel 0 at a non-zero offset (0x1000); verify write activity."""
    log.info("--- Scenario D: 256-byte write to channel 0 at offset 0x1000 ---")
    data = random.randbytes(256)

    reg.rst_cntrs()
    windows[0].write(0x1000, data)
    s = reg.get_statistics()
    log.debug("Scenario D stats:\n%s", s)

    assert s.hbm_wr_trs > 0, f"Expected hbm_wr_trs > 0, got {s.hbm_wr_trs}"
    assert within(s.hbm_wr_bytes, 256), \
        f"hbm_wr_bytes={s.hbm_wr_bytes} not within tolerance of 256"
    assert s.pcie_rd_reqs <= 4, \
        f"Pure write path: expected pcie_rd_reqs <= 4, got {s.pcie_rd_reqs}"

    log.info("Scenario D PASSED")


SCENARIOS = {
    "a": scenario_a,
    "b": scenario_b,
    "c": scenario_c,
    "d": scenario_d,
}


def main():
    parser = ArgumentParser(
        description="Hardware bring-up test driver for the H2C DMA Hyperion WRITE path (host → HBM)",
    )

    access = parser.add_argument_group("card access arguments")
    access.add_argument(
        "-d", "--device",
        default=nfb.libnfb.Nfb.default_dev_path,
        metavar="device",
        help="Path to the NFB device (default: %(default)s)",
    )

    run_args = parser.add_argument_group("test control")
    run_args.add_argument(
        "-v", "--verbose",
        action="count",
        default=0,
        help="Increase verbosity (use -v for DEBUG output)",
    )
    run_args.add_argument(
        "-s", "--scenario",
        choices=list(SCENARIOS.keys()) + ["all"],
        default="all",
        metavar="{" + ",".join(list(SCENARIOS.keys()) + ["all"]) + "}",
        help="Scenario(s) to run (default: all)",
    )

    args = parser.parse_args()

    log_level = logging.DEBUG if args.verbose > 0 else logging.INFO
    logging.basicConfig(
        level=log_level,
        format="%(asctime)s %(levelname)-8s %(name)s: %(message)s",
    )

    dev = nfb.open(args.device)
    reg, windows, n = discover(dev)

    if args.scenario == "all":
        selected = list(SCENARIOS.keys())
    else:
        selected = [args.scenario]

    any_failed = False
    for name in selected:
        fn = SCENARIOS[name]
        try:
            fn(reg, windows, n)
            log.info("PASS: scenario_%s", name)
        except AssertionError as exc:
            log.error("FAIL: scenario_%s — %s", name, exc)
            any_failed = True

    sys.exit(1 if any_failed else 0)


if __name__ == "__main__":
    main()
