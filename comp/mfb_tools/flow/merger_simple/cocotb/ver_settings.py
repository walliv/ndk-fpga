# ver_settings.py: generic combinations of the MFB_MERGER_SIMPLE cocotb bench
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

SETTINGS = {
    "default": {
        "REGIONS": "1",
        "REGION_SIZE": "4",
        "BLOCK_SIZE": "8",
        "ITEM_WIDTH": "8",
        "META_WIDTH": "8",
        "MASKING_EN": "true",
        "CNT_MAX": "64",
    },

    "nomask": {"MASKING_EN": "false"},
    "cnt2": {"CNT_MAX": "2"},
    "cnt4": {"CNT_MAX": "4"},
    "cnt256": {"CNT_MAX": "256"},
    # REGION_SIZE > 1 puts an EOF and the next SOF into one region.
    "rs1": {"REGION_SIZE": "1"},
    "r2_rs8": {"REGIONS": "2", "REGION_SIZE": "8"},
    "r4_rs8": {"REGIONS": "4", "REGION_SIZE": "8"},
    # The PCIe geometry DMA_CALYPTE merges its RQ streams in.
    "pcie": {"REGION_SIZE": "1", "ITEM_WIDTH": "32", "META_WIDTH": "16", "MASKING_EN": "false", "CNT_MAX": "8"},
    "2reg": {"REGIONS": "2"},

    "_combinations_": {
        "default": (),
        "r1_nomask_cnt2": ("nomask", "cnt2"),
        "r1_rs1_cnt256": ("rs1", "cnt256"),
        "r2_rs8": ("r2_rs8",),
        "r2_rs8_nomask_cnt2": ("r2_rs8", "nomask", "cnt2"),
        "pcie_1reg": ("pcie",),
        "pcie_2reg": ("pcie", "2reg"),
        "r4_rs8_cnt4": ("r4_rs8", "cnt4"),
        "r4_rs8_nomask_cnt256": ("r4_rs8", "nomask", "cnt256"),
    },
}
