---
name: ila-insert
description: Add a Vivado ILA (ChipScope) debug core to an NDK-FPGA design via the Tcl console on a saved synthesis checkpoint, package/flash it, and read captures over JTAG. Use to observe internal RTL signals (e.g. PCIe RQ/CQ MFB handshakes and TLP descriptors) on a running card without the GUI "Set Up Debug" wizard.
---

# Add ILA probes through the Vivado Tcl console

Insert an ILA on the **saved synthesis checkpoint** in one non-project Vivado session, then implement →
bitstream → `.nfw` → flash → read over JTAG. This works headless and connects the `dbg_hub` clock
cleanly, unlike a dynamic `read_xdc`-based `ilas.xdc` (which leaves `dbg_hub/clk` unconnected — the
failure mode that blocks the NDK constraint path).

Assets in this skill dir (edit the paths/instance names for your app):
- `ila_insert.tcl` — open synth checkpoint, link IP, insert ILA, opt/place/route, write bit + ltx
- `ila_discover.tcl` — enumerate JTAG targets, find the one holding the ILA, list probe names
- `ila_capture.tcl` — arm a trigger, wait, upload, write CSV

Toolchain: local Vivado `2025.1` (`/opt/Xilinx/2025.1/Vivado`), Vivado_Lab + `hw_server` on the card
host (`nct`). See also `bitstream-flash` and `nfb-access`.

## 1. Mark the signals (RTL)

Add `mark_debug` to the entity signals you want (single-bit and buses both work; connecting by the
`MARK_DEBUG` net filter is name-robust). Example (`dma_iuventus.vhd`):
```vhdl
attribute mark_debug : string;
attribute mark_debug of PCIE_RQ_MFB_SRC_RDY : signal is "true";
-- ... SOF/EOF/DST_RDY, and the CQ side ...
```
Then run a **normal build once** so the synth checkpoint + OOC IP checkpoints exist. You can also mark
extra nets at checkpoint time with `set_property MARK_DEBUG true [get_nets ...]` (no re-synth), but
note constant/unused bits are trimmed and **register-constant fields** (addresses derived from MI
regs, e.g. `SQ_BADDR`/doorbell base) get constant-propagated and are **not observable** as nets.

## 2. Insert the ILA on the synth checkpoint

Key steps (see `ila_insert.tcl`):
1. `open_checkpoint <runs>/synth_1/CARD_TOP.dcp`
2. `read_checkpoint -cell <inst> <ip.dcp>` for **every OOC IP black box** (find them with
   `get_cells -hier -filter {IS_BLACKBOX==1}`; here: pcie4_uscale_plus, axi_quad_spi). Do all your
   `get_nets`/`get_pins` **after** these reads — read_checkpoint invalidates earlier object handles.
3. **`read_xdc` the card physical constraints** (`src/general.xdc`, `src/pblock.xdc`,
   `constr/pcie_half.xdc`). These are implementation-only (pin `LOC`/`IOSTANDARD`) and are NOT in the
   synth checkpoint — **skip this and `write_bitstream` fails DRC NSTD-1/UCIO-1 and the pinout is wrong.**
4. Clock: `set clk [get_nets -of_objects [get_pins core_logic_i/dma_g[0].dma_i/CLK]]` → the DMA clock
   (`core_logic_i/pcie_clks`). Clock the ILA on the **same domain as the marked nets**.
5. `create_debug_core u_ila_0 ila`; `connect_debug_port u_ila_0/clk $clk`; add `probe` ports and
   `connect_debug_port u_ila_0/probeN $nets`. When collecting bus bits, **only include nets that
   exist** (unused lanes are trimmed) — iterate `get_nets pat[*]` and filter by index, don't loop 0..N.
6. `opt_design` (auto-inserts `dbg_hub`), `place_design`, `route_design`,
   `write_bitstream -force x.bit`, `write_debug_probes -force x.ltx`.

Fast pre-check (~2-3 min): run through `opt_design` + `report_drc` and grep for a `dbg_hub`
unconnected-clk violation before committing to full P&R.

Timing note: with only the card XDCs re-read, the async clock-group constraints are missing, so
`pcie_clks ↔ mmcm_usr_clks` **CDC paths show as false setup violations** (WNS ~ -2 ns). Confirm they
are all CDC (`report_timing_summary`; startpoint clk ≠ endpoint clk) — the bitstream is still
functionally sound. **Always sanity-test on the known-good drive/path first** before trusting a capture.

## 3. Package `.nfw` and flash

The `.nfw` is just `tar -czf` of `DevTree.dts` + `DevTree.dtb` (reuse from the normal build's
`*.netcope_tmp/`) + the `.bit` **renamed to `<FPGA-part>.bit`** (e.g. `xcu55c-fsvh2892-2L-e.bit`):
```sh
tar -czf out_ila.nfw -C tmpdir DevTree.dts DevTree.dtb xcu55c-fsvh2892-2L-e.bit
```
Then flash with the `bitstream-flash` skill (`nfb-boot -f 0`, reboot). The `.nfw` metadata (project
name/version) comes from the reused DevTree, so `nfb-info` shows the original synth's "Built at".

## 4. Read the ILA over JTAG

The `dbg_hub` is reached via JTAG (USB FT4232H per card), **independent of the PCIe/uio binding** — so
fzc/SPDK can own the PCIe function while you read the ILA. On the card host:
```sh
source /opt/Xilinx/2025.1/Vivado_Lab/settings64.sh
pgrep -x hw_server || (nohup hw_server >/tmp/hwsrv.log 2>&1 &)   # port 3121
vivado_lab -mode batch -source ila_discover.tcl -tclargs <ltx>   # find target + probe names
```
Then arm + capture with `ila_capture.tcl <target> <ltx> <trig_probe_substring> <trig_value> <pos> <csv> <timeout_s>`,
e.g. trigger on the RQ start:
```sh
vivado_lab -mode batch -source ila_capture.tcl -tclargs \
  localhost:3121/xilinx_tcf/Xilinx/<serial> ~/x.ltx PCIE_RQ_MFB_SRC_RDY "eq1'b1" 512 ~/rq.csv 60
```
Interleave: launch capture in background, wait for `### ARMED` in its log, **then** apply the stimulus
(`iuventus_rw_test.py -w 0 8`), then read the CSV. `write_hw_ila_data -csv_file` dumps one row/sample.

### JTAG gotchas (all hit and solved)
- **Device names are session-relative** in `hw_manager` (`xcu280_u55c_0` vs `_0_1` depending on which
  targets are open). Select the device that actually has your ILA/probes, not by fixed name.
- **Probe names contain `[` `]`** (e.g. `dma_g[0]`) which are glob chars — match a probe by
  **substring** (`string match "*PCIE_RQ_MFB_SRC_RDY*"`), not exact name in `get_hw_probes <name>`.
- `hw_ila` has **no `CORE_STATUS` property** in this flow; just `catch` the `wait_on_hw_ila -timeout`
  (it throws on timeout) and check its return.
- Kill fzc/vivado_lab by `pidof <exe>` / `pkill -x`, **never `pkill -f <pattern>`** where the pattern
  is in your own ssh command line (self-kill → ssh exit 255).

## Interpreting (this design)
RQ/CQ MFB TLP **header/descriptor** is in `PCIE_*_MFB_META` (wide, ~168 b/region) but its
address/req-type bits are usually constant-propagated → capture handshakes + `DATA` (payload) + what
META survives. `DST_RDY=1` on an RQ beat means the PCIe hard IP accepted the TLP (it went on the wire).
No `CQ SRC_RDY` after a stimulus = no completion arrived from the device.
