#!/usr/bin/env python3

import sys
import json
import statistics
import fcntl
from datetime import datetime
import os
from enum import IntEnum
from time import sleep

import nfb
from ofm.comp.debug.data_logger.data_logger import DataLogger
from ofm.comp.mfb_tools.debug.generator import MfbGenerator
import ofm.comp.dma.latency_meas.calam_graph
from ofm.utils import convert_units


# Held open for the process lifetime: closing the file releases the lock.
_device_lock_fh = None


def acquire_device_lock(device) -> None:
    """Refuse to start if another instance is already driving this device.

    Two of these at once share one traffic generator and one set of counters, so each overwrites
    the other's stimulus mid-sweep and both read totals containing the other's traffic. It does not
    look like a tooling fault -- it surfaces as 0 IOPS, or as impossible values such as a free-page
    count above the pool size -- so it is worth failing loudly instead.

    flock is released by the kernel on process exit, including SIGKILL, so a stale lock file can
    never block a later run.
    """
    global _device_lock_fh

    tag = "".join(c if c.isalnum() else "_" for c in str(device))
    path = os.path.join("/tmp", f"iuventus_rw_test.{tag}.lock")
    try:
        fh = open(path, "a+")
    except OSError as exc:
        raise SystemExit(f"ERROR: cannot open device lock {path}: {exc}")

    try:
        fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        fh.seek(0)
        owner = fh.read().strip() or "unknown"
        fh.close()
        raise SystemExit(
            f"ERROR: another instance is already driving device '{device}' (pid {owner}).\n"
            f"       Lock: {path}\n"
            "       Two instances corrupt each other's measurements -- wait for it to finish, or\n"
            "       stop it with SIGINT (never SIGKILL while fzc is running)."
        )

    fh.seek(0)
    fh.truncate()
    fh.write(str(os.getpid()))
    fh.flush()
    _device_lock_fh = fh


def _latex_escape(text: str) -> str:
    return text.replace("_", r"\_")


def build_throughput_iops_booktabs_table(results):
    mode_labels = {
        "rd": "RD",
        "wr": "WR",
    }
    addressing_labels = {
        "rand": "Random",
        "seq": "Sequential",
    }
    mode_order = ["rd", "wr"]
    addressing_order = ["rand", "seq"]

    grouped_results = {}
    for item in results:
        mode = str(item["mode"]).lower()
        addressing = str(item["addressing"]).lower()
        if mode not in mode_order or addressing not in addressing_order:
            continue

        grouped_results.setdefault((mode, addressing), []).append(item)

    for key in grouped_results:
        grouped_results[key].sort(key=lambda row: (int(row.get("num_queues", 1)), int(row["lba_num"])))

    lines = [
        r"\begin{table}[!ht]",
        r"    \centering",
        r"    \caption{Results of throughput measurement for different operations, request sizes and access pattern}",
        r"    \label{tab:thrp_results}",
        r"    \begin{tabular}{llSSSS}",
        r"        \toprule",
        r"        \textbf{Mode} & \textbf{Addressing} & \textbf{Queues} & \textbf{LBAs} & \textbf{IOps} & \textbf{Throughput} \\",
        r"                    & & & & & \textbf{[GBps]} \\",
        r"        \midrule",
    ]

    first_mode_block = True
    for mode in mode_order:
        mode_has_rows = any((mode, addressing) in grouped_results for addressing in addressing_order)
        if not mode_has_rows:
            continue

        if not first_mode_block:
            lines.append(r"        \midrule")
        first_mode_block = False

        mode_written = False
        for addressing_index, addressing in enumerate(addressing_order):
            rows = grouped_results.get((mode, addressing), [])
            if not rows:
                continue

            if mode_written and addressing_index > 0:
                lines.append(r"        \addlinespace")

            addressing_written = False
            for item in rows:
                mode_col = mode_labels[mode] if not mode_written else ""
                addressing_col = addressing_labels[addressing] if not addressing_written else ""
                num_queues = int(item.get("num_queues", 1))
                lba_num = int(item["lba_num"]) + 1
                iops = float(item["iops"])
                throughput_gbps = float(item["throughput_bps"]) / 1e9
                thrp_calc_gbps = iops * lba_num * 512 / 1e9
                lines.append(
                    f"        {mode_col} & {addressing_col} & {num_queues} & {lba_num} & {iops:.0f} & "
                    f"{throughput_gbps:.3f} \\\\"
                )
                mode_written = True
                addressing_written = True

    lines.extend([
        r"        \bottomrule",
        r"    \end{tabular}",
        r"\end{table}",
    ])
    return "\n".join(lines)


def _mode_label(mode: str, addressing: str, num_queues: int = 1) -> str:
    mode_name = "read" if mode == "rd" else "write"
    addr_name = "sequential" if addressing == "seq" else "random"
    return f"{mode_name} {addr_name} (N={num_queues})"


def _collect_series(results, selector, metric_key):
    series = {}
    for item in results:
        mode = item["mode"]
        addressing = item["addressing"]
        if not selector(mode, addressing):
            continue
        num_queues = int(item.get("num_queues", 1))
        label = _mode_label(mode, addressing, num_queues)
        lba_count = int(item["lba_num"]) + 1
        metric_value = float(item[metric_key])
        series.setdefault(label, []).append((lba_count, metric_value))

    for key in series:
        series[key].sort(key=lambda pair: pair[0])

    return series


