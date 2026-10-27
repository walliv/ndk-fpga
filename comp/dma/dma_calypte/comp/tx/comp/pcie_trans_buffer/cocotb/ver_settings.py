# ver_settings.py: generic combinations of the TX_DMA_PCIE_TRANS_BUFFER cocotb bench
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

SETTINGS = {
    # The defaults of the wrapper: AUTO selects the banked URAM buffer.
    "default": {
        "DEVICE": "\\\"ULTRASCALE\\\"",
        "CHANNELS": "8",
        "MFB_REGIONS": "2",
        "POINTER_WIDTH": "16",
        "READ_BARREL_SHIFTER_MASK": "3",
        "RAM_TYPE": "\\\"AUTO\\\"",
        "MEM_PARTITIONING": "true",
        "READ_LATENCY": "1",
    },

    # The per-byte buffer with two memory arrays, or the banked BRAM one with a flat space or a read latency of 3.
    "bram": {"RAM_TYPE": "\\\"BRAM\\\""},
    "ch32": {"CHANNELS": "32", "POINTER_WIDTH": "13"},
    # As in TX_DMA_CALYPTE: per-byte, or banked URAM with 32 channels.
    "txdma": {"READ_BARREL_SHIFTER_MASK": "1", "CHANNELS": "16", "POINTER_WIDTH": "13"},
    "lat3": {"READ_LATENCY": "3"},
    "intel": {"DEVICE": "\\\"AGILEX\\\""},
    "flat": {"MEM_PARTITIONING": "false", "CHANNELS": "2", "POINTER_WIDTH": "18"},
    # cocotb_1region_smoke.py checks a 1-region instance, which cocotb_test.py does not drive.
    "smoke_1region": {"MFB_REGIONS": "1", "RAM_TYPE": "\\\"URAM\\\"",
                      "__cocotb_params__": {"TEST_MODULES": "cocotb_1region_smoke"}},

    "_combinations_": {
        "default": (),
        "bram": ("bram",),
        "ch32": ("ch32",),
        "txdma": ("txdma",),
        "txdma_ch32": ("txdma", "ch32"),
        "lat3_bram": ("lat3", "bram"),
        "intel_default": ("intel",),
        "flat_bram": ("flat", "bram"),
        "smoke_uram_b8": ("txdma", "smoke_1region"),
    },
}
