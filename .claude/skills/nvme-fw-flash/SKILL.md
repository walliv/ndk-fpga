---
name: nvme-fw-flash
description: Flash NVMe SSD firmware on the test host — the generic nvme-cli path, and the Samsung-consumer (990 PRO) path where raw nvme-cli fails and the vendor `fumagician` tool is required. Use to update an SSD's firmware (e.g. bringing all P2P test drives to one revision) without booting a vendor ISO.
---

# Flash NVMe SSD firmware

SSDs live on the test host, reached over ssh (use your configured host alias `<host>`). Two paths:
a **generic** one that works for most drives, and a **Samsung-consumer** one (990 PRO / 9-series)
whose firmware image is encrypted and can only be applied by Samsung's `fumagician`.

## Safety first (do these every time)

- **SSH identity**: if your ssh-agent entry has a lifetime it can lapse — re-add your key
  (`ssh-add -t <ttl> <path/to/key>`) and retry when a remote command fails with exit 255.
- **Identify drives by SERIAL, not NVMe node** — `/dev/nvmeN` numbers reorder across reboots/rescans.
  Map fresh: `for n in /sys/class/nvme/nvme*; do echo "$(basename $n) -> $(basename $(readlink -f $n/device))"; done`,
  then `nvme id-ctrl /dev/nvmeN | grep -E '^sn|^fr'`.
- **Never flash the OS drive.** Find it first: `lsblk` / `findmnt /` → note its nvme node, exclude it.
  Sanity-check with `dmesg | grep -i 'EXT4.*re-mounted'` (shows the root nvme node).
- **Drive must be idle** — not mounted, no holders: `lsblk -o NAME,MOUNTPOINT /dev/nvmeNn1`,
  `sudo fuser -m /dev/nvmeNn1` (expect none). Bring it back to the kernel `nvme` driver if it was
  bound to `uio_pci_generic`/`vfio-pci`.
- **Flash one drive at a time**, verify healthy, then the next — so a bad flash can't take out several.
- Firmware update warnings about "data loss" are Samsung boilerplate; a firmware update does not erase
  user data, but confirm the target is a scratch drive if unsure.

## Path A — generic nvme-cli (raw firmware image available)

Use when you have a **raw, unencrypted** firmware binary for the drive.

1. Check slot rules: `nvme id-ctrl /dev/nvmeN | grep -E '^frmw|^fwug'` and `nvme fw-log /dev/nvmeN`.
   `frmw` bit0 = slot 1 read-only?, bits3:1 = #slots, bit4 = activate-without-reset supported.
2. Download: `sudo nvme fw-download /dev/nvmeN --fw=<firmware.bin>` (add `--xfer=0x1000` if it errors).
3. Commit to a writable slot, activate on reset: `sudo nvme fw-commit /dev/nvmeN -s <slot> -a 1`.
4. Activate: `sudo nvme reset /dev/nvmeN` (or `sudo reboot` if the drive needs a power cycle).
5. Verify: `nvme id-ctrl /dev/nvmeN | grep '^fr'` shows the new revision.

## Path B — Samsung consumer (990 PRO etc.): use `fumagician`

**Raw `nvme fw-download` of the Samsung `.enc` FAILS** at offset `0x300000` (3 MB) with
`Invalid Field in Command (0x2)`, regardless of `--xfer` — the `.enc` is **encrypted** (high-entropy,
no plaintext image header); `fumagician` decrypts it before sending. So Path A cannot be used.

`fumagician` is a **static x86-64 ELF** shipped inside the Samsung firmware-update ISO — it runs on the
live host, **no ISO boot needed**.

1. **Get the tool + image.** Extract the Samsung firmware ISO (`bsdtar -xf <firmware>.iso -C <dir>`),
   or reuse a prior extraction. The binary and encrypted image are at:
   `<extract>/rootfs/root/fumagician/fumagician` and `.../fumagician/<REV>.enc`.
2. **Understand its UI.** `fumagician` takes **no args**. It enumerates all compatible Samsung drives,
   prints a `# | Model | Serial | Firmware` table, then prompts
   `Do you want to continue the firmware update? [Y/N]` (plus a data-loss WARNING `[Y/N]`) **per drive**.
   It **skips drives already on the target FW** ("Firmware is already updated on this SSD!") and only
   lists compatible models (won't touch other-model or non-Samsung drives). If the target revision is
   correct for every listed drive, **answering `Y` to all is safe.**
3. **Drive it over a real PTY with PACED input.** It needs a TTY and time to reach each prompt — a
   `yes Y` flood produces no output / a stuck ssh. Drop this helper on the host and run it under `sudo`:
   ```sh
   #!/bin/bash
   FUMA=<extract>/rootfs/root/fumagician/fumagician
   : > /tmp/fuma.log
   ( for i in $(seq 1 90); do echo Y; sleep 1; done ) | script -q -f -c "$FUMA" /tmp/fuma.log
   echo "=== fumagician exited rc=$? ===" >> /tmp/fuma.log
   ```
   Run in the background (`ssh <host> 'sudo -n /tmp/flash_fw.sh'`) and **poll `/tmp/fuma.log`** live:
   `tr -d '\r' < /tmp/fuma.log | grep -viE '^Y+$'`. Watch for `Firmware Update Completed` per drive.
4. **Activate.** `fumagician` does `fw-commit` → the new FW lands in **slot 1** (`nvme fw-log` `frs1`),
   `afi` queues it for next reset, but **`nvme id-ctrl … fr` still shows the OLD revision** until reset.
   **`sudo nvme reset /dev/nvmeN` activates it — no reboot required.**
5. **Verify** all intended drives: `nvme id-ctrl /dev/nvmeN | grep '^fr'` → new revision.
6. **Clean up** the root-owned log/helper: `sudo rm -f /tmp/fuma.log /tmp/flash_fw.sh`.

## Cautions

- **MPS is not firmware.** `DevCtl MaxPayload` is set by OS PCIe enumeration; flashing does not change
  it. If drives must match an FPGA endpoint's MPS for P2P, clamp separately with `setpci`
  (`CAP_EXP+8.w`, MaxPayload field bits 7:5) or rebuild the FPGA PCIe IP — see [[nfb-access]].
- A controller reset (`nvme reset`) activates firmware committed with "activate on next reset" and does
  **not** touch PCIe config space (so MPS, BAR placement, driver binding all survive). Prefer it over a
  reboot unless a drive specifically requires a power cycle.
- Real host aliases, serials, BDFs, and firmware paths are private — keep them out of this repo; look
  them up live on the host.
