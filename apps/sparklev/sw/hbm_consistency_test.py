#!/usr/bin/env python3
# hbm_consistency_test.py: Full-range HBM consistency test — write address-stamped pattern, read back
# strided chunks via C2H reader → RX DMA Calypte, compare to expected pattern to detect bit errors
# and address aliasing.
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import ctypes
import logging
import os
import sys
import time
from argparse import ArgumentParser

import numpy as np
import nfb
from ofm.comp.dma.c2h_hbm_reader import C2HHBMReaderRegAccess

log = logging.getLogger(__name__)

_PCI_BAR2_NODE = "/drivers/mi/PCI0,BAR2"

# HBM geometry
_HBM_TOTAL_SIZE = 0x400000000          # 16 GiB
_HBM_CH_STRIDE = 0x80000000            # 2 GiB per channel
NUM_RX_CH = 8

# Pattern seed (XOR with byte address to stamp each 64-bit word)
SEED = np.uint64(0xA5A55A5ADEADBEEF)


# ---------------------------------------------------------------------------
# Helpers copied from hbm_bidir_test.py (self-contained, do not import it)
# ---------------------------------------------------------------------------

def _fdt_u64(dev, node_path, prop):
    data = dev.fdt.get_node(node_path).get_property(prop).data
    acc = 0
    for w in data:
        acc = (acc << 32) | (w & 0xffffffff)
    return acc


class HbmDirectWriter:
    """Writes raw bytes to absolute HBM byte offsets via a direct mmap of BAR2
    (bypasses comp_open, which cannot map the 16 GB BAR2)."""

    def __init__(self, dev, device_path):
        self._base = _fdt_u64(dev, _PCI_BAR2_NODE, "mmap_base")
        self._fd = os.open(device_path, os.O_RDWR)
        self._libc = ctypes.CDLL("libc.so.6", use_errno=True)
        self._libc.mmap.restype = ctypes.c_void_p
        self._libc.mmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int,
                                    ctypes.c_int, ctypes.c_int, ctypes.c_long]
        self._libc.munmap.argtypes = [ctypes.c_void_p, ctypes.c_size_t]

    def write(self, hbm_addr, data):
        off = self._base + hbm_addr                 # device-fd offset of the target
        page = off & ~0xFFF
        delta = off - page
        maplen = (delta + len(data) + 0xFFF) & ~0xFFF
        p = self._libc.mmap(None, maplen, 0x1 | 0x2, 0x1, self._fd, page)  # PROT_READ|WRITE, MAP_SHARED
        if p in (None, (1 << 64) - 1):
            raise OSError(ctypes.get_errno(), os.strerror(ctypes.get_errno()))
        try:
            ctypes.memmove(p + delta, data, len(data))
        finally:
            self._libc.munmap(ctypes.c_void_p(p), maplen)


# ---------------------------------------------------------------------------
# Address-stamped pattern
# ---------------------------------------------------------------------------

def expected_bytes(hbm_addr, length):
    """Return `length` bytes of the address-stamped pattern starting at `hbm_addr`.

    Each 64-bit word at byte address X equals ``X ^ SEED``.
    ``length`` must be a multiple of 8.
    """
    n = length // 8
    idx = np.arange(n, dtype=np.uint64)
    words = (np.uint64(hbm_addr) + idx * np.uint64(8)) ^ SEED
    return words.tobytes()


# ---------------------------------------------------------------------------
# CLI helpers
# ---------------------------------------------------------------------------

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
# Write phase
# ---------------------------------------------------------------------------

