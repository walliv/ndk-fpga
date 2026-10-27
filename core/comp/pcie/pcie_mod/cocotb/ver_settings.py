# ver_settings.py: Verification settings of PCIE_COMPLETER_TB
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

    "_combinations_" : (
        (),
    ),
}
