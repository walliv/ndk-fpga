set OFM_PATH "$ENTITY_BASE/../../../../"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/math_pack.vhd"
lappend PACKAGES "$OFM_PATH/comp/base/pkg/type_pack.vhd"
lappend COMPONENTS [list "SDP_BRAM" "$OFM_PATH/comp/base/mem/sdp_bram" "FULL"]
lappend MOD "$ENTITY_BASE/../iuventus_groupby_lane.vhd"
lappend MOD "$ENTITY_BASE/../iuventus_groupby_engine.vhd"