def _save_metric_plot(results, selector, metric_key, title, y_label, value_scale, out_base_path, png_dpi=400):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    series = _collect_series(results, selector, metric_key)
    if not series:
        return []

    plt.figure(figsize=(8, 6))
    for label in sorted(series):
        x_vals = [x for x, _ in series[label]]
        y_vals = [y / value_scale for _, y in series[label]]
        plt.plot(x_vals, y_vals, marker="o", linewidth=2, label=label)

    plt.xlabel("Request size [LBAs]", fontsize=15)
    plt.ylabel(y_label, fontsize=15)
    plt.xticks([1, 16, 32, 64, 128, 256], fontsize=13)
    plt.yticks(fontsize=13)
    plt.grid(True, linestyle="--", alpha=0.8)
    plt.legend(fontsize=12)
    plt.tight_layout()
    png_path = f"{out_base_path}.png"
    pdf_path = f"{out_base_path}.pdf"
    plt.savefig(png_path, dpi=png_dpi)
    plt.savefig(pdf_path)
    plt.close()
    return [png_path, pdf_path]


def run_stamp() -> str:
    """Timestamp suffix shared by every artifact of ONE -t invocation, so successive sweeps
    accumulate instead of overwriting each other. These are WORKING artifacts: promote the ones
    worth keeping into doc/measurements/ deliberately, do not commit them wholesale."""
    return datetime.now().strftime("%Y-%m-%d_%H%M%S")


def build_throughput_plots(results, out_dir=".", stamp=None):
    os.makedirs(out_dir, exist_ok=True)
    stamp = stamp or run_stamp()

    plots = [
        (
            "throughput_all_modes",
            "Throughput vs Request Size (All Modes)",
            lambda mode, addressing: mode in {"rd", "wr"} and addressing in {"seq", "rand"},
        ),
        (
            "throughput_read_seq_vs_rand",
            "Throughput vs Request Size (Read: Sequential vs Random)",
            lambda mode, addressing: mode == "rd" and addressing in {"seq", "rand"},
        ),
        (
            "throughput_write_seq_vs_rand",
            "Throughput vs Request Size (Write: Sequential vs Random)",
            lambda mode, addressing: mode == "wr" and addressing in {"seq", "rand"},
        ),
        (
            "throughput_seq_read_vs_write",
            "Throughput vs Request Size (Sequential: Read vs Write)",
            lambda mode, addressing: addressing == "seq" and mode in {"rd", "wr"},
        ),
        (
            "throughput_rand_read_vs_write",
            "Throughput vs Request Size (Random: Read vs Write)",
            lambda mode, addressing: addressing == "rand" and mode in {"rd", "wr"},
        ),
    ]

    generated = []
    for file_stem, title, selector in plots:
        out_base_path = os.path.join(out_dir, f"{file_stem}_{stamp}")
        generated_paths = _save_metric_plot(
            results=results,
            selector=selector,
            metric_key="throughput_bps",
            title=title,
            y_label="Throughput [GBps]",
            value_scale=1e9,
            out_base_path=out_base_path,
        )
        if generated_paths:
            generated.extend(generated_paths)

    return generated


def build_iops_plots(results, out_dir=".", stamp=None):
    os.makedirs(out_dir, exist_ok=True)
    stamp = stamp or run_stamp()

    plots = [
        (
            "iops_all_modes",
            "IOps vs Request Size (All Modes)",
            lambda mode, addressing: mode in {"rd", "wr"} and addressing in {"seq", "rand"},
        ),
        (
            "iops_read_seq_vs_rand",
            "IOps vs Request Size (Read: Sequential vs Random)",
            lambda mode, addressing: mode == "rd" and addressing in {"seq", "rand"},
        ),
        (
            "iops_write_seq_vs_rand",
            "IOps vs Request Size (Write: Sequential vs Random)",
            lambda mode, addressing: mode == "wr" and addressing in {"seq", "rand"},
        ),
        (
            "iops_seq_read_vs_write",
            "IOps vs Request Size (Sequential: Read vs Write)",
            lambda mode, addressing: addressing == "seq" and mode in {"rd", "wr"},
        ),
        (
            "iops_rand_read_vs_write",
            "IOps vs Request Size (Random: Read vs Write)",
            lambda mode, addressing: addressing == "rand" and mode in {"rd", "wr"},
        ),
    ]

    generated = []
    for file_stem, title, selector in plots:
        out_base_path = os.path.join(out_dir, f"{file_stem}_{stamp}")
        generated_paths = _save_metric_plot(
            results=results,
            selector=selector,
            metric_key="iops",
            title=title,
            y_label="IOps",
            value_scale=1.0,
            out_base_path=out_base_path,
        )
        if generated_paths:
            generated.extend(generated_paths)

    return generated


def save_throughput_results(results, out_path):
    out_dir = os.path.dirname(out_path)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)

    with open(out_path, "w") as output_file:
        json.dump(results, output_file, indent=2)


def load_throughput_results(in_path):
    with open(in_path, "r") as input_file:
        results = json.load(input_file)

    assert isinstance(results, list), "Throughput results file must contain a JSON list"
    required_keys = {"mode", "addressing", "lba_num", "iops", "throughput_bps"}
    for index, item in enumerate(results):
        assert isinstance(item, dict), f"Result item #{index} must be a JSON object"
        missing = required_keys - set(item.keys())
        assert not missing, f"Result item #{index} is missing keys: {sorted(missing)}"

    return results


def generate_throughput_outputs(results, out_dir="."):
    os.makedirs(out_dir, exist_ok=True)

    latex_table = build_throughput_iops_booktabs_table(results)
    out_path = os.path.join(out_dir, "throughput_iops_table.tex")
    with open(out_path, "w") as output_file:
        output_file.write(latex_table + "\n")
    print(f"\nSaved LaTeX table to {out_path}")

    stamp = run_stamp()
    plot_paths = build_throughput_plots(results, out_dir=out_dir, stamp=stamp)
    for path in plot_paths:
        print(f"Saved plot to {path}")

    iops_plot_paths = build_iops_plots(results, out_dir=out_dir, stamp=stamp)
    for path in iops_plot_paths:
        print(f"Saved plot to {path}")


