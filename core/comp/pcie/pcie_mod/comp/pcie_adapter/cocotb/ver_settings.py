# ver_settings.py: Verification settings of PCIE_ADAPTER
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

SETTINGS = {
    # The default setting of verification. Only changed generics are listed.
    "default" : {
        "MFB_REGIONS"      : "2",
        "AXI_CQUSER_WIDTH" : "183",
        "AXI_CCUSER_WIDTH" : "81",
        "AXI_RQUSER_WIDTH" : "137",
        "AXI_RCUSER_WIDTH" : "161",
        "AXI_STRADDLING"   : "true",
    },

    "no_straddling" : {
        "AXI_STRADDLING"   : "false",
    },

    "axi_256" : {
        "MFB_REGIONS"      : "1",
        "AXI_CQUSER_WIDTH" : "88",
        "AXI_CCUSER_WIDTH" : "33",
        "AXI_RQUSER_WIDTH" : "62",
        "AXI_RCUSER_WIDTH" : "75",
        "AXI_STRADDLING"   : "false",
    },

    "_combinations_" : (
        (),
        ("no_straddling",),
        ("axi_256",),
    ),
}
