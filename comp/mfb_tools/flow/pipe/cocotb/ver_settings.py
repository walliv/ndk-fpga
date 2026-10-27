# ver_settings.py: the generic combinations of the MFB_PIPE UVM bench for the cocotb bench
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

import runpy
from pathlib import Path

# The SystemVerilog of the UVM bench takes these as 0 and 1, which nvc rejects for the VHDL booleans of MFB_PIPE.
BOOLEAN_GENERICS = ("FAKE_PIPE", "USE_DST_RDY")

SETTINGS = runpy.run_path(str(Path(__file__).resolve().parent.parent / "uvm" / "ver_settings.py"))["SETTINGS"]
for setting in SETTINGS.values():
    if isinstance(setting, dict):
        for name in BOOLEAN_GENERICS:
            if name in setting:
                setting[name] = {"0": "false", "1": "true"}[setting[name]]
