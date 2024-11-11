-- This file was generated automatically. For changing its content,
-- edit corresponding variables in netcope_const.tcl

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.std_logic_arith.all;

package combo_user_const is
   constant ID_PROJECT_TEXT : std_logic_vector( 255 downto 0) := X"4e444b5f43414c595054455f44454d4f00000000000000000000000000000000";
   constant CARD_NAME : string := "ALVEO_U55C";
   constant PCIE_MOD_ARCH : string := "USP_PCIE4C";
   constant RX_GEN_EN : boolean := true;
   constant TX_GEN_EN : boolean := true;
   constant PCIE_LANES : integer := 8;
   constant PCIE_GEN : integer := 3;
   constant PCIE_ENDPOINTS : integer := 1;
   constant PCIE_ENDPOINT_MODE : integer := 2;
   constant DMA_RX_CHANNELS : integer := 16;
   constant DMA_TX_CHANNELS : integer := 2;
   constant DMA_RX_PKT_SIZE_MAX : integer := 4096;
   constant DMA_TX_PKT_SIZE_MAX : integer := 4096;
   constant DMA_RX_BLOCKING_MODE : boolean := true;
   constant DMA_RX_DATA_PTR_W : integer := 16;
   constant DMA_RX_HDR_PTR_W : integer := 16;
   constant DMA_TX_DATA_PTR_W : integer := 13;
   constant HBM_CHANNELS : integer := 32;
   constant DMA_GEN_LOOP_EN : boolean := false;
   constant VIRTUAL_DEBUG_ENABLE : boolean := false;
   constant DMA_DEBUG_ENABLE : boolean := false;
   constant PCIE_CORE_DEBUG_ENABLE : boolean := false;
   constant PCIE_CTRL_DEBUG_ENABLE : boolean := false;

end combo_user_const;

package body combo_user_const is
end combo_user_const;
