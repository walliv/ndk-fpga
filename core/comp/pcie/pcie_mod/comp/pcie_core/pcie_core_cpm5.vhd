-- pcie_core_cpm5.vhd: PCIe module core for the Versal CPM5 hard block (two Gen5 x8 endpoints)
-- Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
-- Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
--
-- SPDX-License-Identifier: CERN-OHL-W-2.0

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

use work.combo_user_const.all;

use work.math_pack.all;
use work.type_pack.all;

-- Wraps the CIPS block design cpm5_cips (created by the card's BD script, both CPM5 controllers as 1024-bit straddled endpoints) and one PCIE_ADAPTER per endpoint. MISC_PCIE2TOP(0) carries the CIPS PL0 clock (bit 0) and its active-low reset (bit 1).
architecture CPM5 of PCIE_CORE is

    -- PG346 Table 50: the user extended configuration space of the Extended_Large option starts at 0x600
    constant VSEC_BASE_ADDRESS : natural := 16#600#;
    constant EXT_CFG_FIRST_REG : natural := VSEC_BASE_ADDRESS/4;
    constant EXT_CFG_LAST_REG  : natural := 16#FFC#/4;
    constant VSEC_REGS         : natural := 8;

    constant IP_LANES         : natural := PCIE_LANES/2;
    constant AXI_DATA_WIDTH   : natural := 1024;
    constant AXI_CQUSER_WIDTH : natural := 465;
    constant AXI_CCUSER_WIDTH : natural := 165;
    constant AXI_RQUSER_WIDTH : natural := 373;
    constant AXI_RCUSER_WIDTH : natural := 337;

    component cpm5_cips_wrapper is
        port (
            EP0_CFG_CONTROL_ERR_COR_IN                   : in  std_logic;
            EP0_CFG_CONTROL_ERR_UNCOR_IN                 : in  std_logic;
            EP0_CFG_CONTROL_FLR_DONE                     : in  std_logic;
            EP0_CFG_CONTROL_FLR_DONE_FUNCTION_NUMBER     : in  std_logic_vector(15 downto 0);
            EP0_CFG_CONTROL_FLR_IN_PROCESS               : out std_logic_vector(3 downto 0);
            EP0_CFG_CONTROL_HOT_RESET_IN                 : in  std_logic;
            EP0_CFG_CONTROL_HOT_RESET_OUT                : out std_logic;
            EP0_CFG_CONTROL_PER_FUNCTION_NUMBER          : in  std_logic_vector(15 downto 0);
            EP0_CFG_CONTROL_PER_FUNCTION_REQ             : in  std_logic;
            EP0_CFG_CONTROL_POWER_STATE_CHANGE_ACK       : in  std_logic;
            EP0_CFG_CONTROL_POWER_STATE_CHANGE_INTERRUPT : out std_logic;
            EP0_CFG_EXT_FUNCTION_NUMBER                  : out std_logic_vector(15 downto 0);
            EP0_CFG_EXT_READ_DATA                        : in  std_logic_vector(31 downto 0);
            EP0_CFG_EXT_READ_DATA_VALID                  : in  std_logic;
            EP0_CFG_EXT_READ_RECEIVED                    : out std_logic;
            EP0_CFG_EXT_REGISTER_NUMBER                  : out std_logic_vector(9 downto 0);
            EP0_CFG_EXT_WRITE_BYTE_ENABLE                : out std_logic_vector(3 downto 0);
            EP0_CFG_EXT_WRITE_DATA                       : out std_logic_vector(31 downto 0);
            EP0_CFG_EXT_WRITE_RECEIVED                   : out std_logic;
            EP0_CFG_FC_CPLD                              : out std_logic_vector(11 downto 0);
            EP0_CFG_FC_CPLD_SCALE                        : out std_logic_vector(1 downto 0);
            EP0_CFG_FC_CPLH                              : out std_logic_vector(7 downto 0);
            EP0_CFG_FC_CPLH_SCALE                        : out std_logic_vector(1 downto 0);
            EP0_CFG_FC_NPD                               : out std_logic_vector(11 downto 0);
            EP0_CFG_FC_NPD_SCALE                         : out std_logic_vector(1 downto 0);
            EP0_CFG_FC_NPH                               : out std_logic_vector(7 downto 0);
            EP0_CFG_FC_NPH_SCALE                         : out std_logic_vector(1 downto 0);
            EP0_CFG_FC_PD                                : out std_logic_vector(11 downto 0);
            EP0_CFG_FC_PD_SCALE                          : out std_logic_vector(1 downto 0);
            EP0_CFG_FC_PH                                : out std_logic_vector(7 downto 0);
            EP0_CFG_FC_PH_SCALE                          : out std_logic_vector(1 downto 0);
            EP0_CFG_FC_SEL                               : in  std_logic_vector(2 downto 0);
            EP0_CFG_FC_VC_SEL                            : in  std_logic;
            EP0_CFG_INTERRUPT_INTX_VECTOR                : in  std_logic_vector(3 downto 0);
            EP0_CFG_INTERRUPT_PENDING                    : in  std_logic_vector(15 downto 0);
            EP0_CFG_INTERRUPT_SENT                       : out std_logic;
            EP0_CFG_STATUS_10B_TAG_REQUESTER_ENABLE      : out std_logic;
            EP0_CFG_STATUS_ATOMIC_REQUESTER_ENABLE       : out std_logic;
            EP0_CFG_STATUS_BUS_NUMBER                    : out std_logic_vector(7 downto 0);
            EP0_CFG_STATUS_CQ_NP_REQ                     : in  std_logic_vector(1 downto 0);
            EP0_CFG_STATUS_CQ_NP_REQ_COUNT               : out std_logic_vector(5 downto 0);
            EP0_CFG_STATUS_CURRENT_SPEED                 : out std_logic_vector(2 downto 0);
            EP0_CFG_STATUS_ERR_COR_OUT                   : out std_logic;
            EP0_CFG_STATUS_ERR_FATAL_OUT                 : out std_logic;
            EP0_CFG_STATUS_ERR_NONFATAL_OUT              : out std_logic;
            EP0_CFG_STATUS_EXT_TAG_ENABLE                : out std_logic;
            EP0_CFG_STATUS_FUNCTION_POWER_STATE          : out std_logic_vector(2 downto 0);
            EP0_CFG_STATUS_FUNCTION_STATUS               : out std_logic_vector(3 downto 0);
            EP0_CFG_STATUS_LINK_POWER_STATE              : out std_logic_vector(1 downto 0);
            EP0_CFG_STATUS_LOCAL_ERROR_OUT               : out std_logic_vector(4 downto 0);
            EP0_CFG_STATUS_LOCAL_ERROR_VALID             : out std_logic;
            EP0_CFG_STATUS_LTSSM_STATE                   : out std_logic_vector(5 downto 0);
            EP0_CFG_STATUS_MAX_PAYLOAD                   : out std_logic_vector(1 downto 0);
            EP0_CFG_STATUS_MAX_READ_REQ                  : out std_logic_vector(2 downto 0);
            EP0_CFG_STATUS_NEGOTIATED_WIDTH              : out std_logic_vector(2 downto 0);
            EP0_CFG_STATUS_PER_FUNCTION_OUT              : out std_logic_vector(23 downto 0);
            EP0_CFG_STATUS_PER_FUNCTION_VLD              : out std_logic;
            EP0_CFG_STATUS_PHY_LINK_DOWN                 : out std_logic;
            EP0_CFG_STATUS_PHY_LINK_STATUS               : out std_logic_vector(1 downto 0);
            EP0_CFG_STATUS_PL_STATUS_CHANGE              : out std_logic;
            EP0_CFG_STATUS_RCB_STATUS                    : out std_logic;
            EP0_CFG_STATUS_RQ_SEQ_NUM0                   : out std_logic_vector(5 downto 0);
            EP0_CFG_STATUS_RQ_SEQ_NUM1                   : out std_logic_vector(5 downto 0);
            EP0_CFG_STATUS_RQ_SEQ_NUM2                   : out std_logic_vector(5 downto 0);
            EP0_CFG_STATUS_RQ_SEQ_NUM3                   : out std_logic_vector(5 downto 0);
            EP0_CFG_STATUS_RQ_SEQ_NUM_VLD0               : out std_logic;
            EP0_CFG_STATUS_RQ_SEQ_NUM_VLD1               : out std_logic;
            EP0_CFG_STATUS_RQ_SEQ_NUM_VLD2               : out std_logic;
            EP0_CFG_STATUS_RQ_SEQ_NUM_VLD3               : out std_logic;
            EP0_CFG_STATUS_RQ_TAG0                       : out std_logic_vector(9 downto 0);
            EP0_CFG_STATUS_RQ_TAG1                       : out std_logic_vector(9 downto 0);
            EP0_CFG_STATUS_RQ_TAG2                       : out std_logic_vector(9 downto 0);
            EP0_CFG_STATUS_RQ_TAG3                       : out std_logic_vector(9 downto 0);
            EP0_CFG_STATUS_RQ_TAG_AV                     : out std_logic_vector(3 downto 0);
            EP0_CFG_STATUS_RQ_TAG_VLD0                   : out std_logic;
            EP0_CFG_STATUS_RQ_TAG_VLD1                   : out std_logic;
            EP0_CFG_STATUS_RQ_TAG_VLD2                   : out std_logic;
            EP0_CFG_STATUS_RQ_TAG_VLD3                   : out std_logic;
            EP0_CFG_STATUS_RX_PM_STATE                   : out std_logic_vector(1 downto 0);
            EP0_CFG_STATUS_TPH_REQUESTER_ENABLE          : out std_logic_vector(3 downto 0);
            EP0_CFG_STATUS_TPH_ST_MODE                   : out std_logic_vector(11 downto 0);
            EP0_CFG_STATUS_TX_PM_STATE                   : out std_logic_vector(1 downto 0);
            EP0_CFG_STATUS_WRREQ_BME_VLD                 : out std_logic;
            EP0_CFG_STATUS_WRREQ_FLR_VLD                 : out std_logic;
            EP0_CFG_STATUS_WRREQ_FUNCTION_NUMBER         : out std_logic_vector(15 downto 0);
            EP0_CFG_STATUS_WRREQ_MSI_VLD                 : out std_logic;
            EP0_CFG_STATUS_WRREQ_MSIX_VLD                : out std_logic;
            EP0_CFG_STATUS_WRREQ_OUT_VALUE               : out std_logic_vector(3 downto 0);
            EP0_CFG_STATUS_WRREQ_VFE_VLD                 : out std_logic;
            EP0_GT_GRX_N                                 : in  std_logic_vector(7 downto 0);
            EP0_GT_GRX_P                                 : in  std_logic_vector(7 downto 0);
            EP0_GT_GTX_N                                 : out std_logic_vector(7 downto 0);
            EP0_GT_GTX_P                                 : out std_logic_vector(7 downto 0);
            EP0_GT_REFCLK_CLK_N                          : in  std_logic;
            EP0_GT_REFCLK_CLK_P                          : in  std_logic;
            EP0_M_AXIS_CQ_TDATA                          : out std_logic_vector(1023 downto 0);
            EP0_M_AXIS_CQ_TKEEP                          : out std_logic_vector(31 downto 0);
            EP0_M_AXIS_CQ_TLAST                          : out std_logic;
            EP0_M_AXIS_CQ_TREADY                         : in  std_logic;
            EP0_M_AXIS_CQ_TUSER                          : out std_logic_vector(464 downto 0);
            EP0_M_AXIS_CQ_TVALID                         : out std_logic;
            EP0_M_AXIS_RC_TDATA                          : out std_logic_vector(1023 downto 0);
            EP0_M_AXIS_RC_TKEEP                          : out std_logic_vector(31 downto 0);
            EP0_M_AXIS_RC_TLAST                          : out std_logic;
            EP0_M_AXIS_RC_TREADY                         : in  std_logic;
            EP0_M_AXIS_RC_TUSER                          : out std_logic_vector(336 downto 0);
            EP0_M_AXIS_RC_TVALID                         : out std_logic;
            EP0_S_AXIS_CC_TDATA                          : in  std_logic_vector(1023 downto 0);
            EP0_S_AXIS_CC_TKEEP                          : in  std_logic_vector(31 downto 0);
            EP0_S_AXIS_CC_TLAST                          : in  std_logic;
            EP0_S_AXIS_CC_TREADY                         : out std_logic;
            EP0_S_AXIS_CC_TUSER                          : in  std_logic_vector(164 downto 0);
            EP0_S_AXIS_CC_TVALID                         : in  std_logic;
            EP0_S_AXIS_RQ_TDATA                          : in  std_logic_vector(1023 downto 0);
            EP0_S_AXIS_RQ_TKEEP                          : in  std_logic_vector(31 downto 0);
            EP0_S_AXIS_RQ_TLAST                          : in  std_logic;
            EP0_S_AXIS_RQ_TREADY                         : out std_logic;
            EP0_S_AXIS_RQ_TUSER                          : in  std_logic_vector(372 downto 0);
            EP0_S_AXIS_RQ_TVALID                         : in  std_logic;
            EP0_TRANSMIT_FC_NPD_AV                       : out std_logic_vector(3 downto 0);
            EP0_TRANSMIT_FC_NPH_AV                       : out std_logic_vector(3 downto 0);
            EP0_USER_CLK                                 : out std_logic;
            EP0_USER_LNK_UP                              : out std_logic;
            EP0_USER_RESET                               : out std_logic;
            EP1_CFG_CONTROL_ERR_COR_IN                   : in  std_logic;
            EP1_CFG_CONTROL_ERR_UNCOR_IN                 : in  std_logic;
            EP1_CFG_CONTROL_FLR_DONE                     : in  std_logic;
            EP1_CFG_CONTROL_FLR_DONE_FUNCTION_NUMBER     : in  std_logic_vector(15 downto 0);
            EP1_CFG_CONTROL_FLR_IN_PROCESS               : out std_logic_vector(3 downto 0);
            EP1_CFG_CONTROL_HOT_RESET_IN                 : in  std_logic;
            EP1_CFG_CONTROL_HOT_RESET_OUT                : out std_logic;
            EP1_CFG_CONTROL_PER_FUNCTION_NUMBER          : in  std_logic_vector(15 downto 0);
            EP1_CFG_CONTROL_PER_FUNCTION_REQ             : in  std_logic;
            EP1_CFG_CONTROL_POWER_STATE_CHANGE_ACK       : in  std_logic;
            EP1_CFG_CONTROL_POWER_STATE_CHANGE_INTERRUPT : out std_logic;
            EP1_CFG_EXT_FUNCTION_NUMBER                  : out std_logic_vector(15 downto 0);
            EP1_CFG_EXT_READ_DATA                        : in  std_logic_vector(31 downto 0);
            EP1_CFG_EXT_READ_DATA_VALID                  : in  std_logic;
            EP1_CFG_EXT_READ_RECEIVED                    : out std_logic;
            EP1_CFG_EXT_REGISTER_NUMBER                  : out std_logic_vector(9 downto 0);
            EP1_CFG_EXT_WRITE_BYTE_ENABLE                : out std_logic_vector(3 downto 0);
            EP1_CFG_EXT_WRITE_DATA                       : out std_logic_vector(31 downto 0);
            EP1_CFG_EXT_WRITE_RECEIVED                   : out std_logic;
            EP1_CFG_FC_CPLD                              : out std_logic_vector(11 downto 0);
            EP1_CFG_FC_CPLD_SCALE                        : out std_logic_vector(1 downto 0);
            EP1_CFG_FC_CPLH                              : out std_logic_vector(7 downto 0);
            EP1_CFG_FC_CPLH_SCALE                        : out std_logic_vector(1 downto 0);
            EP1_CFG_FC_NPD                               : out std_logic_vector(11 downto 0);
            EP1_CFG_FC_NPD_SCALE                         : out std_logic_vector(1 downto 0);
            EP1_CFG_FC_NPH                               : out std_logic_vector(7 downto 0);
            EP1_CFG_FC_NPH_SCALE                         : out std_logic_vector(1 downto 0);
            EP1_CFG_FC_PD                                : out std_logic_vector(11 downto 0);
            EP1_CFG_FC_PD_SCALE                          : out std_logic_vector(1 downto 0);
            EP1_CFG_FC_PH                                : out std_logic_vector(7 downto 0);
            EP1_CFG_FC_PH_SCALE                          : out std_logic_vector(1 downto 0);
            EP1_CFG_FC_SEL                               : in  std_logic_vector(2 downto 0);
            EP1_CFG_FC_VC_SEL                            : in  std_logic;
            EP1_CFG_INTERRUPT_INTX_VECTOR                : in  std_logic_vector(3 downto 0);
            EP1_CFG_INTERRUPT_PENDING                    : in  std_logic_vector(15 downto 0);
            EP1_CFG_INTERRUPT_SENT                       : out std_logic;
            EP1_CFG_STATUS_10B_TAG_REQUESTER_ENABLE      : out std_logic;
            EP1_CFG_STATUS_ATOMIC_REQUESTER_ENABLE       : out std_logic;
            EP1_CFG_STATUS_BUS_NUMBER                    : out std_logic_vector(7 downto 0);
            EP1_CFG_STATUS_CQ_NP_REQ                     : in  std_logic_vector(1 downto 0);
            EP1_CFG_STATUS_CQ_NP_REQ_COUNT               : out std_logic_vector(5 downto 0);
            EP1_CFG_STATUS_CURRENT_SPEED                 : out std_logic_vector(2 downto 0);
            EP1_CFG_STATUS_ERR_COR_OUT                   : out std_logic;
            EP1_CFG_STATUS_ERR_FATAL_OUT                 : out std_logic;
            EP1_CFG_STATUS_ERR_NONFATAL_OUT              : out std_logic;
            EP1_CFG_STATUS_EXT_TAG_ENABLE                : out std_logic;
            EP1_CFG_STATUS_FUNCTION_POWER_STATE          : out std_logic_vector(2 downto 0);
            EP1_CFG_STATUS_FUNCTION_STATUS               : out std_logic_vector(3 downto 0);
            EP1_CFG_STATUS_LINK_POWER_STATE              : out std_logic_vector(1 downto 0);
            EP1_CFG_STATUS_LOCAL_ERROR_OUT               : out std_logic_vector(4 downto 0);
            EP1_CFG_STATUS_LOCAL_ERROR_VALID             : out std_logic;
            EP1_CFG_STATUS_LTSSM_STATE                   : out std_logic_vector(5 downto 0);
            EP1_CFG_STATUS_MAX_PAYLOAD                   : out std_logic_vector(1 downto 0);
            EP1_CFG_STATUS_MAX_READ_REQ                  : out std_logic_vector(2 downto 0);
            EP1_CFG_STATUS_NEGOTIATED_WIDTH              : out std_logic_vector(2 downto 0);
            EP1_CFG_STATUS_PER_FUNCTION_OUT              : out std_logic_vector(23 downto 0);
            EP1_CFG_STATUS_PER_FUNCTION_VLD              : out std_logic;
            EP1_CFG_STATUS_PHY_LINK_DOWN                 : out std_logic;
            EP1_CFG_STATUS_PHY_LINK_STATUS               : out std_logic_vector(1 downto 0);
            EP1_CFG_STATUS_PL_STATUS_CHANGE              : out std_logic;
            EP1_CFG_STATUS_RCB_STATUS                    : out std_logic;
            EP1_CFG_STATUS_RQ_SEQ_NUM0                   : out std_logic_vector(5 downto 0);
            EP1_CFG_STATUS_RQ_SEQ_NUM1                   : out std_logic_vector(5 downto 0);
            EP1_CFG_STATUS_RQ_SEQ_NUM2                   : out std_logic_vector(5 downto 0);
            EP1_CFG_STATUS_RQ_SEQ_NUM3                   : out std_logic_vector(5 downto 0);
            EP1_CFG_STATUS_RQ_SEQ_NUM_VLD0               : out std_logic;
            EP1_CFG_STATUS_RQ_SEQ_NUM_VLD1               : out std_logic;
            EP1_CFG_STATUS_RQ_SEQ_NUM_VLD2               : out std_logic;
            EP1_CFG_STATUS_RQ_SEQ_NUM_VLD3               : out std_logic;
            EP1_CFG_STATUS_RQ_TAG0                       : out std_logic_vector(9 downto 0);
            EP1_CFG_STATUS_RQ_TAG1                       : out std_logic_vector(9 downto 0);
            EP1_CFG_STATUS_RQ_TAG2                       : out std_logic_vector(9 downto 0);
            EP1_CFG_STATUS_RQ_TAG3                       : out std_logic_vector(9 downto 0);
            EP1_CFG_STATUS_RQ_TAG_AV                     : out std_logic_vector(3 downto 0);
            EP1_CFG_STATUS_RQ_TAG_VLD0                   : out std_logic;
            EP1_CFG_STATUS_RQ_TAG_VLD1                   : out std_logic;
            EP1_CFG_STATUS_RQ_TAG_VLD2                   : out std_logic;
            EP1_CFG_STATUS_RQ_TAG_VLD3                   : out std_logic;
            EP1_CFG_STATUS_RX_PM_STATE                   : out std_logic_vector(1 downto 0);
            EP1_CFG_STATUS_TPH_REQUESTER_ENABLE          : out std_logic_vector(3 downto 0);
            EP1_CFG_STATUS_TPH_ST_MODE                   : out std_logic_vector(11 downto 0);
            EP1_CFG_STATUS_TX_PM_STATE                   : out std_logic_vector(1 downto 0);
            EP1_CFG_STATUS_WRREQ_BME_VLD                 : out std_logic;
            EP1_CFG_STATUS_WRREQ_FLR_VLD                 : out std_logic;
            EP1_CFG_STATUS_WRREQ_FUNCTION_NUMBER         : out std_logic_vector(15 downto 0);
            EP1_CFG_STATUS_WRREQ_MSI_VLD                 : out std_logic;
            EP1_CFG_STATUS_WRREQ_MSIX_VLD                : out std_logic;
            EP1_CFG_STATUS_WRREQ_OUT_VALUE               : out std_logic_vector(3 downto 0);
            EP1_CFG_STATUS_WRREQ_VFE_VLD                 : out std_logic;
            EP1_GT_GRX_N                                 : in  std_logic_vector(7 downto 0);
            EP1_GT_GRX_P                                 : in  std_logic_vector(7 downto 0);
            EP1_GT_GTX_N                                 : out std_logic_vector(7 downto 0);
            EP1_GT_GTX_P                                 : out std_logic_vector(7 downto 0);
            EP1_GT_REFCLK_CLK_N                          : in  std_logic;
            EP1_GT_REFCLK_CLK_P                          : in  std_logic;
            EP1_M_AXIS_CQ_TDATA                          : out std_logic_vector(1023 downto 0);
            EP1_M_AXIS_CQ_TKEEP                          : out std_logic_vector(31 downto 0);
            EP1_M_AXIS_CQ_TLAST                          : out std_logic;
            EP1_M_AXIS_CQ_TREADY                         : in  std_logic;
            EP1_M_AXIS_CQ_TUSER                          : out std_logic_vector(464 downto 0);
            EP1_M_AXIS_CQ_TVALID                         : out std_logic;
            EP1_M_AXIS_RC_TDATA                          : out std_logic_vector(1023 downto 0);
            EP1_M_AXIS_RC_TKEEP                          : out std_logic_vector(31 downto 0);
            EP1_M_AXIS_RC_TLAST                          : out std_logic;
            EP1_M_AXIS_RC_TREADY                         : in  std_logic;
            EP1_M_AXIS_RC_TUSER                          : out std_logic_vector(336 downto 0);
            EP1_M_AXIS_RC_TVALID                         : out std_logic;
            EP1_S_AXIS_CC_TDATA                          : in  std_logic_vector(1023 downto 0);
            EP1_S_AXIS_CC_TKEEP                          : in  std_logic_vector(31 downto 0);
            EP1_S_AXIS_CC_TLAST                          : in  std_logic;
            EP1_S_AXIS_CC_TREADY                         : out std_logic;
            EP1_S_AXIS_CC_TUSER                          : in  std_logic_vector(164 downto 0);
            EP1_S_AXIS_CC_TVALID                         : in  std_logic;
            EP1_S_AXIS_RQ_TDATA                          : in  std_logic_vector(1023 downto 0);
            EP1_S_AXIS_RQ_TKEEP                          : in  std_logic_vector(31 downto 0);
            EP1_S_AXIS_RQ_TLAST                          : in  std_logic;
            EP1_S_AXIS_RQ_TREADY                         : out std_logic;
            EP1_S_AXIS_RQ_TUSER                          : in  std_logic_vector(372 downto 0);
            EP1_S_AXIS_RQ_TVALID                         : in  std_logic;
            EP1_TRANSMIT_FC_NPD_AV                       : out std_logic_vector(3 downto 0);
            EP1_TRANSMIT_FC_NPH_AV                       : out std_logic_vector(3 downto 0);
            EP1_USER_CLK                                 : out std_logic;
            EP1_USER_LNK_UP                              : out std_logic;
            EP1_USER_RESET                               : out std_logic;
            PL0_REF_CLK                                  : out std_logic;
            PL0_RESETN                                   : out std_logic
        );
    end component;

    signal pl0_ref_clk           : std_logic;
    signal pl0_resetn            : std_logic;

    signal pcie_hip_clk          : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal pcie_hip_rst          : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal user_lnk_up           : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal pcie_rst_async        : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal pcie_rst              : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(RESET_WIDTH+1-1 downto 0);

    signal cfg_max_payload       : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(1 downto 0);
    signal cfg_max_read_req      : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(2 downto 0);
    signal cfg_phy_link_status   : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(1 downto 0);
    signal cfg_rcb_status        : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);

    signal cfg_ext_read          : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal cfg_ext_write         : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal cfg_ext_register      : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(9 downto 0);
    signal cfg_ext_function      : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(15 downto 0);
    signal cfg_ext_write_data    : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(31 downto 0);
    signal cfg_ext_write_be      : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(3 downto 0);
    signal cfg_ext_read_dtb_data : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(31 downto 0);
    signal cfg_ext_read_dtb_dv   : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal cfg_ext_read_zero_dv  : std_logic_vector(PCIE_ENDPOINTS-1 downto 0) := (others => '0');
    signal cfg_ext_read_data     : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(31 downto 0);
    signal cfg_ext_read_dv       : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);

    signal pcie_cq_axi_data      : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(AXI_DATA_WIDTH-1 downto 0);
    signal pcie_cq_axi_user      : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(AXI_CQUSER_WIDTH-1 downto 0);
    signal pcie_cq_axi_last      : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal pcie_cq_axi_keep      : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(AXI_DATA_WIDTH/32-1 downto 0);
    signal pcie_cq_axi_valid     : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal pcie_cq_axi_ready     : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal pcie_cc_axi_data      : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(AXI_DATA_WIDTH-1 downto 0);
    signal pcie_cc_axi_user      : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(AXI_CCUSER_WIDTH-1 downto 0);
    signal pcie_cc_axi_last      : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal pcie_cc_axi_keep      : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(AXI_DATA_WIDTH/32-1 downto 0);
    signal pcie_cc_axi_valid     : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal pcie_cc_axi_ready     : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal pcie_rq_axi_data      : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(AXI_DATA_WIDTH-1 downto 0);
    signal pcie_rq_axi_user      : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(AXI_RQUSER_WIDTH-1 downto 0);
    signal pcie_rq_axi_last      : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal pcie_rq_axi_keep      : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(AXI_DATA_WIDTH/32-1 downto 0);
    signal pcie_rq_axi_valid     : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal pcie_rq_axi_ready     : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal pcie_rc_axi_data      : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(AXI_DATA_WIDTH-1 downto 0);
    signal pcie_rc_axi_user      : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(AXI_RCUSER_WIDTH-1 downto 0);
    signal pcie_rc_axi_last      : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal pcie_rc_axi_keep      : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(AXI_DATA_WIDTH/32-1 downto 0);
    signal pcie_rc_axi_valid     : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);
    signal pcie_rc_axi_ready     : std_logic_vector(PCIE_ENDPOINTS-1 downto 0);


    signal dbg_credits_ph        : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(7 downto 0);
    signal dbg_credits_pd        : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(11 downto 0);
    signal dbg_credits_nph       : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(7 downto 0);
    signal dbg_credits_npd       : slv_array_t(PCIE_ENDPOINTS-1 downto 0)(11 downto 0);

