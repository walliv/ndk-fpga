---
name: bitstream-flash
description: Flash an NDK-FPGA bitstream (.nfw/.bit) onto a card on the test host and bring it up. Use after building a bitstream to program an FPGA card (e.g. SparkleV onto an Alveo U55C) and verify it enumerated.
---

# Flash an NDK-FPGA bitstream

Cards live on the test host, reached over ssh (use your configured host alias). Tool: `nfb-boot` (from the `nfb-framework` package).

## Steps
1. **SSH identity** (the agent lapses, ~9 h): `ssh-add -t 9h ~/.ssh/id_ed25519`. If ssh/scp fails with exit 255 / "agent refused operation", re-add it.
2. **Copy** the image to the host: `scp <build_dir>/<card>-<app>-<pcie>.nfw <host>:~/sparklev.nfw`.
3. **Inspect**: `nfb-boot -i ~/sparklev.nfw` — confirm `Card name` and `Project name` are what you expect.
4. **Write + boot a slot**: `nfb-boot -d /dev/nfbX -f 0 ~/sparklev.nfw`. The U55C exposes a single boot slot, `0`. **Never use `--force`.** (`-w` writes without reload; `-f` writes and reloads; `-F` reloads an existing slot.)
5. **Reboot the host** for a clean PCIe re-enumeration: `ssh <host> 'sudo -n reboot'`. Required whenever the BAR layout or PCIe link width changes — on-the-fly reconfig can drop the PCIe link. Then wait for it to come back (poll ssh).
6. **Identify by project name, not index**: after reboot run `nfb-info -l` — the `/dev/nfbN` index and BDF can change. Match the card by its `Project name`. Confirm the BARs with `lspci -vv -s <bdf>` (e.g. `Region 2 ... [size=16G]` and *not* `[disabled]`).

## Cautions
- A bitstream whose BAR the host can't place can **hang POST** — e.g. a multi-GB *non-prefetchable* BAR (those are confined to the 32-bit bridge window), or any large BAR without BIOS "Above 4G Decoding" / large-BAR support. Keep a known-good recovery image to reprogram the card if it doesn't come back.
- Flashing writes the card's SPI flash; the image persists across reboots.
- The reboot drops your ssh session and any background work on the host — sequence accordingly.
