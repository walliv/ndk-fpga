# ver_settings.py: CHANNELS and FRAME_SIZE_MAX configurations of the C2H_HBM_READER cocotb bench
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

SETTINGS = {
    # The RTL default of the entity.
    "default" : {
        "CHANNELS"       : "64",
        "FRAME_SIZE_MAX" : "4096",
    },
    # What DMA_HYPERION of SparkleV instantiates.
    "sparklev" : {
        "CHANNELS"       : "8",
        "FRAME_SIZE_MAX" : "256",
    },
    # Every beat is a frame of its own.
    "frame_one_beat" : {
        "CHANNELS"       : "8",
        "FRAME_SIZE_MAX" : "32",
    },
}
