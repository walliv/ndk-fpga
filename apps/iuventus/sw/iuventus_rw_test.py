#!/usr/bin/env python3

import sys
import json
import os
from enum import IntEnum
from time import sleep

import nfb
from ofm.comp.debug.data_logger.data_logger import DataLogger
from ofm.comp.mfb_tools.debug.generator import MfbGenerator
from ofm.comp.mfb_tools.logic.speed_meter import SpeedMeter
import ofm.comp.dma.latency_meas.calam_graph
from ofm.utils import convert_units


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


def build_throughput_plots(results, out_dir="."):
    os.makedirs(out_dir, exist_ok=True)

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
        out_base_path = os.path.join(out_dir, file_stem)
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


def build_iops_plots(results, out_dir="."):
    os.makedirs(out_dir, exist_ok=True)

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
        out_base_path = os.path.join(out_dir, file_stem)
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

    plot_paths = build_throughput_plots(results, out_dir=out_dir)
    for path in plot_paths:
        print(f"Saved plot to {path}")

    iops_plot_paths = build_iops_plots(results, out_dir=out_dir)
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

        for key, (mode, addressing, size) in combs.items():
            print(f"Running test with size {size}, mode {mode}, and addressing {addressing}")
            self.test_comp.rd_req_lba_num = size
            self.test_comp.tst_mode = mode
            self.test_comp.tst_addressing = addressing
            self.test_comp.tst_iterations = iterations-1

            if mode == "wr":
                self.test_comp.disp_wr_req(0, size, iterations)

            sleep(0.3)
            while not self.is_tst_finished():
                sleep(0.1)
                pass

            self.save_histograms(key)
            self.rst()


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

    test = IuventusTest(dev=args.device, index=0)
    lmeter = LatencyMeter(test, dev=args.device, index=0)
    lm_output = LatencyMeterOutput(clk_period=4)
    nvme_rd_sm = SpeedMeter(dev=args.device, index=0)
    nvme_wr_sm = SpeedMeter(dev=args.device, index=1)
    print(f"{nvme_rd_sm._node.path=}, {nvme_rd_sm._node.name=}")
    print(f"{nvme_wr_sm._node.path=}, {nvme_wr_sm._node.name=}")

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
        tst_comb = {f"{mode}_{addressing}_{size}": (mode, addressing, size)}
        lmeter.run_test_suite(tst_comb, iterations)
        lm_output.process_results_by_structure(tst_comb)
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

    if args.throughput:
        assert args.queues >= 1, "--queues must be at least 1"
        test.evcr_interval_cycles = 0xFFFFFFFF
        # Confine both read and write request generation to queues 0..args.queues-1 so
        # traffic is spread across exactly this many SSD-backed queues. With --queues 1
        # (the default) this reproduces the previous single-queue-only behavior exactly.
        test.set_queue_range(args.queues)
        tst_modes = ["rd", "wr"]
        tst_addr_modes = ["seq", "rand"]
        tst_sizes = [0, 1, 3, 7, 15, 31, 63, 127, 255]
        tst_comb = {f"{mode}_{addressing}_{size}": (mode, addressing, size) for mode in sorted(tst_modes) for addressing in sorted(tst_addr_modes) for size in sorted(tst_sizes)}
        results = []
        # tst_comb = {"rd_seq_0" : ("rd", "seq", 0)}

        warmup_key, (warmup_mode, warmup_addressing, warmup_size) = next(iter(tst_comb.items()))
        print(f"Running warmup throughput measurement: {warmup_key} (queues={args.queues})")
        nvme_rd_sm.clear_data()
        nvme_wr_sm.clear_data()
        test.tst_addressing = warmup_addressing
        test.tst_mode = warmup_mode

        if warmup_mode == "wr":
            test.contig_test = True
            test.gen.bursting = False
            test.disp_wr_req(0, warmup_size, 64)
        else:
            test.rd_req_lba_num = warmup_size
            test.contig_test = True

        nvme_rd_sm.measure()
        nvme_wr_sm.measure()

        if warmup_mode == "wr":
            test.gen.enabled = False
            test.gen.bursting = True
            test.contig_test = False

            while test.gen.generating:
                sleep(0.1)
        else:
            test.contig_test = False
            while test.rd_req_vld:
                sleep(0.1)

        print("Warmup throughput measurement done, collecting results...")

        for key, (mode, addressing, size) in tst_comb.items():
            nvme_rd_sm.clear_data()
            nvme_wr_sm.clear_data()
            test.tst_addressing = addressing
            test.tst_mode = mode

            if mode == "wr":
                test.contig_test = True
                test.gen.bursting = False
                test.disp_wr_req(0, size, 64)
            else:
                test.rd_req_lba_num = size
                test.contig_test = True

            # sleep(0.1)
            # sleep(5)
            sleep(3)
            rd_throughput, _ = nvme_rd_sm.measure()
            rd_thrp_val, rd_thrp_unit = convert_units(rd_throughput)
            # print(f"{nvme_rd_sm.frequency=}, {nvme_rd_sm.items=}, {nvme_rd_sm.ticks=}, {nvme_rd_sm.sofs=}, {nvme_rd_sm.eofs=}")
            wr_throughput, _ = nvme_wr_sm.measure()
            wr_thrp_val, wr_thrp_unit = convert_units(wr_throughput)
            # print(f"{nvme_wr_sm.frequency=}, {nvme_wr_sm.items=}, {nvme_wr_sm.ticks=}, {nvme_wr_sm.sofs=}, {nvme_wr_sm.eofs=}")
            throughput = wr_throughput if mode == "wr" else rd_throughput
            iops = test.iops()
            print(f"{key} (queues={args.queues}): IOps: {iops:.0f}, RD Thrp: {rd_thrp_val:.2f} {rd_thrp_unit}Bps, "
                  f"WR Thrp: {wr_thrp_val:.2f} {wr_thrp_unit}Bps")
            results.append({
                "mode": mode,
                "addressing": addressing,
                "lba_num": size,
                "iops": iops,
                "throughput_bps": throughput,
                "num_queues": args.queues,
            })

            if mode == "wr":
                test.gen.enabled = False
                test.gen.bursting = True
                test.contig_test = False

                while test.gen.generating:
                    sleep(0.1)
            else:
                test.contig_test = False
                while test.rd_req_vld:
                    sleep(0.1)

        save_throughput_results(results, args.throughput_results_file)
        print(f"Saved throughput results to {args.throughput_results_file}")
        output_dir = os.path.dirname(args.throughput_results_file) or "."
        generate_throughput_outputs(results, out_dir=output_dir)

        sys.exit(0)

    if args.r:
        assert args.r[0].isdigit() and args.r[1].isdigit(), "LBA_PTR and LBA_NUM must be integers"
        test.disp_rd_req(int(args.r[0]), int(args.r[1]))
        sys.exit(0)
    if args.w:
        assert args.w[0].isdigit() and args.w[1].isdigit(), "LBA_PTR and LBA_NUM must be integers"
        test.disp_wr_req(int(args.w[0]), int(args.w[1]))
        sys.exit(0)

    if args.verbose >= 1:
        test.dump_regs()

    if args.verbose >= 2:
        print(lmeter.stats_to_str(hist=True))