# ver_settings.py: CHANNELS configurations of the C2H_HBM_READER cocotb bench
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

SETTINGS = {
    # The RTL default of the entity.
    "default" : {
        "CHANNELS" : "64",
    },
    # What DMA_HYPERION of SparkleV instantiates.
    "channels_8" : {
        "CHANNELS" : "8",
    },
}
