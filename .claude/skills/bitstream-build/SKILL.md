---
name: bitstream-build
description: Build (synthesize + implement) an NDK-FPGA application bitstream for a card with Vivado/Quartus and verify it. Use when asked to build or rebuild a design (e.g. SparkleV on alveo-u55c) or after changing RTL, PCIe IP config, app_conf, or the DevTree.
---

# Build an NDK-FPGA bitstream

Run from the app's card build directory, e.g. `apps/sparklev/build/alveo-u55c/`.

## Build
- Full build: `make` (selects Vivado or Quartus per the Makefile; ~1 h for an Alveo U55C). Run in the background and capture the log:
  `make 2>&1 | tee build_run.log`
- Override the tool with `make SYNTH=vivado` / `make SYNTH=quartus`.
- Card-specific Ethernet targets exist on some cards (e.g. `make 400g1`, `make 100g4`).

## Clean rebuild (do this when config changed)
- `make clean` first (removes `.cache`/`.runs`/`.gen`/`.bit`/`.nfw`; keeps `card_top.vhd` and the xdc).
- **If you changed the PCIe IP / any IP config**, also `rm -rf src/pcie4_uscale_plus*` (or the relevant `src/<ip>*` dir) so the IP `.xci` is regenerated — otherwise Vivado can reuse a cached IP with the *old* config and your change silently won't take effect. Confirm by grepping the freshly generated `.xci` for the parameter you changed.

## Verify — RTL correctness, NOT timing
Grep `build_run.log` for:
- `Synthesis finished with 0 errors`
- `DRC finished with 0 Errors`
- `Bitgen Completed Successfully` and `write_bitstream completed successfully`
- `All constraints were met`

Timing/utilization numbers are not the bring-up criterion — 0 errors + bitstream written is what proves the RTL is correct.

## Fail fast
A VHDL/elaboration error surfaces within ~10–15 min (well before the ~1 h finish). Arm an early watcher so a typo doesn't cost a full hour:
```
until grep -qiE 'ERROR:|Synthesis finished with' build_run.log; do sleep 15; done
grep -niE "ERROR:|Synthesis finished with" build_run.log | head
```
Generic/parameter values that reached synthesis are echoed too (e.g. `Parameter X bound to: 1`), handy to confirm a config propagated.

## Artifacts
`<card>-<app>-<pcie>.nfw` (preferred for flashing — a gzipped tar of bitstream + DeviceTree) and the raw `.bit`. Inspect a `.nfw` with `nfb-boot -i <file>`.
