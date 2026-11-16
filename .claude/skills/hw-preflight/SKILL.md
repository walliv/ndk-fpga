---
name: hw-preflight
description: Pre-flight checks on the FPGA test host before a hardware measurement campaign or a fzc session — ssh key, card identity, drive links, uio bindings, OS-drive safety, queue depth. Use before any campaign or after the host rebooted.
disable-model-invocation: true
---

# Hardware campaign pre-flight

Concrete host addresses live in `CLAUDE.local.md`; this skill uses placeholders. Stop at the first
failed check and report it. Never fix a check by reloading the card mid-campaign.

## 1. ssh
```sh
ssh-add -t 9h ~/.ssh/id_ed25519      # a lapsed agent looks like "host unreachable"
ssh <host> true
```

## 2. Card identity
- `nfb-info -l` (as a normal user, never with sudo). Match the card by **project name** and PCI
  address, never by `/dev/nfbN` index; the index moves after a reload or reboot.
- Use the test card named in `CLAUDE.local.md` (the one on the same root complex as the SSDs).
  Host scripts may default to the other card, so override their device variables.
- `nfb-boot -i` on the image you expect and compare it with the running project name. A stale
  bitstream produces convincing wrong numbers.

## 3. Drive links
For every campaign SSD: `sudo -n lspci -vv -s <ssd-bdf> | grep LnkSta`. Any `(downgraded)` stops the
campaign: a narrower link caps that queue and every even split across queues. A reboot does not fix
it; reseating does.

## 4. Bindings
- After a reboot, run the devbind helper once. It registers the uio ids, binds the FPGA peer
  functions and the SSDs, sets `COMMAND=0x406` and loads `ublk_drv`.
- Check `/sys/bus/pci/drivers/uio_pci_generic/new_id` took the SSD id. Without it, SPDK cannot
  attach, and fills "succeed" on empty drives.
- Check that the peer function's `BASE_ADDRESS_0` is non-zero. Never assert a fixed value, since a
  rescan reorders BARs.

## 5. OS drive
`lspci -k -s <os-drive-bdf>` must show the kernel `nvme` driver. If it shows anything else, stop.
Never pass its address or device id to any bind, format or SPDK command.

## 6. Protocol
- fzc runs with `-q 64` for the whole campaign, as one session.
- Load the design at step 0 only. No reload, soft reset or DMA stop/start between points. A wedge
  stops the campaign and gets reported; never reload and continue.
- Stop processes with SIGTERM or SIGUSR, by exact name (`pkill -x`) or PID.
- Every result needs 10 comparable repetitions. State QD, drive count, firmware and bitstream in
  the run's CONFIG line.