class IuventusTestRegMap(IntEnum):
    RD_REQ_VLD           = 0x00
    RD_REQ_LBA_PTR       = 0x04
    RD_REQ_LBA_NUM       = 0x0C
    WR_REQ_LBA_PTR       = 0x10
    OP_STAT_REG          = 0x18
    TST_ITERATIONS       = 0x1C
    TST_SEQ_RAND_SEL     = 0x20
    EVCR_INTERVAL_CYCLES = 0x24
    ECVR_TOTAL_EVENTS    = 0x28
    EVCR_TOTAL_CYCLES    = 0x2C
    RD_CH_MINMAX         = 0x58
    RD_BURST             = 0x5C


class LatencyMeterOutput(ofm.comp.dma.latency_meas.calam_graph.LatencyMeterOutput):
    def __init__(self, **kwargs):
        super().__init__(**kwargs)

    def process_results_by_structure(self, tests):
        tst_grps = []
        for key, _ in tests.items():
            # print(f"Adding item: {mode}, {addressing}, {size}")
            tst_grps.append((key, f"./{key}.json"))

        self.load_config_user("./meas_conf.json")
        self.draw_cumdib(tst_grps)


class IuventusTest(nfb.BaseComp):
    DT_COMPATIBLE = "ziti,iuventus_test_ctrl"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.gen = MfbGenerator(*args, **kwargs)
        self.gen.burst_size = 1
        self.gen.bursting = True
        self.clk_period = 4*(10**-9)

    @property
    def rd_req_vld(self):
        return self._comp.get_bit(IuventusTestRegMap.RD_REQ_VLD.value, 0)

    @rd_req_vld.setter
    def rd_req_vld(self, val: bool):
        self._comp.set_bit(IuventusTestRegMap.RD_REQ_VLD.value, 0, val)

    @property
    def rd_req_rdy(self):
        return self._comp.get_bit(IuventusTestRegMap.RD_REQ_VLD.value, 1)

    @property
    def rd_req_lba_ptr(self):
        return self._comp.read64(IuventusTestRegMap.RD_REQ_LBA_PTR.value)

    @rd_req_lba_ptr.setter
    def rd_req_lba_ptr(self, val: int):
        self._comp.write64(IuventusTestRegMap.RD_REQ_LBA_PTR.value, val)

    @property
    def rd_req_lba_num(self):
        return self._comp.read8(IuventusTestRegMap.RD_REQ_LBA_NUM.value)

    @rd_req_lba_num.setter
    def rd_req_lba_num(self, val: int):
        self._comp.write8(IuventusTestRegMap.RD_REQ_LBA_NUM.value, val & 0xFF)

    @property
    def wr_req_lba_ptr(self):
        return self._comp.read64(IuventusTestRegMap.WR_REQ_LBA_PTR.value)

    @wr_req_lba_ptr.setter
    def wr_req_lba_ptr(self, val: int):
        self._comp.write64(IuventusTestRegMap.WR_REQ_LBA_PTR.value, val)

    @property
    def op_stat_reg(self):
        val = self._comp.read64(IuventusTestRegMap.OP_STAT_REG.value)
        op_code = val & 0x3
        op_type = (val >> 2) & 0x1
        op_vld = (val >> 3) & 0x1
        return op_code, op_type, op_vld

    @property
    def tst_iterations(self):
        return self._comp.read32(IuventusTestRegMap.TST_ITERATIONS.value)

    @tst_iterations.setter
    def tst_iterations(self, val: int):
        assert val >= 1000, "Iterations must be greater than 1000"
        self._comp.write32(IuventusTestRegMap.TST_ITERATIONS.value, val)

    @property
    def lat_meas_mode(self) -> bool:
        """Serialise the read generator to ONE operation in flight (TST_SEQ_RAND_SEL bit 4).

        LATENCY_METER pairs starts to completions positionally -- it carries no tag -- so any
        concurrency pairs a completion with the wrong start. Without this the generator issued
        back-to-back until the page pool emptied, the run could never retire its programmed
        operation count and the measurement FSM never asserted tst_finished, hanging the caller.
        Single SSD / single queue pair only; this deliberately throttles to QD1 and must be off
        for throughput runs."""
        return self._comp.get_bit(IuventusTestRegMap.TST_SEQ_RAND_SEL.value, 4)

    @lat_meas_mode.setter
    def lat_meas_mode(self, val: bool) -> None:
        self._comp.set_bit(IuventusTestRegMap.TST_SEQ_RAND_SEL.value, 4, val)

    @property
    def tst_tmsp_ovf(self):
        return self._comp.get_bit(IuventusTestRegMap.TST_SEQ_RAND_SEL.value, 2)

    @tst_tmsp_ovf.setter
    def tst_tmsp_ovf(self, val: bool):
        self._comp.set_bit(IuventusTestRegMap.TST_SEQ_RAND_SEL.value, 2, val)

    @property
    def tst_mode(self):
        val = self._comp.get_bit(IuventusTestRegMap.TST_SEQ_RAND_SEL.value, 1)
        return "wr" if (val & 0x1) == 0 else "rd"

    @tst_mode.setter
    def tst_mode(self, val: str):
        if val == "wr":
            self._comp.set_bit(IuventusTestRegMap.TST_SEQ_RAND_SEL.value, 1, False)
        elif val == "rd":
            self._comp.set_bit(IuventusTestRegMap.TST_SEQ_RAND_SEL.value, 1, True)
        else:
            raise ValueError("Invalid value for tst_mode. Expected 'wr' or 'rd'.")

    @property
    def tst_addressing(self):
        val = self._comp.get_bit(IuventusTestRegMap.TST_SEQ_RAND_SEL.value, 0)
        return "seq" if (val & 0x1) == 0 else "rand"

    @tst_addressing.setter
    def tst_addressing(self, val: str):
        if val == "seq":
            self._comp.set_bit(IuventusTestRegMap.TST_SEQ_RAND_SEL.value, 0, False)
        elif val == "rand":
            self._comp.set_bit(IuventusTestRegMap.TST_SEQ_RAND_SEL.value, 0, True)
        else:
            raise ValueError("Invalid value for tst_addressing. Expected 'seq' or 'rand'.")

    @property
    def contig_test(self):
        return self._comp.get_bit(IuventusTestRegMap.TST_SEQ_RAND_SEL.value, 3)

    @contig_test.setter
    def contig_test(self, val: bool):
        self._comp.set_bit(IuventusTestRegMap.TST_SEQ_RAND_SEL.value, 3, val)

    @property
    def evcr_interval_cycles(self):
        return self._comp.read32(IuventusTestRegMap.EVCR_INTERVAL_CYCLES.value)

    @evcr_interval_cycles.setter
    def evcr_interval_cycles(self, val: int):
        # assert val <= 2**28 and val > 2**12, "Interval cycles must fit in 29 bits and be greater than 4096"
        self._comp.write32(IuventusTestRegMap.EVCR_INTERVAL_CYCLES.value, val)

    @property
    def evcr_total_events(self):
        return self._comp.read32(IuventusTestRegMap.ECVR_TOTAL_EVENTS.value)

    @property
    def evcr_total_cycles(self):
        return self._comp.read32(IuventusTestRegMap.EVCR_TOTAL_CYCLES.value)

    @property
    def rd_ch_min(self):
        return self._comp.read16(IuventusTestRegMap.RD_CH_MINMAX.value)

    @rd_ch_min.setter
    def rd_ch_min(self, val: int):
        # Reg layout: [15:0] = min channel (QID), [31:16] = max channel (QID)
        val &= 0xFFFF
        self._comp.write32(IuventusTestRegMap.RD_CH_MINMAX.value, (self.rd_ch_max << 16) | val)

    @property
    def rd_ch_max(self):
        return self._comp.read16(IuventusTestRegMap.RD_CH_MINMAX.value + 2)

    @rd_ch_max.setter
    def rd_ch_max(self, val: int):
        # Reg layout: [15:0] = min channel (QID), [31:16] = max channel (QID)
        val &= 0xFFFF
        self._comp.write32(IuventusTestRegMap.RD_CH_MINMAX.value, (val << 16) | self.rd_ch_min)

    @property
    def rd_burst(self):
        return self._comp.read32(IuventusTestRegMap.RD_BURST.value)

    @rd_burst.setter
    def rd_burst(self, val: int):
        self._comp.write32(IuventusTestRegMap.RD_BURST.value, val)

    def set_rd_channel_range(self, ch_min: int, ch_max: int):
        """Set the read-request round-robin channel (QID) range [ch_min, ch_max] with a
        single 32-bit write to RD_CH_MINMAX (reg 0x58: [15:0] = min, [31:16] = max)."""
        ch_min &= 0xFFFF
        ch_max &= 0xFFFF
        self._comp.write32(IuventusTestRegMap.RD_CH_MINMAX.value, (ch_max << 16) | ch_min)

    def set_wr_channel_range(self, ch_min: int, ch_max: int):
        """Set the write-side (MFB_GENERATOR_MI32) round-robin channel range [ch_min, ch_max]."""
        self.gen.minimum_channel = ch_min
        self.gen.maximum_channel = ch_max

    def set_queue_range(self, num_queues: int):
        """Confine both read and write request generation to queues 0..num_queues-1."""
        assert num_queues >= 1, "num_queues must be at least 1"
        self.set_rd_channel_range(0, num_queues - 1)
        self.set_wr_channel_range(0, num_queues - 1)

    def iops(self):
        total_events = self.evcr_total_events
        total_cycles = self.evcr_total_cycles
        if total_cycles == 0:
            return 0
        return total_events / (total_cycles * self.clk_period)

    def disp_rd_req(self, lba_ptr: int, lba_num: int):
        assert lba_num < 256, "LBA number must fit in 8 bits"
        self.rd_req_lba_ptr = lba_ptr
        self.rd_req_lba_num = lba_num
        self.rd_req_vld = True

    def disp_wr_req(self, lba_ptr: int, lba_num: int, burst_size: int = 1):
        assert lba_num < 256, "LBA number must fit in 8 bits"
        assert burst_size < 2**16 and burst_size > 0, "Burst size must fit in 16 bits and be greater than 0"
        self.wr_req_lba_ptr = lba_ptr
        self.gen.frame_length = (lba_num+1) * 512
        self.gen.burst_size = burst_size
        self.gen.enabled = False
        self.gen.enabled = True

    def dump_regs(self):
        print(f"VLD:               {self.rd_req_vld}")
        print(f"RDY:               {self.rd_req_rdy}")
        print(f"RD_REQ_LBA_PTR:    {self.rd_req_lba_ptr:#018x}")
        print(f"RD_REQ_LBA_NUM:    {self.rd_req_lba_num}")
        print(f"WR_REQ_LBA_PTR:    {self.wr_req_lba_ptr:#018x}")
        print(f"OP_VLD:            {self.op_stat_reg[2] != 0} -> OP_TYPE: {'WR' if self.op_stat_reg[1] == 0 else 'RD'}, OP_CODE: {bin(self.op_stat_reg[0])}")
        print(f"TST_ITERATIONS:    {self.tst_iterations}")
        print(f"TST_SEL:           MODE: {self.tst_mode}, ADDRESSING: {self.tst_addressing}")
        print(f"TST_TMSP_OVF:      {self.tst_tmsp_ovf}")
        print(f"CONTIG_TEST:       {self.contig_test}")
        print(f"EVCR_INTERVAL:     {self.evcr_interval_cycles} cycles")
        print(f"EVCR_TOTAL_EVENTS: {self.evcr_total_events}")
        print(f"EVCR_TOTAL_CYCLES: {self.evcr_total_cycles}")
        print(f"RD_CH_MIN/MAX:     {self.rd_ch_min}/{self.rd_ch_max}")
        print(f"RD_BURST:          {self.rd_burst}")


