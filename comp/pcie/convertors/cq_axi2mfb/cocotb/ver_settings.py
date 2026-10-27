# ver_settings.py: Verification settings of PCIE_CQ_AXI2MFB
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

SETTINGS = {
    # The default setting of verification. Only changed generics are listed.
    "default" : {
        "MFB_REGIONS"      : "2",
        "AXI_CQUSER_WIDTH" : "183",
        "STRADDLING"       : "true",
    },

    "no_straddling" : {
        "STRADDLING"       : "false",
    },

    "axi_256" : {
        "MFB_REGIONS"      : "1",
        "AXI_CQUSER_WIDTH" : "88",
        "STRADDLING"       : "false",
    },

    "axi_256_user_85" : {
        "MFB_REGIONS"      : "1",
        "AXI_CQUSER_WIDTH" : "85",
        "STRADDLING"       : "false",
    },

    "_combinations_" : (
        (),
        ("no_straddling",),
        ("axi_256",),
        ("axi_256_user_85",),
    ),
}
