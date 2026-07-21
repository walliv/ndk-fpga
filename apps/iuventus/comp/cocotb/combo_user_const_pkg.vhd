-- combo_user_const_pkg.vhd: minimal stand-in for the per-card `combo_user_const` package
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-W-2.0

-- In a real card build, `combo_user_const` is generated per-card by the NDK core build
-- (core/common.inc.tcl's nb_generate_file_register_userpkg), carrying constants such as
-- CARD_NAME. USER_CORE only has a bare `use work.combo_user_const.all;` clause (user_core_ent.vhd)
-- and never actually references anything from it, so this component-level cocotb testbench (which
-- elaborates USER_CORE standalone, with no card/core context at all) supplies this empty stub
-- purely to satisfy that `use` clause.

package combo_user_const is
end package;