class LatencyMeter(DataLogger):
    DT_COMPATIBLE = "netcope,latency_meter"

    def __init__(self, test_comp : IuventusTest, **kwargs):
        super().__init__(**kwargs)
        self.test_comp = test_comp

    def is_tst_finished(self):
        formatstr = "{:0" + str(self.config["CTRLI_WIDTH"]) + "b}"
        ctrli_vec = formatstr.format(self.load_ctrl(False))
        fin_flag = (int(ctrli_vec[0]) == 1)
        return fin_flag

    def save_histograms(self,fname):
        # Save measured values to JSON data to file
        output_file_path = '{}.json'.format(fname)
        stats_data = json.loads(self.stats_to_str(hist=True))
        with open(output_file_path, 'w') as output_file:
            json.dump(stats_data, output_file, indent=2)

    def run_test_suite(self, combs, iterations):
        conf_data = json.loads(self.config_to_str())
        with open('meas_conf.json', 'w') as output_file:
            json.dump(conf_data, output_file, indent=2)

        # Cleared in the finally below so a failed/interrupted run cannot leave the generator
        # throttled for later throughput tests.
        try:
            for key, (mode, addressing, size) in combs.items():
                print(f"Running test with size {size}, mode {mode}, and addressing {addressing}")
                self.test_comp.rd_req_lba_num = size
                self.test_comp.tst_mode = mode
                self.test_comp.tst_addressing = addressing

                # AFTER tst_mode/tst_addressing: both write TST_SEQ_RAND_SEL, so arming last keeps
                # this correct. QD1 is required -- LATENCY_METER pairs starts to completions
                # positionally, with no tag, so concurrency reports a wrong latency.
                self.test_comp.lat_meas_mode = True
                assert self.test_comp.lat_meas_mode, \
                    "lat_meas_mode did not stick -- the run would over-issue and hang"

                self.test_comp.tst_iterations = iterations-1

                if mode == "wr":
                    # Burst mode explicitly: the generator emits exactly burst_size packets and
                    # stops. Do NOT inherit it: _throughput_point_start sets bursting=False, so a
                    # later latency run would face a free-running generator, breaking
                    # one-command-in-flight.
                    self.test_comp.gen.bursting = True
                    self.test_comp.disp_wr_req(0, size, iterations)

                sleep(0.3)
                while not self.is_tst_finished():
                    sleep(0.1)
                    pass

                self.save_histograms(key)
                self.rst()
        finally:
            self.test_comp.lat_meas_mode = False


