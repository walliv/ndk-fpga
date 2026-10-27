# SPDX-License-Identifier: BSD-3-Clause
# Copyright (C) 2025 CESNET z. s. p. o.
# Author(s): Jakub Cabal <cabal@cesnet.cz>
#            Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#            Ondřej Schwarz <ondrejschwarz@cesnet.cz>

from random import randint


def get_mfb_params(signal_bus, params_dic):
    # calculating settings from the bus, which may lack SOF_POS or EOF_POS
    regions = len(signal_bus.sof)
    dw = len(signal_bus.data)
    sof_pos = getattr(signal_bus, "sof_pos", None)
    eof_pos = getattr(signal_bus, "eof_pos", None)

    if (sof_pos is None) or (len(sof_pos) == regions):
        sps = 0
    else:
        sps = len(sof_pos) // regions

    if eof_pos is None:
        eps = 0
    else:
        eps = len(eof_pos) // regions

    region_size = 2**sps
    block_size  = 2**max(0, eps - sps)
    item_width  = dw // (regions * region_size * block_size)
    meta_width  = len(signal_bus.meta) // regions if hasattr(signal_bus, "meta") else 0
    os_vld_with = "sof"

    # overriding calculated settings with manual settings (if present)
    if params_dic is not None:
        regions     = params_dic.get("regions", regions)
        region_size = params_dic.get("region_size", region_size)
        block_size  = params_dic.get("block_size", block_size)
        item_width  = params_dic.get("item_width", item_width)
        meta_width  = params_dic.get("meta_width", meta_width)
        os_vld_with = params_dic.get("os_vld_with", os_vld_with)

    # checking for errors
    dw = regions * region_size * block_size * item_width

    if regions != len(signal_bus.sof):
        signal_bus.sof.log.error("MFB parameters do not correspond to signals length!")
        raise Exception()

    if dw != len(signal_bus.data):
        signal_bus.data.log.error("MFB parameters do not correspond to signals length!")
        raise Exception()

    if os_vld_with not in ["sof", "eof"]:
        raise ValueError(f"Invalid value of {os_vld_with} of 'os_vld_with'. Supported values are: \"sof\", \"eof\".")

    return regions, region_size, block_size, item_width, meta_width, os_vld_with


def region_frame_event(sof, eof, sof_item, eof_item):
    """What the SOF and EOF of one region do to the frame: "start", "end", "whole" (a frame starts and ends in the
    region), "end_start" (the open frame ends, the next one starts) or None. Items count within the region."""
    if sof and eof:
        return "whole" if eof_item >= sof_item else "end_start"
    if sof:
        return "start"
    return "end" if eof else None


def random_tuple_iterator(min1, max1, min2, max2):
    while True:
        yield (randint(min1, max1), randint(min2, max2))