def phase_write(writer: HbmDirectWriter, hbm_size: int, write_block: int) -> float:
    """Write the address-stamped pattern over the full HBM address space.

    Returns elapsed wall-clock seconds.
    """
    log.info("=== WRITE PHASE: writing %d GiB in %d MiB blocks ===",
             hbm_size >> 30, write_block >> 20)

    t_start = time.monotonic()
    progress_threshold = 0
    progress_step = 1 << 30           # report every ~1 GiB

    addr = 0
    while addr < hbm_size:
        block = min(write_block, hbm_size - addr)
        # block must be a multiple of 8 for expected_bytes(); write_block is
        # enforced to be 8-aligned by argparse, and hbm_size is always aligned.
        writer.write(addr, expected_bytes(addr, block))
        addr += block

        if addr >= progress_threshold:
            elapsed = time.monotonic() - t_start
            mb_s = (addr / (1 << 20)) / elapsed if elapsed > 0 else 0.0
            log.info("  wrote %d GiB / %d GiB  (%.1f MB/s)",
                     addr >> 30, hbm_size >> 30, mb_s)
            progress_threshold += progress_step

    elapsed = time.monotonic() - t_start
    total_mb = hbm_size / (1 << 20)
    log.info("Write phase done: %.1f GiB in %.1f s  (%.1f MB/s)",
             hbm_size / (1 << 30), elapsed, total_mb / elapsed if elapsed > 0 else 0.0)
    return elapsed


# ---------------------------------------------------------------------------
# Read / verify phase
# ---------------------------------------------------------------------------

def _build_read_addresses(channels: list[int], stride: int, chunk: int) -> list[tuple[int, int]]:
    """Return the list of ``(hbm_addr, channel)`` pairs to read in the verify phase.

    The stride sweep covers the full 2 GiB channel window and explicitly
    appends the last aligned chunk at the top of the window to ensure end
    coverage even when stride does not divide the window evenly.
    """
    result = []
    for ch in channels:
        base = ch * _HBM_CH_STRIDE
        ch_end = base + _HBM_CH_STRIDE
        last_chunk_addr = ch_end - chunk

        addr = base
        while addr + chunk <= ch_end:
            result.append((addr, ch))
            addr += stride

        # Ensure the very last aligned chunk at the top of the window is included.
        if result and result[-1][0] != last_chunk_addr:
            result.append((last_chunk_addr, ch))

    return result


def _recv_exact(rxq, size: int, timeout_per_recv: float = 0.1, total_timeout: float = 2.0) -> bytes:
    """Collect exactly *size* bytes from *rxq*, concatenating DMA frames.

    Returns the collected bytes (may be more than *size* if DMA over-delivers,
    caller takes only [:size]).  Raises RuntimeError on timeout.
    """
    received = bytearray()
    deadline = time.monotonic() + total_timeout

    while len(received) < size:
        if time.monotonic() > deadline:
            raise RuntimeError(
                f"Timeout collecting {size} B from RX queue; "
                f"got only {len(received)} B"
            )
        frames = rxq.recv(cnt=1, timeout=timeout_per_recv)
        for frame in frames:
            received.extend(frame)

    return bytes(received)