# --- Importable run-logic, factored out of main() below ---
# These take an ALREADY-OPEN IuventusTest/LatencyMeter plus parsed parameters -- no argparse, no
# nfb.open() -- so main()'s CLI handlers and a cocotb testbench drive the same code paths.

class FzcNotRunning(RuntimeError):
    """The design is not enabled, so no traffic can flow and every rate would read zero."""


def assert_fzc_running(test: IuventusTest) -> None:
    """Refuse to start a measurement unless fzc has enabled the design.

    fzc owns CONTROL bit 0: it sets it once the SQ/CQ/buffers are up and the drives are attached.
    Without it the generator has nowhere to send requests, so a sweep runs its full duration and
    reports zeros -- which reads as a catastrophic result rather than as a setup mistake. That
    happened for 12 minutes on 2026-09-05 after a fabric reload left the FPGA's PF1 unbound and
    fzc could not attach; the probe loop kept going and produced nothing.
    """
    # Reached through the test object's OWN device handle. Opening a second one with nfb.open()
    # makes every counter read back zero, which would turn this guard into the fault it detects.
    dma = getattr(test, "_dma_ctl_comp", None)
    if dma is None:
        dma = test._dev.comp_open("ziti,dma_iuventus", 0)
        test._dma_ctl_comp = dma
    ctl = dma.read16(0x00)
    if not (ctl & 1):
        raise FzcNotRunning(
            "DMA Iuventus CONTROL=0x%04x: bit 0 clear, so fzc has not enabled the design. "
            "Start fzc and wait for CONTROL & 1 before measuring. If fzc exited with "
            "'Cannot find device', the FPGA's PF1 is unbound -- rebind it to uio_pci_generic "
            "and set COMMAND=0x406." % ctl)


def run_read_dispatch(test: IuventusTest, lba_ptr: int, lba_num: int) -> None:
    """CLI '-r LBA_PTR LBA_NUM': dispatch one manual read request."""
    assert_fzc_running(test)
    test.disp_rd_req(lba_ptr, lba_num)


def run_write_dispatch(test: IuventusTest, lba_ptr: int, lba_num: int, burst_size: int = 1) -> None:
    """CLI '-w LBA_PTR LBA_NUM': dispatch one write frame (or a free-running burst if
    burst_size > 1, matching IuventusTest.disp_wr_req's own semantics)."""
    assert_fzc_running(test)
    test.disp_wr_req(lba_ptr, lba_num, burst_size)


def run_latency(
    lmeter: "LatencyMeter", lm_output: "LatencyMeterOutput", mode: str, iterations: int,
    addressing: str, size: int,
) -> None:
    """CLI '-l TYPE ITERATIONS ADDRESSING LBA_NUM': measure and report the latency of one
    mode/addressing/size combination."""
    assert_fzc_running(test)
    # Pin to one queue: unlike -t and --profile, this path sets no range on its own, so it would
    # otherwise inherit a prior multi-queue sweep's and mix SSDs into one figure. QD1 already
    # makes the meter's pairing exact; this makes it single-drive.
    lmeter.test_comp.set_queue_range(1)

    tst_comb = {f"{mode}_{addressing}_{size}": (mode, addressing, size)}
    lmeter.run_test_suite(tst_comb, iterations)
    lm_output.process_results_by_structure(tst_comb)


