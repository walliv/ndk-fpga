---
name: fzc-run
description: Run the fzc (fpga_zero_copy SPDK app) P2P test on the test host — bind the SSD + FPGA PF1 to uio, set PCIe bus-master, launch fzc against the DMA-Iuventus card, drive reads via the USER_CORE generator, and tear down. Use to exercise NVMe peer-to-peer reads/writes from the Iuventus FPGA.
---

# Run fzc (FPGA P2P NVMe test)

`fzc` = **`fpga_zero_copy`**, a custom SPDK app built under an SPDK checkout
(`~/projects/spdk/build/examples/fpga_zero_copy`) on the test host. It sets up the DMA-Iuventus
SQ/CQ/buffers in the FPGA's PF1 BARs, attaches an NVMe SSD as the P2P peer, enables the design, and
holds it open. Actual read/write traffic is driven by the FPGA's USER_CORE **test generator** (via
`apps/iuventus/sw/iuventus_rw_test.py`), not by fzc itself.

Everything runs on the test host over ssh — use your configured host alias (shown here as `<host>`:
`ssh <host>`). Re-add the ssh key if the agent lapsed: `ssh-add -t 9h ~/.ssh/id_ed25519`.

## 0. Identify the card and SSD
- The Iuventus P2P card is a U55C: PF0 (`<fpga-pf0-bdf>`) = nfb mgmt, PF1 (`<fpga-pf1-bdf>`) = the peer
  BAR holding SQ/CQ/RDBUFF/WRBUFF. `nfb-info -l` — **the `/dev/nfbN` index changes** after a
  module/firmware reload, so match by PCI addr and use that index for `fzc -d <index>` and
  `nfb.open("<index>")`.
- Identify the P2P SSD by its PCI addr (`<ssd-bdf>`); some consumer SSDs wedge on idle, so qualify per
  drive. **NEVER touch/format the OS drive** (`<os-drive-bdf>`, kernel nvme).

## 1. Bind SSD + FPGA PF1 to uio + set bus-master
A local devbind helper registers the vendor IDs, binds PF1 + the SSD to `uio_pci_generic`, sets
`COMMAND=0x406`, and `modprobe ublk_drv`. Or minimal, by hand:
```sh
echo "18ec c020" | sudo tee /sys/bus/pci/drivers/uio_pci_generic/new_id   # FPGA NCD
echo "1c5c 1639" | sudo tee /sys/bus/pci/drivers/uio_pci_generic/new_id   # NVMe SSD (vendor:device)
echo 0000:<fpga-pf1-bdf> | sudo tee /sys/bus/pci/drivers/uio_pci_generic/bind
sudo setpci -s <fpga-pf1-bdf> COMMAND=0x406                                # mem + bus-master
echo 0000:<ssd-bdf> | sudo tee /sys/bus/pci/devices/0000:<ssd-bdf>/driver/unbind
echo 0000:<ssd-bdf> | sudo tee /sys/bus/pci/drivers/uio_pci_generic/bind
sudo setpci -s <ssd-bdf> COMMAND=0x406
sudo modprobe ublk_drv
```
`sudo` on the test host is non-interactive (`sudo -n`). Verify PF1 BAR0 != 0
(`setpci -s <fpga-pf1-bdf> BASE_ADDRESS_0`); **do NOT assert a fixed BAR value** — a rescan reorders
BAR→address (see [[reference_nfb_boot_no_reboot_reload]]).

## 2. Launch fzc (background)
```sh
FZC=~/projects/spdk/build/examples/fpga_zero_copy
sudo -n nohup $FZC -d <idx> -t "trtype:PCIe traddr:0000:<ssd-bdf>" -q 16 > /tmp/fzc.log 2>&1 &
```
`-d <idx>` = the card's /dev/nfb index; `-q` = queue depth (16 for QD16). fzc enables the design
(`CONTROL` bit 0). It reaches `Starting main loop` but that printf is **stdout-block-buffered** to the
redirected file, so it may not flush — check `CONTROL & 1 == 1` instead of grepping the log. ublk is
disabled in fzc, so no `/dev/ublkbN` appears — that's expected.

## 3. Drive reads + read counters (Python)
Use a Python env that has `nfb` plus the `ofm`/iuventus tooling:
```python
import nfb, sys; sys.path.insert(0, "apps/iuventus/sw")
from iuventus_rw_test import IuventusTest
from ofm.comp.dma.iuventus.iuventus_reg_access import DMAIuventusRegAccess
DEV="<idx>"
c = nfb.open(DEV).comp_open("ziti,dma_iuventus", 0)
test = IuventusTest(dev=DEV, index=0); ra = DMAIuventusRegAccess(dev=DEV)
while (c.read16(0x00) & 1) == 0: pass                 # wait for fzc ENABLE
test.contig_test=False; test.tst_mode="rd"; test.tst_addressing="seq"; test.rd_req_lba_num=7
test.tst_iterations = 99999                            # trigger a bounded read burst
ra.sample_cntrs(); print(ra.succ_cpls, ra.unsucc_cpls, ra.sqes_dispatched, ra.sq_pcie_rds)
```
Built-in throughput/latency: `iuventus_rw_test.py -t` (IOPS from the EVENT_COUNTER, GBps derived
from it -- the design has no MFB speed meter) / `-l` / `-p`
(plots) / `--throughput-from-file`. Prefer these over ad-hoc scripts. A healthy drive shows `succ`
climbing steadily with `unsucc=0`. **Wedged/jammed** = `succ` frozen, `SQ_PCIE_RDS` stalls while
`SQE_DISP` climbs, `RDY=0`.

## 4. Teardown / recovery
- Stop fzc: `sudo -n pkill -9 -f fpga_zero_copy` then clear the design: `python -c "import nfb;
  nfb.open('<idx>').comp_open('ziti,dma_iuventus',0).write16(0x00,0)"`. (fzc kill + counter reads in
  one compound ssh command often swallow output — run them as separate ssh calls.)
- **op_ctrl jam recovery** (after a wedge, persists across fzc runs): reload the FPGA
  `nfb-boot -d /dev/nfbN -F 0` (no reboot — the driver re-enumerates PF1; then re-`setpci
  COMMAND=0x406`). This resets op_ctrl to fresh.
- Restore the SSD to kernel nvme when done: remove the uio dynamic id, unbind from uio, bind to `nvme`.

## Cautions
- Never run `nfb-*`/`ndp-*` with sudo for control ops (they work as user); `sudo` is only for
  `setpci`/`uio bind`/`fzc` (SPDK hugepages).
- Never touch the OS drive.
