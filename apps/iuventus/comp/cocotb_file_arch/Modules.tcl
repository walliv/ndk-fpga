# Modules.tcl: USER_CORE (FILE architecture) sources for its standalone cocotb testbench
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

# Mirrors the USR_CORE_ARCH=="FILE" branch of ../Modules.tcl.
set APP_COMP_BASE [file normalize "$ENTITY_BASE/.."]

lappend PACKAGES "$OFM_PATH/comp/base/pkg/math_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/type_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/nvme_meta_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/dma/dma_iuventus/pkg/iuventus_sizing_pkg.vhd"
# user_core_ent.vhd uses the generated per-card package but reads nothing from it.
lappend PACKAGES "$APP_COMP_BASE/cocotb_test_arch/combo_user_const_pkg.vhd"

lappend COMPONENTS [list "FILE_SHELL" "$APP_COMP_BASE/file_shell" "FULL"]

lappend MOD "$APP_COMP_BASE/user_core_ent.vhd"
lappend MOD "$APP_COMP_BASE/user_core_file_arch.vhd"
