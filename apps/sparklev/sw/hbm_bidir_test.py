#!/usr/bin/env python3
# hbm_bidir_test.py: Bidirectional HBM verification — write via H2C BAR2, read back via C2H reader → RX DMA
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import logging
import random
import sys
import time
from argparse import ArgumentParser

import nfb
from ofm.comp.dma.hyperion import C2HHBMReaderRegAccess
from ofm.comp.dma.hyperion import HBMWriteWindow

log = logging.getLogger(__name__)


# Channel geometry constants
# HBM address stride per C2H channel: bits [33:31] → 2 GB
_HBM_CH_STRIDE = 0x80000000          # 2 GiB per channel

# Number of RX DMA channels exposed by the current RTL build
NUM_RX_CH = 8

# Maximum individual DMA packet size accepted by Calypte
DMA_PKT_SIZE_MAX = 16 * 1024


def parse_channel_list(spec: str) -> list[int]:
    """Parse a comma/range channel specification such as ``0-7`` or ``0,2,4-6``."""
    channels = []
    for part in spec.split(","):
        part = part.strip()
        if "-" in part:
            lo, hi = part.split("-", 1)
            channels.extend(range(int(lo), int(hi) + 1))
        else:
            channels.append(int(part))
    return channels


# ---------------------------------------------------------------------------
# Positive per-channel scenario
# ---------------------------------------------------------------------------

def scenario_bidir_channel(
    reader: C2HHBMReaderRegAccess,
    dev,
    ch: int,
    size: int,
    device_path: str,
) -> bool:
    """Write a random pattern to HBM for channel *ch*, read it back, compare.

    Returns True on PASS, False on FAIL (never raises — caller logs the result).
    """
    hbm_addr = ch * _HBM_CH_STRIDE

    log.info("--- Channel %d: hbm_addr=0x%010x  size=%d B ---",
             ch, hbm_addr, size)

    pattern = random.randbytes(size)
    log.debug("Channel %d: pattern first 16 bytes: %s", ch, pattern[:16].hex())

    # 1. Open RX queue and arm it BEFORE triggering the C2H read so the DMA
    #    descriptor ring is ready when the first packet arrives.
    rxq = dev.ndp.rx[ch]
    rxq.start()
    rxq.reset_stats()

    # 2. Write the pattern into HBM via a direct mmap of BAR2.
    win = HBMWriteWindow(dev, index=ch * 4, device_path=device_path)
    win.write(0, pattern)
    win.close()
    log.debug("Channel %d: H2C write complete", ch)

    # 3. Trigger the C2H reader.
    try:
        reader.read(hbm_addr, size)
    except RuntimeError as exc:
        log.error("FAIL channel %d: reader.read() raised unexpectedly: %s", ch, exc)
        return False

    if not reader.done:
        log.error("FAIL channel %d: reader.done is False after read()", ch)
        return False
    if reader.error:
        log.error("FAIL channel %d: reader.error is True after read()", ch)
        return False

    log.debug("Channel %d: C2H read done; stats:\n%s", ch, reader.get_statistics())

    # 4. Collect received bytes from the RX DMA channel.
    #    One read normally produces one DMA frame, but be robust to fragmentation.
    received = bytearray()
    deadline = time.monotonic() + 2.0

    while len(received) < size and time.monotonic() < deadline:
        frames = rxq.recv(cnt=1, timeout=0.1)
        for frame in frames:
            received.extend(frame)
            log.debug("Channel %d: got frame %d B (total so far %d B)",
                      ch, len(frame), len(received))

    rx_stats = rxq.read_stats()
    log.debug("Channel %d: RX stats: %s", ch, rx_stats)

    if len(received) < size:
        log.error(
            "FAIL channel %d: only %d of %d bytes received within deadline; "
            "rx_stats=%s  reader=%s",
            ch, len(received), size, rx_stats, reader.get_statistics(),
        )
        return False

    received_cmp = bytes(received[:size])
    if received_cmp != pattern:
        # Find first differing byte for a useful diagnostic.
        mismatch_offset = next(
            i for i, (a, b) in enumerate(zip(received_cmp, pattern)) if a != b
        )
        log.error(
            "FAIL channel %d: data mismatch at offset %d "
            "(received 0x%02x, expected 0x%02x); "
            "rx_stats=%s  reader=%s",
            ch, mismatch_offset,
            received_cmp[mismatch_offset], pattern[mismatch_offset],
            rx_stats, reader.get_statistics(),
        )
        return False

    log.info("PASS channel %d", ch)
    return True


# ---------------------------------------------------------------------------
# Negative / range-check scenario
# ---------------------------------------------------------------------------

