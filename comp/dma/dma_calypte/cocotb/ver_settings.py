# ver_settings.py: generic combinations of the DMA_CALYPTE cocotb bench
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

BASE = "run_dma_calypte_test"
SPEED = "run_dma_calypte_speed_test"

def tests(*names):
    """The cocotb tests a combination runs, as COCOTB_TEST_FILTER, which cocotb searches in "<module>.<test>"."""
    return {"TEST_FILTER": r"\.(" + "|".join(names) + r")\b"}


# Every enabled combination of the RX and TX UVM ver_settings.py.
SETTINGS = {
    "default": {
        "DEVICE": "\\\"ULTRASCALE\\\"",
        "MI_WIDTH": "32",
        "HDR_META_WIDTH": "24",
        "RX_PTR_WIDTH": "16",
        "TX_PTR_WIDTH": "13",
        "USR_RX_PKT_SIZE_MAX": "4096",
        "USR_TX_PKT_SIZE_MAX": "4096",
        "DSP_CNT_WIDTH": "64",
        "PERF_CNTR_EN": "false",
        "USR_MFB_REGIONS": "1",
        "USR_MFB_REGION_SIZE": "4",
        "USR_MFB_BLOCK_SIZE": "8",
        "USR_MFB_ITEM_WIDTH": "8",
        "PCIE_RQ_MFB_REGIONS": "1",
        "PCIE_RQ_MFB_REGION_SIZE": "1",
        "PCIE_RQ_MFB_BLOCK_SIZE": "8",
        "PCIE_RQ_MFB_ITEM_WIDTH": "32",
        "PCIE_CQ_MFB_REGIONS": "1",
        "PCIE_CQ_MFB_REGION_SIZE": "1",
        "PCIE_CQ_MFB_BLOCK_SIZE": "8",
        "PCIE_CQ_MFB_ITEM_WIDTH": "32",
        "RX_CHANNELS": "2",
        "TX_CHANNELS": "2",
        "TRBUF_REG_EN": "false",
        "__cocotb_params__": tests(BASE, SPEED),
    },

    "intel": {"DEVICE": "\\\"AGILEX\\\""},
    "2reg": {"USR_MFB_REGION_SIZE": "8", "PCIE_RQ_MFB_REGIONS": "2", "PCIE_CQ_MFB_REGIONS": "2"},
    "ch32_trbuf": {"RX_CHANNELS": "32", "TX_CHANNELS": "8", "TRBUF_REG_EN": "true"},
    "ch16_trbuf": {"RX_CHANNELS": "16", "TX_CHANNELS": "16", "TRBUF_REG_EN": "true"},

    "tests_base": {"__cocotb_params__": tests(BASE)},

    "_combinations_": {
        "default": (),
        "ch32_trbuf": ("ch32_trbuf", "tests_base"),
        "2reg": ("2reg", "tests_base"),
        "ch16_2reg_trbuf": ("2reg", "ch16_trbuf", "tests_base"),
        "intel_2reg": ("intel", "2reg"),
        "intel_ch16_trbuf": ("intel", "ch16_trbuf", "tests_base"),
        "intel_ch16_2reg_trbuf": ("intel", "2reg", "ch16_trbuf", "tests_base"),
    },

    # A Jenkins run, multi_ver_cocotb.py without -r, takes 7 * 30 // 100 = 2 combinations at random to stay within the 4 h
    # component timeout; local runs pass -r 100, and the nvc suite runs every combination.
    "_combinations_run_percentage_": 30,
}
