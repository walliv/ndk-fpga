import os
import json
import matplotlib.pyplot as plt
import numpy as np
from scipy.ndimage import gaussian_filter1d

def format_time_value(value):
    return value / 1e3, 'us'

class LatencyMeterOutput():

    def __init__(self, clk_period=4):
        self.clk_period = clk_period

    def process_results_by_structure(self,tests):

        tst_grps = {}

        for tst_name, tst_params in tests.items():
            for grp_idx in tst_params[5]:
                print("Adding item: ", tst_name, ",", grp_idx)
                tst_grps.setdefault(grp_idx, []).append((tst_name, f"./{tst_name}.json"))

        self.load_config_user("./meas_conf.json")

        for grp_idx,tst_row in tst_grps.items():
            print("Processed test row: ", tst_row)
            self.draw_cumdib(tst_row)

    def process_results_by_file(self, filelist, output_name="graph"):

        tst_grps = {}

        for file_name in filelist:
            if (file_name.endswith(".json") and file_name != "meas_conf.json"):
                fname = os.path.basename(file_name)
                tst_name, _ = os.path.splitext(fname)
                print(f"{tst_name=}")
                tst_grps.setdefault(0, []).append((tst_name, file_name))

        for _, tst_row in tst_grps.items():
            print("Processed test row: ", tst_row)
            self.draw_cumdib(tst_row, output_name)

    def load_config_user(self, conf_file=""):

        conf_data = json.load(open(conf_file))

        # Extract histogram information
        self.hist_box_cnt = conf_data["HIST_BOX_CNT"][0]
        self.hist_box_width = conf_data["HIST_BOX_WIDTH"][0]
        self.hist_step = conf_data["HIST_STEP"][0]

    def _parse_tst_name(self, tst_name):
        parts = tst_name.split("_")
        if len(parts) >= 3:
            mode = parts[0].lower()
            addressing = parts[1].lower()
            size = parts[2]
            if mode in ["rd", "wr"] and addressing in ["seq", "rand"] and size.isdigit():
                op = "RD" if mode == "rd" else "WR"
                access = "Sequential" if addressing == "seq" else "Random"
                return op, access, int(size)+1
        return None, None, None

    def write_latex_table(self, latex_rows, output_file="latency_results_table.tex"):
        if not latex_rows:
            return

        op_order = {"RD": 0, "WR": 1}
        access_order = {"Random": 0, "Sequential": 1}
        sorted_rows = sorted(
            latex_rows,
            key=lambda row: (
                op_order.get(row["op"], 99),
                access_order.get(row["access"], 99),
                row["size"]
            )
        )

        lines = [
            r"\begin{table}[!ht]",
            r"    \centering",
            r"    \setlength{\tabcolsep}{4pt}",
            r"    \caption[Latency measurement results]{Results of latency measurement for different operations,",
            r"    request sizes and access pattern (\si{\micro\second})}",
            r"    \label{tab:latency-results}",
            r"    \begin{tabular}{lllSSSSSS@{}}",
            r"        \toprule",
            r"        \textbf{Op.} & \textbf{Access} & \textbf{Size} & {\textbf{Min}} & {\boldmath $P_{1}$} &",
            r"        {\boldmath $P_{50}$} & {\boldmath $P_{80}$} & {\boldmath $P_{99}$} & {\textbf{Max}} \\",
            r"        & & {[LBAs]} & & & & & & \\",
            r"        \midrule",
        ]

        prev_op = None
        prev_access = None
        total_rows = len(sorted_rows)

        for idx, row in enumerate(sorted_rows):
            if prev_op is not None and row["op"] != prev_op:
                lines.append(r"        \midrule")
                prev_access = None
            elif prev_access is not None and row["access"] != prev_access:
                lines.append(r"        \addlinespace")

            op_col = row["op"] if row["op"] != prev_op else ""
            access_col = row["access"] if row["access"] != prev_access else ""

            latex_line = "        {:<2} & {:<10} & {:>3} & {:>6.2f} & {:>6.2f} & {:>6.2f} & {:>6.2f} & {:>6.2f} & {:>6.2f}".format(
                op_col,
                access_col,
                row["size"],
                row["min"],
                row["p1"],
                row["p50"],
                row["p80"],
                row["p99"],
                row["max"],
            )
            lines.append(latex_line + r" \\")

            prev_op = row["op"]
            prev_access = row["access"]

            if idx == total_rows - 1:
                lines.append(r"        \bottomrule")

        lines.extend([
            r"    \end{tabular}",
            r"\end{table}",
        ])

        with open(output_file, "w") as tex_file:
            tex_file.write("\n".join(lines) + "\n")

        print(f"LaTeX table written to {output_file}")

    def draw_cumdib(self, tst_row, output_name="graph"):
        # Plot cumulative distribution for each value_*
        fig, axes = plt.subplots(figsize=(7, 4), layout='tight')

        concat_title = ""
        x_max_lim = 0
        x_min_lim = 2**20

        # Calculate bin edges based on HIST_BOX_CNT, HIST_BOX_WIDTH, and HIST_STEP
        bins = [j * self.hist_step for j in range(1, self.hist_box_cnt+1)]
        # print(f"{bins=}")
        # convert bin edges to time values
        bins_time = np.array([edge * self.clk_period for edge in bins])
        # print(f"{bins_time=}")
        # Adjust time value according to the largest value in measured results
        bins_time_form, time_unit = format_time_value(bins_time)
        # print(f"{bins_time_form=}")

        latex_rows = []

        for tst_name, tst_path in tst_row:
            with open(tst_path, 'r') as json_file:
                stats_data = json.load(json_file)
                concat_title += "x" + tst_name

                for key, value in stats_data.items():
                    if key.startswith("value_"):
                        if np.all(value["hist"] == 0):
                            print("Skipping measurement, histogram is empty...")
                            continue

                        # Check if the lower bins do not contain any value
                        for bin_idx in range(10):
                            if (value["hist"][bin_idx] != 0):
                                print(f"WARNING: The bin {bin_idx} contains some values, there has probably been some overflow!")

                        cumulative_hist = np.cumsum(value["hist"])
                        cdf = cumulative_hist / cumulative_hist[-1]

                        quant_01_value = np.interp(0.10, cdf, bins_time_form)
                        median_value = np.interp(0.50, cdf, bins_time_form)
                        quant_80_value = np.interp(0.80, cdf, bins_time_form)
                        quant_99_value = np.interp(0.9900, cdf, bins_time_form)

                        min_value, _ = format_time_value(value["min"]*self.clk_period)
                        x_min_lim = min(x_min_lim, min_value)

                        nonzero_mask = np.array(value["hist"]) > 10
                        nonzero_indices = np.where(nonzero_mask)[0]
                        cutoff_count = int(np.floor(0.9900 * len(nonzero_indices))) if len(nonzero_indices) > 1 else 1
                        cutoff_bin_idx = nonzero_indices[:cutoff_count][-1]
                        x_max_lim = max(x_max_lim, bins_time_form[cutoff_bin_idx])

                        max_value, _ = format_time_value(value["max"]*self.clk_period)

                        op, access, size = self._parse_tst_name(tst_name)
                        axes.plot(
                            bins_time_form,
                            cdf,
                            label=f"{access} {op}@{size} LBAs",
                        )

                        print('{:<15}, Min: {:>8.2f}, P1-lat: {:>8.2f}, P50-lat: {:>8.2f}, P80-lat: {:>8.2f}, P99-lat: {:>8.2f}, Max: {:>8.2f}'.format(
                            tst_name,
                            min_value,
                            quant_01_value,
                            median_value,
                            quant_80_value,
                            quant_99_value,
                            max_value
                        ))

                        if op is not None:
                            latex_rows.append({
                                "op": op,
                                "access": access,
                                "size": size,
                                "min": min_value,
                                "p1": quant_01_value,
                                "p50": median_value,
                                "p80": quant_80_value,
                                "p99": quant_99_value,
                                "max": max_value,
                            })

        axes.set_xlabel(f'Latency [{time_unit}]')
        axes.set_ylabel('Probability [-]')
        # fig.legend(loc='center right', bbox_to_anchor=(0.98, 0.14))
        fig.legend(loc='lower center', bbox_to_anchor=(0.5, 1.02), borderaxespad=0, ncol=3)
        axes.minorticks_on()
        axes.yaxis.grid(True, which='major', linestyle='-')
        axes.xaxis.grid(True, which='major', linestyle='-')
        axes.yaxis.grid(True, which='minor', linestyle='-', alpha=0.4)
        axes.xaxis.grid(True, which='minor', linestyle='-', alpha=0.4)
        plt.xlim([0.95*x_min_lim, x_max_lim])
        plt.savefig(f'{output_name}.png', dpi = 600, bbox_inches='tight')
        plt.savefig(f'{output_name}.pdf', dpi = 600, bbox_inches='tight')
        plt.savefig(f'{output_name}.svg', dpi = 600, bbox_inches='tight')
        plt.close()

        self.write_latex_table(latex_rows)

    def draw_hist(self,tst_row):
        fig, axes = plt.subplots(figsize=(10, 8))

        concat_title = ""

        for tst_name, incl_chan_0 in tst_row:
            json_file_path = '{}.json'.format(tst_name)
            # Load data from the JSON file
            with open(json_file_path, 'r') as json_file:
                stats_data = json.load(json_file)

                concat_title += "x" + tst_name

                for key, value in stats_data.items():
                    if key.startswith("value_"):
                        if (np.all(value["hist"] == 0)):
                            continue

                        # Calculate bin edges based on HIST_BOX_CNT, HIST_BOX_WIDTH, and HIST_STEP
                        bins = [j * self.hist_step for j in range(self.hist_box_cnt)]
                        # convert bin edges to time values
                        bins_time = np.array([int(edge * self.clk_period) for edge in bins])
                        # Adjust time value according to the largest value in measured results
                        bins_time_form, time_unit = format_time_value(bins_time)

                        out = []
                        for val, cnt in zip(bins_time, value["hist"]):
                            out += [val] * cnt

                        plt.hist(out, bins=bins_time, alpha=0.3, label=tst_name)

                        if incl_chan_0:
                            break

        axes.set_xlabel(f'Latency [ns]')
        axes.set_ylabel('Samples count [-]')
        axes.legend(loc = 'outside upper center', bbox_to_anchor=(0.5, 1.5), mode='expand')
        plt.xlim([0, 8000])
        plt.savefig('{}.png'.format(concat_title[1:]), dpi = 300)
        plt.close()