def scenario_negative(reader: C2HHBMReaderRegAccess) -> bool:
    """Verify that out-of-range and boundary-crossing reads are rejected.

    Returns True when all sub-cases behave as expected.
    """
    log.info("--- Negative test: range checks ---")
    all_ok = True

    # Sub-case 1: 17 GB request (> 16 GB HBM) starting at address 0.
    req_cnt_before = reader.req_cnt
    try:
        reader.read(0, 17 * 1024 ** 3)
        log.error("FAIL negative sub-case 1: read() did not raise for 17 GB request")
        all_ok = False
    except RuntimeError as exc:
        log.debug("Negative sub-case 1: got expected RuntimeError: %s", exc)
        if not reader.range_err:
            log.error("FAIL negative sub-case 1: range_err not set after rejection")
            all_ok = False
        if reader.busy:
            log.error("FAIL negative sub-case 1: reader still busy after rejection")
            all_ok = False
        req_cnt_after = reader.req_cnt
        if req_cnt_after != req_cnt_before:
            log.error(
                "FAIL negative sub-case 1: req_cnt changed from %d to %d "
                "— rejected request must not increment counter",
                req_cnt_before, req_cnt_after,
            )
            all_ok = False
        if all_ok:
            log.info("PASS negative sub-case 1: 17 GB read correctly rejected")

    # Sub-case 2: 2 GB straddle — starts near the 2 GB boundary, crosses it.
    # addr=0x7FFF0000 + size=0x20000 = 0x8001_0000 (> 0x8000_0000).
    req_cnt_before = reader.req_cnt
    try:
        reader.read(0x7FFF0000, 0x20000)
        log.error("FAIL negative sub-case 2: read() did not raise for 2 GB straddle")
        all_ok = False
    except RuntimeError as exc:
        log.debug("Negative sub-case 2: got expected RuntimeError: %s", exc)
        if not reader.range_err:
            log.error("FAIL negative sub-case 2: range_err not set after rejection")
            all_ok = False
        if reader.busy:
            log.error("FAIL negative sub-case 2: reader still busy after rejection")
            all_ok = False
        req_cnt_after = reader.req_cnt
        if req_cnt_after != req_cnt_before:
            log.error(
                "FAIL negative sub-case 2: req_cnt changed from %d to %d "
                "— rejected request must not increment counter",
                req_cnt_before, req_cnt_after,
            )
            all_ok = False
        if all_ok:
            log.info("PASS negative sub-case 2: 2 GB straddle correctly rejected")

    return all_ok


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    parser = ArgumentParser(
        description=(
            "Bidirectional HBM verification: write via H2C BAR2 window, "
            "read back via C2H HBM reader → RX DMA Calypte, compare."
        ),
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
        help="Increase verbosity (-v for DEBUG output)",
    )
    run_args.add_argument(
        "-s", "--channels",
        default="0-7",
        metavar="CHANNELS",
        help=(
            "Comma/range list of RX DMA channels to exercise "
            "(e.g. 0-7, 0,2,4-6; default: %(default)s)"
        ),
    )
    run_args.add_argument(
        "--size",
        type=int,
        default=4096,
        metavar="BYTES",
        help=(
            f"Payload size in bytes per channel (default: %(default)s, "
            f"max: {DMA_PKT_SIZE_MAX})"
        ),
    )
    run_args.add_argument(
        "--skip-negative",
        action="store_true",
        default=False,
        help="Skip the negative / range-error tests",
    )

    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose > 0 else logging.INFO,
        format="%(asctime)s %(levelname)-8s %(name)s: %(message)s",
    )

    if args.size > DMA_PKT_SIZE_MAX:
        log.error(
            "--size %d exceeds DMA_PKT_SIZE_MAX=%d", args.size, DMA_PKT_SIZE_MAX
        )
        sys.exit(1)

    channels = parse_channel_list(args.channels)
    invalid = [ch for ch in channels if not (0 <= ch < NUM_RX_CH)]
    if invalid:
        log.error("Channel(s) out of range [0, %d): %s", NUM_RX_CH, invalid)
        sys.exit(1)

    log.info("Opening device: %s", args.device)
    dev = nfb.open(args.device)

    reader = C2HHBMReaderRegAccess(dev=dev)
    log.info("C2H HBM reader acquired")

    any_failed = False

    # Positive per-channel tests
    for ch in channels:
        try:
            ok = scenario_bidir_channel(reader, dev, ch, args.size, args.device)
        except Exception as exc:  # noqa: BLE001
            log.error("FAIL channel %d: unexpected exception: %s", ch, exc)
            ok = False
        if not ok:
            any_failed = True

    # Negative tests
    if not args.skip_negative:
        try:
            ok = scenario_negative(reader)
        except Exception as exc:  # noqa: BLE001
            log.error("FAIL negative test: unexpected exception: %s", exc)
            ok = False
        if not ok:
            any_failed = True
    else:
        log.info("Skipping negative tests (--skip-negative)")

    sys.exit(1 if any_failed else 0)


if __name__ == "__main__":
    main()
