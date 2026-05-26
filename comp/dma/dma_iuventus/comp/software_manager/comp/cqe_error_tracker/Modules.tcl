# Modules.tcl: Components include script
# Copyright (C) 2026 CESNET
# Author(s): Vladislav Valek <xvalek14@vutbr.cz>

lappend PACKAGES "$OFM_PATH/comp/base/pkg/nvme_meta_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/dma/dma_iuventus/pkg/iuventus_bar_map_pkg.vhd"

lappend MOD "$ENTITY_BASE/cqe_error_tracker.vhd"