def _throughput_point_start(test: IuventusTest, mode: str, addressing: str, size: int) -> None:
    """Arms one throughput measurement point (mode/addressing/size): configures the test-mode
    registers and, for writes, dispatches the free-running generator via disp_wr_req -- exactly
    the setup the CLI's -t sweep performs for every point of the sweep."""
    assert_fzc_running(test)
    test.tst_addressing = addressing
    test.tst_mode = mode

    if mode == "wr":
        test.contig_test = True
        test.gen.bursting = False
        test.disp_wr_req(0, size, 64)
    else:
        test.rd_req_lba_num = size
        test.contig_test = True


def _throughput_point_stop(test: IuventusTest, mode: str, sleep_fn=sleep) -> None:
    """Disarms one throughput measurement point and waits for the generator/read-request path to
    fully quiesce before the next point starts -- exactly the CLI's own between-points teardown."""
    if mode == "wr":
        test.gen.enabled = False
        test.gen.bursting = True
        test.contig_test = False

        while test.gen.generating:
            sleep_fn(0.1)
    else:
        test.contig_test = False
        while test.rd_req_vld:
            sleep_fn(0.1)


def run_throughput_point(
    test: IuventusTest, mode: str, addressing: str, size: int,
    settle_seconds: float = 3.0, sleep_fn=sleep,
):
    """Runs ONE throughput measurement point (start -> settle -> sample -> stop), returning
    (iops, throughput_bps). This is the exact per-combo body of the CLI's -t sweep, factored out
    so it can also be driven
    point-by-point -- e.g. by a testbench substituting a simulated settle wait (advancing DMA_CLK
    cycles) for the wall-clock sleep_fn used on real hardware."""
    _throughput_point_start(test, mode, addressing, size)
    if settle_seconds > 0:
        sleep_fn(settle_seconds)
    iops = test.iops()
    # Throughput is derived from IOPS (the EVENT_COUNTER), not measured with an MFB speed meter:
    # `sectors` is the request size in 512 B sectors (size is 0-based, matching the
    # (lba_num+1)*512 formula used in build_throughput_iops_booktabs_table).
    sectors = size + 1
    throughput_bps = iops * sectors * 512
    _throughput_point_stop(test, mode, sleep_fn=sleep_fn)
    return iops, throughput_bps


# Stall-profiler MI offsets, first five keeping plot_stall_profile.py's r() order. ALLOC_WAIT
# (0x0AC) is the read-side allocator stall; ALLOC_WR and ALLOC_RD_PEND carry the other two
# allocator stalls OP_CTRL can be in (see the DMA core's own docs).
PROF_CLASS_REGS = [("DISP_SQ", 0x0A4), ("ALLOC_WAIT", 0x0AC), ("DISP_TAG", 0x0B4),
                   ("DATA_WAIT", 0x0BC), ("BUSY", 0x0C4), ("ALLOC_WR", 0x170),
                   ("ALLOC_RD_PEND", 0x178)]
# Elapsed cycles, free-running while the counters are not reset. THE denominator: the classes
# above leave an idle cycle unscored, so their sum is an unknown-size window -- a share reads the
# same whether the DMA saturated or did eight cycles of work.
PROF_ELAPSED_REG = 0x158
PROF_SIZES = [(7, "4K"), (31, "16K"), (255, "128K")]


def _profile_sample_faults(mode, iops, elapsed, classified, delta, commands):
    """Self-contradictions that make one profile point unusable, as a list of reasons.

    These are checks against the RTL, not thresholds: OP_PROF sets at most one bit per cycle, so
    classified can never exceed elapsed, every accepted write sets DATA_WAIT for at least one
    cycle, and every completed command occupies at least one classified cycle."""
    faults = []
    if elapsed <= 0:
        faults.append("TOTAL_CYCLES did not advance: no window to score against")
    elif classified > elapsed:
        faults.append("classified %d > elapsed %d cycles: the counters are not one window"
                      % (classified, elapsed))
    backwards = sorted(k for k, v in delta.items() if v < 0)
    if backwards:
        faults.append("%s counted backwards: the counters were reset inside the window"
                      % ", ".join(backwards))
    if iops <= 0:
        faults.append("no completions in the window: nothing was profiled")
    else:
        if mode == "wr" and delta["DATA_WAIT"] == 0:
            faults.append("write point with IOPS=%d but DATA_WAIT=0: no write was accepted "
                          "while these counters ran" % iops)
        if classified < commands:
            faults.append("classified %d cycles < %d commands completed: at least one classified "
                          "cycle per command is structural, so the counters missed the traffic"
                          % (classified, int(commands)))
    return faults


# Short enough that several windows close inside one measurement point: a too-long interval can
# straddle the point's start and score the ramp as steady state, or (for the throughput sweep)
# read a rate mostly covering earlier points.
EVCR_WINDOW_CYCLES = 1 << 20


def _evcr_rate(test, seconds, sleep_fn):
    """Median EVENT_COUNTER rate over the windows that close while the load runs.

    The rate is TOTAL_EVENTS/(TOTAL_CYCLES*clk_period), both read from the core, so the host sleep
    below is a settle delay and never a divisor -- a wall-clock rate silently absorbs every pause
    the host takes between reads.
    """
    samples, last = [], None
    slices = max(1, int(seconds / 0.25))
    for _ in range(slices):
        sleep_fn(seconds / slices)
        pair = (test.evcr_total_events, test.evcr_total_cycles)
        if pair != last and pair[0] and pair[1]:
            samples.append(pair[0] / (pair[1] * test.clk_period))
        last = pair
    return statistics.median(samples) if samples else 0.0


