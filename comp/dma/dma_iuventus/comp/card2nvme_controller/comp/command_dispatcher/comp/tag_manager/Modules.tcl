# Modules.tcl: Components include script
# Copyright (C) 2025 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

set FIFOX_BASE_PATH "$OFM_PATH/comp/base/fifo/fifox"

lappend COMPONENTS [list "FIFOX" $FIFOX_BASE_PATH "FULL"]

lappend MOD "$ENTITY_BASE/iuventus_cmd_tag_manager.vhd"