def phase_verify(
    reader: C2HHBMReaderRegAccess,
    dev,
    channels: list[int],
    stride: int,
    chunk: int,
    verbose: bool,
) -> tuple[int, int, int, float]:
    """Read back and verify strided chunks across the selected channels.

    Returns ``(total_chunks, total_bytes, mismatch_count, elapsed_seconds)``.
    """
    log.info(
        "=== VERIFY PHASE: channels=%s  stride=%d MiB  chunk=%d B ===",
        channels, stride >> 20, chunk,
    )

    addr_list = _build_read_addresses(channels, stride, chunk)
    total_chunks = len(addr_list)
    log.info("Total read positions: %d  (%d per channel approx)",
             total_chunks, total_chunks // max(len(channels), 1))

    t_start = time.monotonic()
    mismatch_count = 0
    bytes_verified = 0

    # Open each RX queue once before issuing any reads on that channel.
    open_queues: dict[int, object] = {}
    for ch in channels:
        rxq = dev.ndp.rx[ch]
        rxq.start()
        rxq.reset_stats()
        open_queues[ch] = rxq
        log.debug("Started RX queue for channel %d", ch)

    for i, (addr, ch) in enumerate(addr_list):
        rxq = open_queues[ch]

        log.debug("[%d/%d] ch=%d addr=0x%010x  chunk=%d B",
                  i + 1, total_chunks, ch, addr, chunk)

        # Trigger C2H read.
        try:
            reader.read(addr, chunk)
        except RuntimeError as exc:
            log.error(
                "FAIL [%d/%d] ch=%d addr=0x%010x: reader.read() raised: %s",
                i + 1, total_chunks, ch, addr, exc,
            )
            mismatch_count += 1
            continue

        if reader.error:
            log.error(
                "FAIL [%d/%d] ch=%d addr=0x%010x: reader.error set after read()",
                i + 1, total_chunks, ch, addr,
            )
            mismatch_count += 1
            continue

        # Collect DMA frames from RX queue.
        try:
            got = _recv_exact(rxq, chunk)
        except RuntimeError as exc:
            log.error(
                "FAIL [%d/%d] ch=%d addr=0x%010x: recv timeout: %s",
                i + 1, total_chunks, ch, addr, exc,
            )
            mismatch_count += 1
            continue

        # Compare against expected pattern.
        expected = expected_bytes(addr, chunk)
        got_cmp = got[:chunk]

        if got_cmp != expected:
            diff_off = next(
                j for j, (a, b) in enumerate(zip(got_cmp, expected)) if a != b
            )
            # Align diff_off down to nearest 8-byte boundary for word display.
            word_off = diff_off & ~7
            exp_word = expected[word_off:word_off + 8]
            got_word = got_cmp[word_off:word_off + 8]
            log.error(
                "FAIL [%d/%d] ch=%d addr=0x%010x: mismatch at byte offset +%d "
                "(word @+%d: expected %s got %s)",
                i + 1, total_chunks, ch, addr,
                diff_off, word_off, exp_word.hex(), got_word.hex(),
            )
            mismatch_count += 1
        else:
            log.debug("[%d/%d] ch=%d addr=0x%010x OK", i + 1, total_chunks, ch, addr)

        bytes_verified += chunk

        if verbose and (i + 1) % 32 == 0:
            log.info("  verified %d / %d chunks so far  (%d mismatches)",
                     i + 1, total_chunks, mismatch_count)

    elapsed = time.monotonic() - t_start
    log.info(
        "Verify phase done: %d chunks / %d B in %.1f s  (%.1f MB/s)  mismatches=%d",
        total_chunks, bytes_verified, elapsed,
        (bytes_verified / (1 << 20)) / elapsed if elapsed > 0 else 0.0,
        mismatch_count,
    )
    return total_chunks, bytes_verified, mismatch_count, elapsed


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    parser = ArgumentParser(
        description=(
            "HBM consistency test: write an address-stamped pattern over the full 16 GiB HBM "
            "via H2C BAR2 mmap, then read back strided chunks via C2H HBM reader → RX DMA "
            "Calypte and compare to detect bit errors and address aliasing."
        ),
    )

    access = parser.add_argument_group("card access")
    access.add_argument(
        "-d", "--device",
        default=nfb.libnfb.Nfb.default_dev_path,
        metavar="DEVICE",
        help="Path to the NFB device (default: %(default)s)",
    )

    run_args = parser.add_argument_group("test control")
    run_args.add_argument(
        "-v", "--verbose",
        action="store_true",
        default=False,
        help="Enable DEBUG logging and per-chunk progress",
    )
    run_args.add_argument(
        "-s", "--channels",
        default="0-7",
        metavar="CHANNELS",
        help="Comma/range list of RX channels to verify (default: %(default)s)",
    )
    run_args.add_argument(
        "--chunk",
        type=int,
        default=4096,
        metavar="BYTES",
        help="Read chunk size in bytes — must be a multiple of 8 and <= DMA frame limit "
             "(default: %(default)s)",
    )
    run_args.add_argument(
        "--stride",
        type=lambda x: int(x, 0),
        default=0x4000000,
        metavar="BYTES",
        help="Address stride between read positions per channel (default: 0x4000000 = 64 MiB)",
    )
    run_args.add_argument(
        "--write-block",
        type=lambda x: int(x, 0),
        default=0x800000,
        metavar="BYTES",
        help="Write block size in bytes (default: 0x800000 = 8 MiB)",
    )
    run_args.add_argument(
        "--skip-write",
        action="store_true",
        default=False,
        help="Skip the write phase and only verify (assumes HBM already contains the pattern)",
    )
    run_args.add_argument(
        "--hbm-size",
        type=lambda x: int(x, 0),
        default=_HBM_TOTAL_SIZE,
        metavar="BYTES",
        help="Total HBM size in bytes (default: 0x400000000 = 16 GiB)",
    )

    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)-8s %(name)s: %(message)s",
    )

    # Validate arguments.
    if args.chunk % 8 != 0:
        log.error("--chunk must be a multiple of 8 (got %d)", args.chunk)
        sys.exit(1)

    if args.write_block % 8 != 0:
        log.error("--write-block must be a multiple of 8 (got %d)", args.write_block)
        sys.exit(1)

    if args.stride < args.chunk:
        log.error("--stride (%d) must be >= --chunk (%d)", args.stride, args.chunk)
        sys.exit(1)

    channels = parse_channel_list(args.channels)
    invalid = [ch for ch in channels if not (0 <= ch < NUM_RX_CH)]
    if invalid:
        log.error("Channel(s) out of range [0, %d): %s", NUM_RX_CH, invalid)
        sys.exit(1)

    # Validate that no read position would cross a 2 GiB channel boundary.
    if args.chunk > _HBM_CH_STRIDE:
        log.error(
            "--chunk (%d) exceeds channel window size (%d)", args.chunk, _HBM_CH_STRIDE
        )
        sys.exit(1)

    log.info("Opening device: %s", args.device)
    dev = nfb.open(args.device)

    writer = HbmDirectWriter(dev, args.device)
    log.info("HBM direct writer (BAR2 mmap) acquired")

    reader = C2HHBMReaderRegAccess(dev=dev)
    log.info("C2H HBM reader acquired")

    write_elapsed = 0.0

    # ------------------------------------------------------------------
    # Write phase
    # ------------------------------------------------------------------
    if args.skip_write:
        log.info("Skipping write phase (--skip-write)")
    else:
        write_elapsed = phase_write(writer, args.hbm_size, args.write_block)

    # ------------------------------------------------------------------
    # Verify phase
    # ------------------------------------------------------------------
    total_chunks, total_bytes, mismatch_count, read_elapsed = phase_verify(
        reader=reader,
        dev=dev,
        channels=channels,
        stride=args.stride,
        chunk=args.chunk,
        verbose=args.verbose,
    )

    # ------------------------------------------------------------------
    # Final report
    # ------------------------------------------------------------------
    log.info("")
    log.info("========== SUMMARY ==========")
    if not args.skip_write:
        write_mb = args.hbm_size / (1 << 20)
        log.info(
            "Write :  %.1f GiB in %.1f s  (%.1f MB/s)",
            args.hbm_size / (1 << 30),
            write_elapsed,
            write_mb / write_elapsed if write_elapsed > 0 else 0.0,
        )
    read_mb = total_bytes / (1 << 20)
    log.info(
        "Read  :  %d chunks / %.1f MiB in %.1f s  (%.1f MB/s)",
        total_chunks, read_mb, read_elapsed,
        read_mb / read_elapsed if read_elapsed > 0 else 0.0,
    )
    log.info("Mismatches: %d", mismatch_count)

    if mismatch_count == 0:
        log.info("Result: PASS")
    else:
        log.error("Result: FAIL  (%d mismatch(es) in %d chunks)", mismatch_count, total_chunks)
        sys.exit(1)


if __name__ == "__main__":
    main()