def run_stall_profile(test, queues: int, settle_seconds: float = 3.0, results_file=None,
                      sleep_fn=sleep, verbose: bool = True):
    """CLI '-p': DMA stall-class breakdown across read/write x rand/seq x 4K/16K/128K.

    Requires firmware built with PROFILE_EN -- without it every counter reads zero, which the
    per-point checks below then reject rather than render as a breakdown.

    IOPS comes from the core's EVENT_COUNTER, not a host clock. Percentages are shares of ELAPSED
    cycles (TOTAL_CYCLES over the same window) and 'idle' is the unclassified remainder, so a
    point where the DMA did almost nothing reads as almost all idle instead of as a full-looking
    stall breakdown. Every row also carries the raw cycle counts it was computed from.
    """
    assert_fzc_running(test)
    import nfb
    from ofm.comp.dma.iuventus.iuventus_reg_access import DMAIuventusRegAccess

    # test._dev may already be an open Nfb handle (the cocotb TB passes one) or a device string.
    dev = getattr(test, "_dev", "0")
    handle = dev if isinstance(dev, nfb.Nfb) else nfb.open(dev if isinstance(dev, str) else "0")
    dma = handle.comp_open("ziti,dma_iuventus", 0)
    reg = DMAIuventusRegAccess(dev="0")
    test.set_queue_range(queues)

    def snap():
        # One SAMPLE_CNTRS strobe latches every counter, so the classes and the elapsed count
        # below come from the same instant and are subtractable against another snapshot.
        reg.sample_cntrs()
        out = {name: dma.read64(addr) for name, addr in PROF_CLASS_REGS}
        out["ELAPSED"] = dma.read64(PROF_ELAPSED_REG)
        return out

    rows = []
    for mode in ("rd", "wr"):
        for addressing in ("rand", "seq"):
            for size, blk in PROF_SIZES:
                # _throughput_point_start sets contig_test on both paths: contiguous stream.
                _throughput_point_start(test, mode, addressing, size)
                test.evcr_interval_cycles = EVCR_WINDOW_CYCLES
                sleep_fn(0.5)
                before = snap()
                rate = _evcr_rate(test, settle_seconds, sleep_fn)
                after = snap()
                _throughput_point_stop(test, mode, sleep_fn=sleep_fn)
                sleep_fn(0.5)

                delta = {k: after[k] - before[k] for k, _ in PROF_CLASS_REGS}
                elapsed = after["ELAPSED"] - before["ELAPSED"]
                classified = sum(delta.values())
                iops = int(rate)
                # Commands the core completed inside this very window, from the window's own
                # length -- a host sleep is never the divisor.
                commands = iops * elapsed * test.clk_period
                faults = _profile_sample_faults(mode, iops, elapsed, classified, delta, commands)
                pct = {k: round(100.0 * v / elapsed, 1) if elapsed > 0 else 0.0
                       for k, v in delta.items()}
                idle_pct = round(100.0 * (elapsed - classified) / elapsed, 1) if elapsed > 0 else 0.0
                rows.append(dict(N=queues, mode=mode, addressing=addressing, blk=blk,
                                 iops=iops, pct=pct, idle_pct=idle_pct, raw=delta,
                                 elapsed=elapsed, classified=classified, valid=not faults,
                                 faults=faults))
                if verbose:
                    print('  %s %s %s N%d: iops=%d elapsed=%d classified=%d idle=%.1f%% raw=%s' % (
                        blk, mode, addressing, queues, iops, elapsed, classified, idle_pct,
                        delta), flush=True)
                    if faults:
                        # Printed instead of the pasteable row: a point that contradicts the RTL
                        # must not reach a plot by being copied out of this log.
                        for fault in faults:
                            print('  !! REJECTED %s %s %s N%d: %s' % (
                                blk, mode, addressing, queues, fault), flush=True)
                    else:
                        print('  r(%d, %-7s %8d, %5.1f, %5.1f, %5.1f, %5.1f, %5.1f),  # %s %s, '
                              'idle %.1f%%, alloc_wr %.1f%%, alloc_rd_pend %.1f%%' % (
                                  queues, '"%s",' % blk, iops, pct["DISP_SQ"], pct["ALLOC_WAIT"],
                                  pct["DISP_TAG"], pct["DATA_WAIT"], pct["BUSY"], mode,
                                  addressing, idle_pct, pct["ALLOC_WR"], pct["ALLOC_RD_PEND"]),
                              flush=True)

    if results_file:
        with open(results_file, "w") as handle:
            json.dump(rows, handle, indent=2)
        if verbose:
            print("Saved stall profile to %s" % results_file)
    return rows


def run_throughput(
    test: IuventusTest, queues: int, tst_comb=None, settle_seconds: float = 3.0,
    sleep_fn=sleep, results_file=None, verbose: bool = True,
):
    """CLI '-t [--queues N]': the full throughput sweep across mode x addressing x size (the
    default combination list, or an explicit tst_comb override), returning the same list-of-dict
    `results` structure save_throughput_results()/generate_throughput_outputs() expect."""
    assert_fzc_running(test)
    assert queues >= 1, "--queues must be at least 1"
    test.evcr_interval_cycles = EVCR_WINDOW_CYCLES
    # Confine both read and write request generation to queues 0..queues-1 so traffic is spread
    # across exactly this many SSD-backed queues. With queues=1 (the default) this reproduces the
    # previous single-queue-only behavior exactly.
    test.set_queue_range(queues)

    if tst_comb is None:
        tst_modes = ["rd", "wr"]
        tst_addr_modes = ["seq", "rand"]
        tst_sizes = [0, 1, 3, 7, 15, 31, 63, 127, 255]
        tst_comb = {
            f"{mode}_{addressing}_{size}": (mode, addressing, size)
            for mode in sorted(tst_modes) for addressing in sorted(tst_addr_modes) for size in sorted(tst_sizes)
        }

    # Deliberately no warmup point: one would race _throughput_point_stop's drain wait and could
    # hang if the generator hadn't started yet. Every real point already settles, so a warmup buys
    # nothing.

    results = []
    for key, (mode, addressing, size) in tst_comb.items():
        iops, throughput_bps = run_throughput_point(
            test, mode, addressing, size, settle_seconds=settle_seconds, sleep_fn=sleep_fn
        )
        if verbose:
            thrp_val, thrp_unit = convert_units(throughput_bps)
            print(f"{key} (queues={queues}): IOps: {iops:.0f}, Thrp: {thrp_val:.2f} {thrp_unit}Bps")
        results.append({
            "mode": mode,
            "addressing": addressing,
            "lba_num": size,
            "iops": iops,
            "throughput_bps": throughput_bps,
            "num_queues": queues,
        })

    if results_file:
        save_throughput_results(results, results_file)
        if verbose:
            print(f"Saved throughput results to {results_file}")

    return results


