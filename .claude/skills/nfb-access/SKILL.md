---
name: nfb-access
description: Access a running NDK bitstream from software using nfb-tools (CLI) and the pynfb/ofm Python API — read/write component registers, inspect the device tree, check DMA engines, or write a design's HBM/DMA BAR windows. Use when interacting with a flashed, live FPGA design.
---

# Access an NDK design via nfb-tools / pynfb

## CLI tools (on the card host)
**Never use sudo with any nfb-* or ndp-* tool** — they work as a normal user.

- `nfb-info -l` — list cards: index, PCI BDF, card name, running project, version.
- `nfb-bus -l [-d /dev/nfbX]` — list device-tree nodes / the MI (BAR0) address space.
- `nfb-bus -d /dev/nfbX -p <node_path> <addr> [value]` — read (no value) or write (with value) a register.
- `nfb-dma [-d /dev/nfbX] [-v]` — DMA controller / queue status (recognizes CALYPTE/NDP/etc.).
- `nfb-boot` — program/boot the card (see the `bitstream-flash` skill).

## Python (pynfb + ofm)
Use a mamba env that has `nfb`, `fdt`, `ofm`, `cocotbext.ofm` installed:
```python
import nfb
dev  = nfb.open("/dev/nfb0")
node = dev.fdt_get_compatible("ziti,sparklev,h2c_dma_hyperion")[0]
comp = dev.comp_open(node)
print(hex(comp.read32(0x04)))      # read STATUS
comp.set_bit(0x00, 0, width=8)     # pulse a control bit
```
- Wrap a component as an `nfb.BaseComp` subclass (set `DT_COMPATIBLE`); see `python/ofm/ofm/comp/dma/...` (e.g. `iuventus`, `hyperion`) for the pattern, and `python/cocotbext/cocotbext/ofm/dma/...` for shared register-map enums.
- `comp_open` requires the node's `reg` to be **2 cells** (32-bit base + 32-bit size) — it cannot address a >4 GB / 64-bit-`reg` BAR window. For a large memory BAR, read `mmap_base`/`mmap_size` from `/drivers/mi/PCIx,BARn` (`u64` props) and `mmap()` the `/dev/nfbX` fd directly at `mmap_base + channel_offset`.

## Editable installs
`ofm`/`cocotbext.ofm` may be installed as a *copy* in site-packages rather than truly editable. After editing those packages, refresh with `pip install --force-reinstall --no-deps <repo>/python/ofm` (and likewise cocotbext) so the running env sees the change.

## CAUTIONS
- **Never read a write-only BAR** (e.g. an HBM-write window with no read-completion logic). A read TLP with no completion → completion timeout → AER fatal → host reset. Do not add a "read-back to flush" — PCIe ordering means a read of any *completing* register (BAR0/MI) already pushes prior posted writes to the device.
- For write-combined (prefetchable) BARs, libnfb's `nfb_bus_mi_write` issues an `_mm_mfence` after the copy, so `comp.write()` is self-fencing.
- A stalled downstream (e.g. HBM not ready) must never back-pressure the shared PCIe CQ — that wedges the whole endpoint. Engines on the DMA-BAR path should drop+count rather than stall.