begin

    assert (ENDPOINT_MODE = 1 and PCIE_ENDPOINTS = 2 and PCIE_LANES = 16)
        report "Versal CPM5 PCIe Wrapper: only two x8 endpoints (ENDPOINT_MODE 1, PCIE_ENDPOINTS 2, PCIE_LANES 16) are supported!"
        severity failure;

    assert (DEVICE = "VERSAL")
        report "Versal CPM5 PCIe Wrapper: only the VERSAL device is supported!"
        severity failure;

    assert (CQ_MFB_REGIONS*CQ_MFB_REGION_SIZE*CQ_MFB_BLOCK_SIZE*CQ_MFB_ITEM_WIDTH = AXI_DATA_WIDTH and
            CC_MFB_REGIONS*CC_MFB_REGION_SIZE*CC_MFB_BLOCK_SIZE*CC_MFB_ITEM_WIDTH = AXI_DATA_WIDTH and
            RQ_MFB_REGIONS*RQ_MFB_REGION_SIZE*RQ_MFB_BLOCK_SIZE*RQ_MFB_ITEM_WIDTH = AXI_DATA_WIDTH and
            CQ_MFB_REGIONS = 4 and CC_MFB_REGIONS = 4 and RQ_MFB_REGIONS = 4)
        report "Versal CPM5 PCIe Wrapper: CQ, CC and RQ must be 1024-bit MFB with 4 regions!"
        severity failure;

    assert (MISC_PCIE2TOP_WIDTH >= 2)
        report "Versal CPM5 PCIe Wrapper: MISC_PCIE2TOP_WIDTH must be at least 2 (PL0 clock and reset)!"
        severity failure;

    -- =========================================================================
    --  CIPS BLOCK DESIGN (both CPM5 controllers)
    -- =========================================================================

    cips_i : component cpm5_cips_wrapper
    port map (
        ep0_cfg_control_err_cor_in                   => '0',
        ep0_cfg_control_err_uncor_in                 => '0',
        ep0_cfg_control_flr_done                     => '0',
        ep0_cfg_control_flr_done_function_number     => (others => '0'),
        ep0_cfg_control_flr_in_process               => open,
        ep0_cfg_control_hot_reset_in                 => '0',
        ep0_cfg_control_hot_reset_out                => open,
        ep0_cfg_control_per_function_number          => (others => '0'),
        ep0_cfg_control_per_function_req             => '0',
        ep0_cfg_control_power_state_change_ack       => '0',
        ep0_cfg_control_power_state_change_interrupt => open,
        ep0_cfg_ext_function_number                  => cfg_ext_function(0),
        ep0_cfg_ext_read_data                        => cfg_ext_read_data(0),
        ep0_cfg_ext_read_data_valid                  => cfg_ext_read_dv(0),
        ep0_cfg_ext_read_received                    => cfg_ext_read(0),
        ep0_cfg_ext_register_number                  => cfg_ext_register(0),
        ep0_cfg_ext_write_byte_enable                => cfg_ext_write_be(0),
        ep0_cfg_ext_write_data                       => cfg_ext_write_data(0),
        ep0_cfg_ext_write_received                   => cfg_ext_write(0),
        ep0_cfg_fc_cpld                              => open,
        ep0_cfg_fc_cpld_scale                        => open,
        ep0_cfg_fc_cplh                              => open,
        ep0_cfg_fc_cplh_scale                        => open,
        ep0_cfg_fc_npd                               => dbg_credits_npd(0),
        ep0_cfg_fc_npd_scale                         => open,
        ep0_cfg_fc_nph                               => dbg_credits_nph(0),
        ep0_cfg_fc_nph_scale                         => open,
        ep0_cfg_fc_pd                                => dbg_credits_pd(0),
        ep0_cfg_fc_pd_scale                          => open,
        ep0_cfg_fc_ph                                => dbg_credits_ph(0),
        ep0_cfg_fc_ph_scale                          => open,
        ep0_cfg_fc_sel                               => "000",
        ep0_cfg_fc_vc_sel                            => '0',
        ep0_cfg_interrupt_intx_vector                => (others => '0'),
        ep0_cfg_interrupt_pending                    => (others => '0'),
        ep0_cfg_interrupt_sent                       => open,
        ep0_cfg_status_10b_tag_requester_enable      => open,
        ep0_cfg_status_atomic_requester_enable       => open,
        ep0_cfg_status_bus_number                    => open,
        ep0_cfg_status_cq_np_req                     => "11",
        ep0_cfg_status_cq_np_req_count               => open,
        ep0_cfg_status_current_speed                 => open,
        ep0_cfg_status_err_cor_out                   => open,
        ep0_cfg_status_err_fatal_out                 => open,
        ep0_cfg_status_err_nonfatal_out              => open,
        ep0_cfg_status_ext_tag_enable                => open,
        ep0_cfg_status_function_power_state          => open,
        ep0_cfg_status_function_status               => open,
        ep0_cfg_status_link_power_state              => open,
        ep0_cfg_status_local_error_out               => open,
        ep0_cfg_status_local_error_valid             => open,
        ep0_cfg_status_ltssm_state                   => open,
        ep0_cfg_status_max_payload                   => cfg_max_payload(0),
        ep0_cfg_status_max_read_req                  => cfg_max_read_req(0),
        ep0_cfg_status_negotiated_width              => open,
        ep0_cfg_status_per_function_out              => open,
        ep0_cfg_status_per_function_vld              => open,
        ep0_cfg_status_phy_link_down                 => open,
        ep0_cfg_status_phy_link_status               => cfg_phy_link_status(0),
        ep0_cfg_status_pl_status_change              => open,
        ep0_cfg_status_rcb_status                    => cfg_rcb_status(0),
        ep0_cfg_status_rq_seq_num0                   => open,
        ep0_cfg_status_rq_seq_num1                   => open,
        ep0_cfg_status_rq_seq_num2                   => open,
        ep0_cfg_status_rq_seq_num3                   => open,
        ep0_cfg_status_rq_seq_num_vld0               => open,
        ep0_cfg_status_rq_seq_num_vld1               => open,
        ep0_cfg_status_rq_seq_num_vld2               => open,
        ep0_cfg_status_rq_seq_num_vld3               => open,
        ep0_cfg_status_rq_tag0                       => open,
        ep0_cfg_status_rq_tag1                       => open,
        ep0_cfg_status_rq_tag2                       => open,
        ep0_cfg_status_rq_tag3                       => open,
        ep0_cfg_status_rq_tag_av                     => open,
        ep0_cfg_status_rq_tag_vld0                   => open,
        ep0_cfg_status_rq_tag_vld1                   => open,
        ep0_cfg_status_rq_tag_vld2                   => open,
        ep0_cfg_status_rq_tag_vld3                   => open,
        ep0_cfg_status_rx_pm_state                   => open,
        ep0_cfg_status_tph_requester_enable          => open,
        ep0_cfg_status_tph_st_mode                   => open,
        ep0_cfg_status_tx_pm_state                   => open,
        ep0_cfg_status_wrreq_bme_vld                 => open,
        ep0_cfg_status_wrreq_flr_vld                 => open,
        ep0_cfg_status_wrreq_function_number         => open,
        ep0_cfg_status_wrreq_msi_vld                 => open,
        ep0_cfg_status_wrreq_msix_vld                => open,
        ep0_cfg_status_wrreq_out_value               => open,
        ep0_cfg_status_wrreq_vfe_vld                 => open,
        ep0_gt_grx_n                                 => PCIE_RX_N(IP_LANES-1 downto 0),
        ep0_gt_grx_p                                 => PCIE_RX_P(IP_LANES-1 downto 0),
        ep0_gt_gtx_n                                 => PCIE_TX_N(IP_LANES-1 downto 0),
        ep0_gt_gtx_p                                 => PCIE_TX_P(IP_LANES-1 downto 0),
        ep0_gt_refclk_clk_n                          => PCIE_SYSCLK_N(0),
        ep0_gt_refclk_clk_p                          => PCIE_SYSCLK_P(0),
        ep0_m_axis_cq_tdata                          => pcie_cq_axi_data(0),
        ep0_m_axis_cq_tkeep                          => pcie_cq_axi_keep(0),
        ep0_m_axis_cq_tlast                          => pcie_cq_axi_last(0),
        ep0_m_axis_cq_tready                         => pcie_cq_axi_ready(0),
        ep0_m_axis_cq_tuser                          => pcie_cq_axi_user(0),
        ep0_m_axis_cq_tvalid                         => pcie_cq_axi_valid(0),
        ep0_m_axis_rc_tdata                          => pcie_rc_axi_data(0),
        ep0_m_axis_rc_tkeep                          => pcie_rc_axi_keep(0),
        ep0_m_axis_rc_tlast                          => pcie_rc_axi_last(0),
        ep0_m_axis_rc_tready                         => pcie_rc_axi_ready(0),
        ep0_m_axis_rc_tuser                          => pcie_rc_axi_user(0),
        ep0_m_axis_rc_tvalid                         => pcie_rc_axi_valid(0),
        ep0_s_axis_cc_tdata                          => pcie_cc_axi_data(0),
        ep0_s_axis_cc_tkeep                          => pcie_cc_axi_keep(0),
        ep0_s_axis_cc_tlast                          => pcie_cc_axi_last(0),
        ep0_s_axis_cc_tready                         => pcie_cc_axi_ready(0),
        ep0_s_axis_cc_tuser                          => pcie_cc_axi_user(0),
        ep0_s_axis_cc_tvalid                         => pcie_cc_axi_valid(0),
        ep0_s_axis_rq_tdata                          => pcie_rq_axi_data(0),
        ep0_s_axis_rq_tkeep                          => pcie_rq_axi_keep(0),
        ep0_s_axis_rq_tlast                          => pcie_rq_axi_last(0),
        ep0_s_axis_rq_tready                         => pcie_rq_axi_ready(0),
        ep0_s_axis_rq_tuser                          => pcie_rq_axi_user(0),
        ep0_s_axis_rq_tvalid                         => pcie_rq_axi_valid(0),
        ep0_transmit_fc_npd_av                       => open,
        ep0_transmit_fc_nph_av                       => open,
        ep0_user_clk                                 => pcie_hip_clk(0),
        ep0_user_lnk_up                              => user_lnk_up(0),
        ep0_user_reset                               => pcie_hip_rst(0),
        ep1_cfg_control_err_cor_in                   => '0',
        ep1_cfg_control_err_uncor_in                 => '0',
        ep1_cfg_control_flr_done                     => '0',
        ep1_cfg_control_flr_done_function_number     => (others => '0'),
        ep1_cfg_control_flr_in_process               => open,
        ep1_cfg_control_hot_reset_in                 => '0',
        ep1_cfg_control_hot_reset_out                => open,
        ep1_cfg_control_per_function_number          => (others => '0'),
        ep1_cfg_control_per_function_req             => '0',
        ep1_cfg_control_power_state_change_ack       => '0',
        ep1_cfg_control_power_state_change_interrupt => open,
        ep1_cfg_ext_function_number                  => cfg_ext_function(1),
        ep1_cfg_ext_read_data                        => cfg_ext_read_data(1),
        ep1_cfg_ext_read_data_valid                  => cfg_ext_read_dv(1),
        ep1_cfg_ext_read_received                    => cfg_ext_read(1),
        ep1_cfg_ext_register_number                  => cfg_ext_register(1),
        ep1_cfg_ext_write_byte_enable                => cfg_ext_write_be(1),
        ep1_cfg_ext_write_data                       => cfg_ext_write_data(1),
        ep1_cfg_ext_write_received                   => cfg_ext_write(1),
        ep1_cfg_fc_cpld                              => open,
        ep1_cfg_fc_cpld_scale                        => open,
        ep1_cfg_fc_cplh                              => open,
        ep1_cfg_fc_cplh_scale                        => open,
        ep1_cfg_fc_npd                               => dbg_credits_npd(1),
        ep1_cfg_fc_npd_scale                         => open,
        ep1_cfg_fc_nph                               => dbg_credits_nph(1),
        ep1_cfg_fc_nph_scale                         => open,
        ep1_cfg_fc_pd                                => dbg_credits_pd(1),
        ep1_cfg_fc_pd_scale                          => open,
        ep1_cfg_fc_ph                                => dbg_credits_ph(1),
        ep1_cfg_fc_ph_scale                          => open,
        ep1_cfg_fc_sel                               => "000",
        ep1_cfg_fc_vc_sel                            => '0',
        ep1_cfg_interrupt_intx_vector                => (others => '0'),
        ep1_cfg_interrupt_pending                    => (others => '0'),
        ep1_cfg_interrupt_sent                       => open,
        ep1_cfg_status_10b_tag_requester_enable      => open,
        ep1_cfg_status_atomic_requester_enable       => open,
        ep1_cfg_status_bus_number                    => open,
        ep1_cfg_status_cq_np_req                     => "11",
        ep1_cfg_status_cq_np_req_count               => open,
        ep1_cfg_status_current_speed                 => open,
        ep1_cfg_status_err_cor_out                   => open,
        ep1_cfg_status_err_fatal_out                 => open,
        ep1_cfg_status_err_nonfatal_out              => open,
        ep1_cfg_status_ext_tag_enable                => open,
        ep1_cfg_status_function_power_state          => open,
        ep1_cfg_status_function_status               => open,
        ep1_cfg_status_link_power_state              => open,
        ep1_cfg_status_local_error_out               => open,
        ep1_cfg_status_local_error_valid             => open,
        ep1_cfg_status_ltssm_state                   => open,
        ep1_cfg_status_max_payload                   => cfg_max_payload(1),
        ep1_cfg_status_max_read_req                  => cfg_max_read_req(1),
        ep1_cfg_status_negotiated_width              => open,
        ep1_cfg_status_per_function_out              => open,
        ep1_cfg_status_per_function_vld              => open,
        ep1_cfg_status_phy_link_down                 => open,
        ep1_cfg_status_phy_link_status               => cfg_phy_link_status(1),
        ep1_cfg_status_pl_status_change              => open,
        ep1_cfg_status_rcb_status                    => cfg_rcb_status(1),
        ep1_cfg_status_rq_seq_num0                   => open,
        ep1_cfg_status_rq_seq_num1                   => open,
        ep1_cfg_status_rq_seq_num2                   => open,
        ep1_cfg_status_rq_seq_num3                   => open,
        ep1_cfg_status_rq_seq_num_vld0               => open,
        ep1_cfg_status_rq_seq_num_vld1               => open,
        ep1_cfg_status_rq_seq_num_vld2               => open,
        ep1_cfg_status_rq_seq_num_vld3               => open,
        ep1_cfg_status_rq_tag0                       => open,
        ep1_cfg_status_rq_tag1                       => open,
        ep1_cfg_status_rq_tag2                       => open,
        ep1_cfg_status_rq_tag3                       => open,
        ep1_cfg_status_rq_tag_av                     => open,
        ep1_cfg_status_rq_tag_vld0                   => open,
        ep1_cfg_status_rq_tag_vld1                   => open,
        ep1_cfg_status_rq_tag_vld2                   => open,
        ep1_cfg_status_rq_tag_vld3                   => open,
        ep1_cfg_status_rx_pm_state                   => open,
        ep1_cfg_status_tph_requester_enable          => open,
        ep1_cfg_status_tph_st_mode                   => open,
        ep1_cfg_status_tx_pm_state                   => open,
        ep1_cfg_status_wrreq_bme_vld                 => open,
        ep1_cfg_status_wrreq_flr_vld                 => open,
        ep1_cfg_status_wrreq_function_number         => open,
        ep1_cfg_status_wrreq_msi_vld                 => open,
        ep1_cfg_status_wrreq_msix_vld                => open,
        ep1_cfg_status_wrreq_out_value               => open,
        ep1_cfg_status_wrreq_vfe_vld                 => open,
        ep1_gt_grx_n                                 => PCIE_RX_N(2*IP_LANES-1 downto IP_LANES),
        ep1_gt_grx_p                                 => PCIE_RX_P(2*IP_LANES-1 downto IP_LANES),
        ep1_gt_gtx_n                                 => PCIE_TX_N(2*IP_LANES-1 downto IP_LANES),
        ep1_gt_gtx_p                                 => PCIE_TX_P(2*IP_LANES-1 downto IP_LANES),
        ep1_gt_refclk_clk_n                          => PCIE_SYSCLK_N(1),
        ep1_gt_refclk_clk_p                          => PCIE_SYSCLK_P(1),
        ep1_m_axis_cq_tdata                          => pcie_cq_axi_data(1),
        ep1_m_axis_cq_tkeep                          => pcie_cq_axi_keep(1),
        ep1_m_axis_cq_tlast                          => pcie_cq_axi_last(1),
        ep1_m_axis_cq_tready                         => pcie_cq_axi_ready(1),
        ep1_m_axis_cq_tuser                          => pcie_cq_axi_user(1),
        ep1_m_axis_cq_tvalid                         => pcie_cq_axi_valid(1),
        ep1_m_axis_rc_tdata                          => pcie_rc_axi_data(1),
        ep1_m_axis_rc_tkeep                          => pcie_rc_axi_keep(1),
        ep1_m_axis_rc_tlast                          => pcie_rc_axi_last(1),
        ep1_m_axis_rc_tready                         => pcie_rc_axi_ready(1),
        ep1_m_axis_rc_tuser                          => pcie_rc_axi_user(1),
        ep1_m_axis_rc_tvalid                         => pcie_rc_axi_valid(1),
        ep1_s_axis_cc_tdata                          => pcie_cc_axi_data(1),
        ep1_s_axis_cc_tkeep                          => pcie_cc_axi_keep(1),
        ep1_s_axis_cc_tlast                          => pcie_cc_axi_last(1),
        ep1_s_axis_cc_tready                         => pcie_cc_axi_ready(1),
        ep1_s_axis_cc_tuser                          => pcie_cc_axi_user(1),
        ep1_s_axis_cc_tvalid                         => pcie_cc_axi_valid(1),
        ep1_s_axis_rq_tdata                          => pcie_rq_axi_data(1),
        ep1_s_axis_rq_tkeep                          => pcie_rq_axi_keep(1),
        ep1_s_axis_rq_tlast                          => pcie_rq_axi_last(1),
        ep1_s_axis_rq_tready                         => pcie_rq_axi_ready(1),
        ep1_s_axis_rq_tuser                          => pcie_rq_axi_user(1),
        ep1_s_axis_rq_tvalid                         => pcie_rq_axi_valid(1),
        ep1_transmit_fc_npd_av                       => open,
        ep1_transmit_fc_nph_av                       => open,
        ep1_user_clk                                 => pcie_hip_clk(1),
        ep1_user_lnk_up                              => user_lnk_up(1),
        ep1_user_reset                               => pcie_hip_rst(1),
        pl0_ref_clk                                  => pl0_ref_clk,
        pl0_resetn                                   => pl0_resetn
    );

    MISC_PCIE2TOP(0)(0)                              <= pl0_ref_clk;
    MISC_PCIE2TOP(0)(1)                              <= pl0_resetn;
    MISC_PCIE2TOP(0)(MISC_PCIE2TOP_WIDTH-1 downto 2) <= (others => '0');
    misc_ep_g : for i in 1 to PCIE_ENDPOINTS-1 generate
        MISC_PCIE2TOP(i) <= (others => '0');
    end generate;

    -- =========================================================================
    --  PCIE ADAPTER
    -- =========================================================================

    pcie_adapter_g : for i in 0 to PCIE_ENDPOINTS-1 generate
        pcie_adapter_i : entity work.PCIE_ADAPTER
        generic map (
            CQ_MFB_REGIONS     => CQ_MFB_REGIONS,
            CQ_MFB_REGION_SIZE => CQ_MFB_REGION_SIZE,
            CQ_MFB_BLOCK_SIZE  => CQ_MFB_BLOCK_SIZE,
            CQ_MFB_ITEM_WIDTH  => CQ_MFB_ITEM_WIDTH,
            RC_MFB_REGIONS     => RC_MFB_REGIONS,
            RC_MFB_REGION_SIZE => RC_MFB_REGION_SIZE,
            RC_MFB_BLOCK_SIZE  => RC_MFB_BLOCK_SIZE,
            RC_MFB_ITEM_WIDTH  => RC_MFB_ITEM_WIDTH,
            CC_MFB_REGIONS     => CC_MFB_REGIONS,
            CC_MFB_REGION_SIZE => CC_MFB_REGION_SIZE,
            CC_MFB_BLOCK_SIZE  => CC_MFB_BLOCK_SIZE,
            CC_MFB_ITEM_WIDTH  => CC_MFB_ITEM_WIDTH,
            RQ_MFB_REGIONS     => RQ_MFB_REGIONS,
            RQ_MFB_REGION_SIZE => RQ_MFB_REGION_SIZE,
            RQ_MFB_BLOCK_SIZE  => RQ_MFB_BLOCK_SIZE,
            RQ_MFB_ITEM_WIDTH  => RQ_MFB_ITEM_WIDTH,
            ENDPOINT_TYPE      => ENDPOINT_TYPE,
            DEVICE             => DEVICE,
            CQ_FIFO_ITEMS      => 512,
            PCIE_MPS_DW        => 512/4,
            AXI_DATA_WIDTH     => AXI_DATA_WIDTH,
            AXI_CQUSER_WIDTH   => AXI_CQUSER_WIDTH,
            AXI_CCUSER_WIDTH   => AXI_CCUSER_WIDTH,
            AXI_RQUSER_WIDTH   => AXI_RQUSER_WIDTH,
            AXI_RCUSER_WIDTH   => AXI_RCUSER_WIDTH,
            AXI_STRADDLING     => true,
            AVST_DOWN_SEG      => CQ_MFB_REGIONS,
            AVST_UP_SEG        => CC_MFB_REGIONS
        )
        port map (
            PCIE_CLK            => pcie_hip_clk(i),
            PCIE_RESET          => pcie_rst(i)(0),

            AVST_DOWN_DATA      => (others => '0'),
            AVST_DOWN_HDR       => (others => '0'),
            AVST_DOWN_PREFIX    => (others => '0'),
            AVST_DOWN_SOP       => (others => '0'),
            AVST_DOWN_EOP       => (others => '0'),
            AVST_DOWN_EMPTY     => (others => '0'),
            AVST_DOWN_BAR_RANGE => (others => '0'),
            AVST_DOWN_VALID     => (others => '0'),
            AVST_DOWN_READY     => open,

            AVST_UP_DATA        => open,
            AVST_UP_HDR         => open,
            AVST_UP_PREFIX      => open,
            AVST_UP_SOP         => open,
            AVST_UP_EOP         => open,
            AVST_UP_ERROR       => open,
            AVST_UP_VALID       => open,
            AVST_UP_READY       => '0',

            CRDT_DOWN_INIT_DONE => '0',
            CRDT_DOWN_UPDATE    => open,
            CRDT_DOWN_CNT_PH    => open,
            CRDT_DOWN_CNT_NPH   => open,
            CRDT_DOWN_CNT_CPLH  => open,
            CRDT_DOWN_CNT_PD    => open,
            CRDT_DOWN_CNT_NPD   => open,
            CRDT_DOWN_CNT_CPLD  => open,

            CRDT_UP_INIT_DONE   => '0',
            CRDT_UP_UPDATE      => (others => '0'),
            CRDT_UP_CNT_PH      => (others => '0'),
            CRDT_UP_CNT_NPH     => (others => '0'),
            CRDT_UP_CNT_CPLH    => (others => '0'),
            CRDT_UP_CNT_PD      => (others => '0'),
            CRDT_UP_CNT_NPD     => (others => '0'),
            CRDT_UP_CNT_CPLD    => (others => '0'),

            CQ_AXI_DATA         => pcie_cq_axi_data(i),
            CQ_AXI_USER         => pcie_cq_axi_user(i),
            CQ_AXI_LAST         => pcie_cq_axi_last(i),
            CQ_AXI_KEEP         => pcie_cq_axi_keep(i),
            CQ_AXI_VALID        => pcie_cq_axi_valid(i),
            CQ_AXI_READY        => pcie_cq_axi_ready(i),

            RC_AXI_DATA         => pcie_rc_axi_data(i),
            RC_AXI_USER         => pcie_rc_axi_user(i),
            RC_AXI_LAST         => pcie_rc_axi_last(i),
            RC_AXI_KEEP         => pcie_rc_axi_keep(i),
            RC_AXI_VALID        => pcie_rc_axi_valid(i),
            RC_AXI_READY        => pcie_rc_axi_ready(i),

            CC_AXI_DATA         => pcie_cc_axi_data(i),
            CC_AXI_USER         => pcie_cc_axi_user(i),
            CC_AXI_LAST         => pcie_cc_axi_last(i),
            CC_AXI_KEEP         => pcie_cc_axi_keep(i),
            CC_AXI_VALID        => pcie_cc_axi_valid(i),
            CC_AXI_READY        => pcie_cc_axi_ready(i),

            RQ_AXI_DATA         => pcie_rq_axi_data(i),
            RQ_AXI_USER         => pcie_rq_axi_user(i),
            RQ_AXI_LAST         => pcie_rq_axi_last(i),
            RQ_AXI_KEEP         => pcie_rq_axi_keep(i),
            RQ_AXI_VALID        => pcie_rq_axi_valid(i),
            RQ_AXI_READY        => pcie_rq_axi_ready(i),

            CQ_MFB_DATA         => CQ_MFB_DATA(i),
            CQ_MFB_META         => CQ_MFB_META(i),
            CQ_MFB_SOF          => CQ_MFB_SOF(i),
            CQ_MFB_EOF          => CQ_MFB_EOF(i),
            CQ_MFB_SOF_POS      => CQ_MFB_SOF_POS(i),
            CQ_MFB_EOF_POS      => CQ_MFB_EOF_POS(i),
            CQ_MFB_SRC_RDY      => CQ_MFB_SRC_RDY(i),
            CQ_MFB_DST_RDY      => CQ_MFB_DST_RDY(i),

            RC_MFB_DATA         => RC_MFB_DATA(i),
            RC_MFB_META         => RC_MFB_META(i),
            RC_MFB_SOF          => RC_MFB_SOF(i),
            RC_MFB_EOF          => RC_MFB_EOF(i),
            RC_MFB_SOF_POS      => RC_MFB_SOF_POS(i),
            RC_MFB_EOF_POS      => RC_MFB_EOF_POS(i),
            RC_MFB_SRC_RDY      => RC_MFB_SRC_RDY(i),
            RC_MFB_DST_RDY      => RC_MFB_DST_RDY(i),

            CC_MFB_DATA         => CC_MFB_DATA(i),
            CC_MFB_META         => CC_MFB_META(i),
            CC_MFB_SOF          => CC_MFB_SOF(i),
            CC_MFB_EOF          => CC_MFB_EOF(i),
            CC_MFB_SOF_POS      => CC_MFB_SOF_POS(i),
            CC_MFB_EOF_POS      => CC_MFB_EOF_POS(i),
            CC_MFB_SRC_RDY      => CC_MFB_SRC_RDY(i),
            CC_MFB_DST_RDY      => CC_MFB_DST_RDY(i),

            RQ_MFB_DATA         => RQ_MFB_DATA(i),
            RQ_MFB_META         => RQ_MFB_META(i),
            RQ_MFB_SOF          => RQ_MFB_SOF(i),
            RQ_MFB_EOF          => RQ_MFB_EOF(i),
            RQ_MFB_SOF_POS      => RQ_MFB_SOF_POS(i),
            RQ_MFB_EOF_POS      => RQ_MFB_EOF_POS(i),
            RQ_MFB_SRC_RDY      => RQ_MFB_SRC_RDY(i),
            RQ_MFB_DST_RDY      => RQ_MFB_DST_RDY(i)
        );
    end generate;

    -- =========================================================================
    --  PCIE RESET LOGIC
    -- =========================================================================

    pcie_rst_g : for i in 0 to PCIE_ENDPOINTS-1 generate
        pcie_rst_async(i) <= pcie_hip_rst(i) or not user_lnk_up(i);

        pcie_rst_sync_i : entity work.ASYNC_RESET
        generic map (
            TWO_REG  => false,
            OUT_REG  => true,
            REPLICAS => RESET_WIDTH+1
        )
        port map (
            CLK       => pcie_hip_clk(i),
            ASYNC_RST => pcie_rst_async(i),
            OUT_RST   => pcie_rst(i)
        );

        PCIE_USER_CLK(i)   <= pcie_hip_clk(i);
        PCIE_USER_RESET(i) <= pcie_rst(i)(RESET_WIDTH+1-1 downto 1);
    end generate;

    -- =========================================================================
    --  PCIE CONFIGURATION REGISTERS
    -- =========================================================================

    pcie_cfg_g : for i in 0 to PCIE_ENDPOINTS-1 generate
        pcie_cfg_p : process (pcie_hip_clk(i))
        begin
            if (rising_edge(pcie_hip_clk(i))) then
                PCIE_LINK_UP(i)  <= cfg_phy_link_status(i)(0) and cfg_phy_link_status(i)(1);
                PCIE_RCB_SIZE(i) <= cfg_rcb_status(i);
                PCIE_MRRS(i)     <= cfg_max_read_req(i);
                PCIE_MPS(i)      <= '0' & cfg_max_payload(i);
            end if;
        end process;
        PCIE_EXT_TAG_EN(i)     <= '1';
        PCIE_10B_TAG_REQ_EN(i) <= '0';
    end generate;

    -- =========================================================================
    --  PCI EXT CAP - DEVICE TREE
    -- =========================================================================

    dt_g : for i in 0 to PCIE_ENDPOINTS-1 generate
        -- Copies for the PSL checks below, which nvc cannot give indexed signals
        signal ep_clk        : std_logic;
        signal ext_rd_user   : std_logic;
        signal ext_rd_core   : std_logic;
        signal ext_dv        : std_logic;
        signal ext_dv_both   : std_logic;
    begin

        pci_ext_cap_i : entity work.PCI_EXT_CAP
        generic map (
            VSEC_BASE_ADDRESS      => VSEC_BASE_ADDRESS,
            VSEC_NEXT_POINTER      => 0,
            ENDPOINT_ID            => i,
            ENDPOINT_ID_ENABLE     => true,
            DEVICE_TREE_ENABLE     => true,
            CARD_ID_WIDTH          => CARD_ID_WIDTH,
            CFG_EXT_READ_DV_HOTFIX => false
        )
        port map (
            CLK                    => pcie_hip_clk(i),
            CARD_ID                => CARD_ID(i),
            CFG_EXT_READ           => cfg_ext_read(i),
            CFG_EXT_WRITE          => cfg_ext_write(i),
            CFG_EXT_REGISTER       => cfg_ext_register(i),
            CFG_EXT_FUNCTION       => cfg_ext_function(i)(7 downto 0),
            CFG_EXT_WRITE_DATA     => cfg_ext_write_data(i),
            CFG_EXT_WRITE_BE       => cfg_ext_write_be(i),
            CFG_EXT_READ_DATA      => cfg_ext_read_dtb_data(i),
            CFG_EXT_READ_DV        => cfg_ext_read_dtb_dv(i)
        );

        -- The core reports every configuration read but expects an answer to each one in 0x600-0xFFC (PG346 Table 45); PCI_EXT_CAP answers its own registers, this answers the rest with zeros.
        cfg_ext_zero_p : process (pcie_hip_clk(i))
            variable reg : natural;
        begin
            if (rising_edge(pcie_hip_clk(i))) then
                reg                     := to_integer(unsigned(cfg_ext_register(i)));
                cfg_ext_read_zero_dv(i) <= '0';
                if (cfg_ext_read(i) = '1' and reg >= EXT_CFG_FIRST_REG + VSEC_REGS and reg <= EXT_CFG_LAST_REG) then
                    cfg_ext_read_zero_dv(i) <= '1';
                end if;
            end if;
        end process;

        cfg_ext_read_dv(i)   <= cfg_ext_read_dtb_dv(i) or cfg_ext_read_zero_dv(i);
        cfg_ext_read_data(i) <= cfg_ext_read_dtb_data(i) when (cfg_ext_read_dtb_dv(i) = '1') else (others => '0');

        ep_clk      <= pcie_hip_clk(i);
        ext_rd_user <= cfg_ext_read(i) when (unsigned(cfg_ext_register(i)) >= EXT_CFG_FIRST_REG) else '0';
        ext_rd_core <= cfg_ext_read(i) when (unsigned(cfg_ext_register(i)) < EXT_CFG_FIRST_REG) else '0';
        ext_dv      <= cfg_ext_read_dv(i);
        ext_dv_both <= cfg_ext_read_dtb_dv(i) and cfg_ext_read_zero_dv(i);

        -- psl default clock is rising_edge(ep_clk);
        -- psl cpm5_cfg_ext_user_read_answered : assert always (ext_rd_user = '1' -> next (ext_dv = '1'))
        --     report "CPM5 cfg_ext: a read of the user space 0x600-0xFFC got no answer";
        -- psl cpm5_cfg_ext_core_read_unanswered : assert always (ext_rd_core = '1' -> next (ext_dv = '0'))
        --     report "CPM5 cfg_ext: a read the core answers itself got an answer from the fabric";
        -- psl cpm5_cfg_ext_one_answer : assert never (ext_dv_both = '1')
        --     report "CPM5 cfg_ext: PCI_EXT_CAP and the zero filler answered the same read";
    end generate;

    -- =========================================================================
    --  DEBUG logic
    -- =========================================================================

    debug_i : entity work.PCIE_CORE_DEBUG
    generic map (
        PCIE_ENDPOINTS => PCIE_ENDPOINTS,
        DBG_CRDT_PH_W  => 8,
        DBG_CRDT_NPH_W => 8,
        DBG_CRDT_PD_W  => 12,
        DBG_CRDT_NPD_W => 12,
        DBG_ENABLE     => PCIE_CORE_DEBUG_ENABLE,
        MI_WIDTH       => MI_WIDTH,
        DEVICE         => DEVICE
    )
    port map (
        PCIE_CLK            => pcie_hip_clk,
        PCIE_RESET          => pcie_hip_rst,

        DBG_UP_SRC_RDY      => pcie_rq_axi_valid,
        DBG_UP_DST_RDY      => pcie_rq_axi_ready,
        DBG_DW_SRC_RDY      => pcie_rc_axi_valid,
        DBG_DW_DST_RDY      => pcie_rc_axi_ready,

        DBG_CREDITS_PH      => dbg_credits_ph,
        DBG_CREDITS_NPH     => dbg_credits_nph,
        DBG_CREDITS_PD      => dbg_credits_pd,
        DBG_CREDITS_NPD     => dbg_credits_npd,

        DBG_CREDITS_PH_VLD  => (others => '1'),
        DBG_CREDITS_NPH_VLD => (others => '1'),
        DBG_CREDITS_PD_VLD  => (others => '1'),
        DBG_CREDITS_NPD_VLD => (others => '1'),

        MI_CLK              => MI_CLK,
        MI_RESET            => MI_RESET,
        MI_DWR              => MI_DWR,
        MI_ADDR             => MI_ADDR,
        MI_BE               => MI_BE,
        MI_RD               => MI_RD,
        MI_WR               => MI_WR,
        MI_ARDY             => MI_ARDY,
        MI_DRD              => MI_DRD,
        MI_DRDY             => MI_DRDY
    );

end architecture;