def parseParams():
    import argparse
    parser = argparse.ArgumentParser(description="Test script for the Iuventus test component")
    parser.add_argument('-d', '--device', default=nfb.libnfb.Nfb.default_dev_path,
                        metavar='device', help = "Index of a NFB device")
    # parser.add_argument('-i', '--index', type=int, metavar='index', default=0, help = "Index of the component in the Device Tree")
    parser.add_argument('-r', nargs=2, metavar=('LBA_PTR', 'LBA_NUM'), help="Display a read request with the given LBA pointer and number of LBAs")
    parser.add_argument('-w', nargs=2, metavar=('LBA_PTR', 'LBA_NUM'), help="Display a write request with the given LBA pointer and number of LBAs")
    parser.add_argument('-v', '--verbose', action='count', default=0, help="Print the current register values")
    parser.add_argument('-l', '--latency' ,nargs=4, metavar=("TYPE", "ITERATIONS", "ADDRESSING", "LBA_NUM"), help="Measure and print the latency of read and write requests")
    parser.add_argument('-m', '--measure', action='store_true', help="Measure the latency of read and write requests and save histograms to JSON files")
    parser.add_argument('--iterations', type=int, default=10000, help="Number of iterations for latency measurement (default: 10000)")
    parser.add_argument('--rst', action='store_true', help="Reset the latency meter before starting the test")
    parser.add_argument('-t', '--throughput', action='store_true', help="Measure and print the throughput of read and write requests")
    # long-only: -p is already taken by --process
    parser.add_argument('--profile', action='store_true',
                        help="Collect the DMA stall-class profile (needs PROFILE_EN firmware)")
    parser.add_argument('--profile-results-file', default='stall_profile.json',
                        help='Path to the stall-profile results JSON')
    parser.add_argument('-p', '--process', action='store_true', help="Process the measurement results and generate graphs")
    parser.add_argument('--throughput-results-file', default='throughput_results.json',
                        help='Path to throughput results JSON file (used for saving and loading)')
    parser.add_argument('--throughput-from-file', action='store_true',
                        help='Load throughput results from --throughput-results-file and generate plots/table')
    parser.add_argument('--queues', type=int, default=1,
                        help='Number of SSD-backed queues (0..N-1) to spread throughput traffic across (default: 1)')

    return parser.parse_args()

if __name__ == "__main__":
    args = parseParams()

    if args.throughput_from_file:
        results = load_throughput_results(args.throughput_results_file)
        output_dir = os.path.dirname(args.throughput_results_file) or "."
        generate_throughput_outputs(results, out_dir=output_dir)
        sys.exit(0)

    # Before anything opens the device. --throughput-from-file returns above and never touches
    # hardware, so it deliberately does not take the lock.
    acquire_device_lock(args.device)

    test = IuventusTest(dev=args.device, index=0)
    lmeter = LatencyMeter(test, dev=args.device, index=0)
    lm_output = LatencyMeterOutput(clk_period=4)

    if args.rst:
        lmeter.rst()
        test.tst_tmsp_ovf = False
        test.gen.enabled = False
        test.gen.bursting = True
        test.contig_test = False
        sys.exit(0)

    if args.latency:
        assert args.latency[0].lower() in ["rd", "wr"], "TYPE must be either RD or WR"
        assert args.latency[1].isdigit(), "ITERATIONS must be a positive integer"
        assert args.latency[2].lower() in ["seq", "rand"], "ADDRESSING must be either SEQ or RAND"
        assert args.latency[3].isdigit(), "LBA_NUM must be a positive integer"

        size = int(args.latency[3])
        mode, addressing = args.latency[0].lower(), args.latency[2].lower()
        # This argument has to be the last so the measurement begins (the measurement of write is exception)
        iterations = int(args.latency[1])
        run_latency(lmeter, lm_output, mode, iterations, addressing, size)
        sys.exit(0)

    if args.measure or args.process:
        tst_modes = ["rd", "wr"]
        tst_addr_modes = ["seq", "rand"]
        # tst_sizes = [0, 1, 3, 7, 15, 31, 63, 127, 255]
        tst_sizes = [0, 7, 63, 255]
        tst_comb = {f"{mode}_{addressing}_{size}": (mode, addressing, size) for mode in sorted(tst_modes) for addressing in sorted(tst_addr_modes) for size in sorted(tst_sizes)}
        # print(f"Test combinations: {tst_comb}")

        if args.measure:
            lmeter.run_test_suite(tst_comb, args.iterations)
        if args.process:
            lm_output.process_results_by_structure(tst_comb)
        sys.exit(0)

    if args.profile:
        run_stall_profile(test, args.queues, results_file=args.profile_results_file)

    if args.throughput:
        results = run_throughput(test, args.queues, results_file=args.throughput_results_file)
        output_dir = os.path.dirname(args.throughput_results_file) or "."
        generate_throughput_outputs(results, out_dir=output_dir)
        sys.exit(0)

    if args.r:
        assert args.r[0].isdigit() and args.r[1].isdigit(), "LBA_PTR and LBA_NUM must be integers"
        run_read_dispatch(test, int(args.r[0]), int(args.r[1]))
        sys.exit(0)
    if args.w:
        assert args.w[0].isdigit() and args.w[1].isdigit(), "LBA_PTR and LBA_NUM must be integers"
        run_write_dispatch(test, int(args.w[0]), int(args.w[1]))
        sys.exit(0)

    if args.verbose >= 1:
        test.dump_regs()

    if args.verbose >= 2:
        print(lmeter.stats_to_str(hist=True))