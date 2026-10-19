# v80_platform_bd.tcl: block designs of the Alveo V80 platform (CIPS with two CPM5 PCIe endpoints, HBM NoC)
# Copyright (C) 2026 Universitaet Heidelberg, Institut fuer Technische Informatik (ZITI)
# Author(s): Vladislav Valek <vladislav.valek@stud.uni-heidelberg.de>
#
# SPDX-License-Identifier: Apache-2.0

# CPM_CONFIG entries of one CPM5 controller in controller-only PCIE mode, Gen5 x8 endpoint with a 1024-bit straddled AXI4-Stream at 250 MHz.
proc v80_cpm_ctrl_config {ctrl pf0_dev_id pf1_dev_id} {
    set c "CPM_PCIE${ctrl}"
    return [list \
        ${c}_MODES                                {PCIE} \
        ${c}_MODE_SELECTION                       {Advanced} \
        ${c}_PORT_TYPE                            {PCI_Express_Endpoint_device} \
        ${c}_MAX_LINK_SPEED                       {32.0_GT/s} \
        ${c}_PL_LINK_CAP_MAX_LINK_WIDTH           {X8} \
        ${c}_AXISTEN_IF_WIDTH                     {1024} \
        ${c}_USER_CLK_FREQ                        {250_MHz} \
        ${c}_CQ_STRADDLE_SIZE                     {4_TLP} \
        ${c}_CC_STRADDLE_SIZE                     {4_TLP} \
        ${c}_RQ_STRADDLE_SIZE                     {4_TLP} \
        ${c}_RC_STRADDLE_SIZE                     {8_TLP} \
        ${c}_AXISTEN_IF_CQ_ALIGNMENT_MODE         {DWORD_Aligned} \
        ${c}_AXISTEN_IF_CC_ALIGNMENT_MODE         {DWORD_Aligned} \
        ${c}_AXISTEN_IF_RQ_ALIGNMENT_MODE         {DWORD_Aligned} \
        ${c}_AXISTEN_IF_RC_ALIGNMENT_MODE         {DWORD_Aligned} \
        ${c}_AXISTEN_IF_ENABLE_CLIENT_TAG         {1} \
        ${c}_AXISTEN_IF_ENABLE_256_TAGS           {1} \
        ${c}_PF0_DEV_CAP_EXT_TAG_EN               {1} \
        ${c}_PF0_DEV_CAP_10B_TAG_EN               {1} \
        ${c}_PF0_DEV_CAP_MAX_PAYLOAD              {1024_bytes} \
        ${c}_CFG_STS_IF                           {1} \
        ${c}_CFG_CTL_IF                           {1} \
        ${c}_CFG_FC_IF                            {1} \
        ${c}_CFG_EXT_IF                           {1} \
        ${c}_TX_FC_IF                             {1} \
        ${c}_CFG_MGMT_IF                          {0} \
        ${c}_MESG_RSVD_IF                         {0} \
        ${c}_MESG_TRANSMIT_IF                     {0} \
        ${c}_EXT_PCIE_CFG_SPACE_ENABLED           {Extended_Large} \
        ${c}_MSI_X_OPTIONS                        {None} \
        ${c}_TL_PF_ENABLE_REG                     {2} \
        ${c}_COPY_PF0_ENABLED                     {0} \
        ${c}_CFG_VEND_ID                          {18ec} \
        ${c}_PF0_CFG_DEV_ID                       $pf0_dev_id \
        ${c}_PF0_CFG_SUBSYS_ID                    $pf0_dev_id \
        ${c}_PF0_CFG_SUBSYS_VEND_ID               {18ec} \
        ${c}_PF0_USE_CLASS_CODE_LOOKUP_ASSISTANT  {0} \
        ${c}_PF0_BASE_CLASS_VALUE                 {02} \
        ${c}_PF0_SUB_CLASS_VALUE                  {00} \
        ${c}_PF0_INTERFACE_VALUE                  {00} \
        ${c}_PF0_DSN_CAP_ENABLE                   {1} \
        ${c}_PF0_MSI_ENABLED                      {0} \
        ${c}_PF0_MSIX_ENABLED                     {0} \
        ${c}_PF0_BAR0_ENABLED                     {1} \
        ${c}_PF0_BAR0_64BIT                       {1} \
        ${c}_PF0_BAR0_PREFETCHABLE                {0} \
        ${c}_PF0_BAR0_SCALE                       {Megabytes} \
        ${c}_PF0_BAR0_SIZE                        {64} \
        ${c}_PF0_BAR2_ENABLED                     {0} \
        ${c}_PF1_CFG_DEV_ID                       $pf1_dev_id \
        ${c}_PF1_CFG_SUBSYS_ID                    $pf1_dev_id \
        ${c}_PF1_CFG_SUBSYS_VEND_ID               {18ec} \
        ${c}_PF1_USE_CLASS_CODE_LOOKUP_ASSISTANT  {0} \
        ${c}_PF1_BASE_CLASS_VALUE                 {05} \
        ${c}_PF1_SUB_CLASS_VALUE                  {80} \
        ${c}_PF1_INTERFACE_VALUE                  {00} \
        ${c}_PF1_MSI_ENABLED                      {0} \
        ${c}_PF1_MSIX_ENABLED                     {0} \
        ${c}_PF1_BAR0_ENABLED                     {1} \
        ${c}_PF1_BAR0_64BIT                       {1} \
        ${c}_PF1_BAR0_PREFETCHABLE                {1} \
        ${c}_PF1_BAR0_SCALE                       {Gigabytes} \
        ${c}_PF1_BAR0_SIZE                        {1} \
        ${c}_PF1_BAR2_ENABLED                     {0} \
    ]
}

# HBM controller settings of one channel, taken from the Vivado HBM_Foundational tutorial with ECC, scrubbing and parity off and the write data mask on.
proc v80_hbm_chnl_config {} {
    return [list \
        HBM_REORDER_EN                        FALSE \
        HBM_MAINTAIN_COHERENCY                TRUE \
        HBM_Q_AGE_LIMIT                       0x7f \
        HBM_CLOSE_PAGE_REORDER                FALSE \
        HBM_LOOKAHEAD_PCH                     TRUE \
        HBM_COMMAND_PARITY                    FALSE \
        HBM_DQ_WR_PARITY                      FALSE \
        HBM_DQ_RD_PARITY                      FALSE \
        HBM_RD_DBI                            TRUE \
        HBM_WR_DBI                            TRUE \
        HBM_REFRESH_MODE                      ALL_BANK_REFRESH \
        HBM_PC0_PRE_DEFINED_ADDRESS_MAP       ROW_BANK_COLUMN_BGO \
        HBM_PC1_PRE_DEFINED_ADDRESS_MAP       ROW_BANK_COLUMN_BGO \
        HBM_PC0_USER_DEFINED_ADDRESS_MAP      NONE \
        HBM_PC1_USER_DEFINED_ADDRESS_MAP      NONE \
        HBM_PC0_ADDRESS_MAP                   RA14,RA13,RA12,RA11,RA10,RA9,RA8,RA7,RA6,RA5,RA4,RA3,RA2,RA1,RA0,SID,BA1,BA0,BA3,CA5,CA4,CA3,CA2,CA1,BA2,NC,NA,NA,NA,NA \
        HBM_PC1_ADDRESS_MAP                   RA14,RA13,RA12,RA11,RA10,RA9,RA8,RA7,RA6,RA5,RA4,RA3,RA2,RA1,RA0,SID,BA1,BA0,BA3,CA5,CA4,CA3,CA2,CA1,BA2,NC,NA,NA,NA,NA \
        HBM_PWR_DWN_IDLE_TIMEOUT_ENTRY        FALSE \
        HBM_SELF_REF_IDLE_TIMEOUT_ENTRY       FALSE \
        HBM_IDLE_TIME_TO_ENTER_PWR_DWN_MODE   0x0001000 \
        HBM_IDLE_TIME_TO_ENTER_SELF_REF_MODE  1X \
        HBM_ECC_CORRECTION_EN                 FALSE \
        HBM_WRITE_BACK_CORRECTED_DATA         TRUE \
        HBM_ECC_SCRUBBING                     FALSE \
        HBM_ECC_INITIALIZE_EN                 FALSE \
        HBM_ECC_SCRUB_SIZE                    1092 \
        HBM_WRITE_DATA_MASK                   TRUE \
        HBM_REF_PERIOD_TEMP_COMP              FALSE \
        HBM_PARITY_LATENCY                    3 \
        HBM_PC0_PAGE_HIT                      100.000 \
        HBM_PC1_PAGE_HIT                      100.000 \
        HBM_PC0_READ_RATE                     25.000 \
        HBM_PC1_READ_RATE                     25.000 \
        HBM_PC0_WRITE_RATE                    25.000 \
        HBM_PC1_WRITE_RATE                    25.000 \
        HBM_PC0_PHY_ACTIVE                    ENABLED \
        HBM_PC1_PHY_ACTIVE                    ENABLED \
        HBM_PC0_SCRUB_START_ADDRESS           0x0000000 \
        HBM_PC0_SCRUB_END_ADDRESS             0x3FFFBFF \
        HBM_PC0_SCRUB_INTERVAL                24.000 \
        HBM_PC1_SCRUB_START_ADDRESS           0x0000000 \
        HBM_PC1_SCRUB_END_ADDRESS             0x3FFFBFF \
        HBM_PC1_SCRUB_INTERVAL                24.000 \
    ]
}

# Adds the CIPS with both CPM5 controllers and the PL0 clock to the current BD. NDK endpoint 0 is CPM5 controller 1 (edge lanes 0-7), endpoint 1 is controller 0 (lanes 8-15), PG347 Table 296.
proc v80_add_cips {ep0_pf0_id ep0_pf1_id ep1_pf0_id ep1_pf1_id} {
    set cips [create_bd_cell -type ip -vlnv xilinx.com:ip:versal_cips cips]

    set cpm_config [concat [v80_cpm_ctrl_config 1 $ep0_pf0_id $ep0_pf1_id] [v80_cpm_ctrl_config 0 $ep1_pf0_id $ep1_pf1_id]]

    # Board facts follow AVED amd_v80_gen5x8_25.1: OSPI boot on PMC MIO 0-11, 33.33 MHz PMC refclk, 0.88 V PMC rail of the -2MHP overdrive part, CPM_TOPSW at the overdrive 1000 MHz.
    set pmc_config [list \
        BOOT_MODE                          {Custom} \
        CLOCK_MODE                         {Custom} \
        DDR_MEMORY_MODE                    {Custom} \
        DESIGN_MODE                        {1} \
        DEVICE_INTEGRITY_MODE              {Custom} \
        IO_CONFIG_MODE                     {Custom} \
        PS_BOARD_INTERFACE                 {Custom} \
        PS_PL_CONNECTIVITY_MODE            {Custom} \
        PMC_BANK_1_IO_STANDARD             {LVCMOS3.3} \
        PS_BANK_2_IO_STANDARD              {LVCMOS3.3} \
        PMC_REF_CLK_FREQMHZ                {33.333333} \
        PMC_GLITCH_CONFIG                  {{DEPTH_SENSITIVITY 1} {MIN_PULSE_WIDTH 0.5} {TYPE CUSTOM} {VCC_PMC_VALUE 0.88}} \
        PMC_GLITCH_CONFIG_1                {{DEPTH_SENSITIVITY 1} {MIN_PULSE_WIDTH 0.5} {TYPE CUSTOM} {VCC_PMC_VALUE 0.88}} \
        PMC_GLITCH_CONFIG_2                {{DEPTH_SENSITIVITY 1} {MIN_PULSE_WIDTH 0.5} {TYPE CUSTOM} {VCC_PMC_VALUE 0.88}} \
        PMC_OSPI_PERIPHERAL                {{ENABLE 1} {IO {PMC_MIO 0 .. 11}} {MODE Single}} \
        PMC_CRP_OSPI_REF_CTRL_FREQMHZ      {200} \
        PMC_MIO_EN_FOR_PL_PCIE             {0} \
        PMC_GPIO_EMIO_PERIPHERAL_ENABLE    {0} \
        PS_GPIO_EMIO_PERIPHERAL_ENABLE     {0} \
        PMC_USE_PMC_NOC_AXI0               {0} \
        PS_USE_NOC_LPD_AXI0                {0} \
        PS_USE_FPD_CCI_NOC                 {0} \
        PS_USE_M_AXI_FPD                   {0} \
        PS_USE_M_AXI_LPD                   {0} \
        PS_USE_S_AXI_LPD                   {0} \
        PS_CRL_CPM_TOPSW_REF_CTRL_FREQMHZ  {1000} \
        PCIE_APERTURES_DUAL_ENABLE         {0} \
        PCIE_APERTURES_SINGLE_ENABLE       {0} \
        PS_PCIE1_PERIPHERAL_ENABLE         {1} \
        PS_PCIE2_PERIPHERAL_ENABLE         {1} \
        PS_PCIE_RESET                      {{ENABLE 1}} \
        PS_PCIE_EP_RESET1_IO               {PMC_MIO 24} \
        PS_PCIE_EP_RESET2_IO               {PMC_MIO 25} \
        PS_USE_PMCPL_CLK0                  {1} \
        PMC_CRP_PL0_REF_CTRL_FREQMHZ       {100} \
        PS_NUM_FABRIC_RESETS               {1} \
    ]

    set_property -dict [list CONFIG.CPM_CONFIG $cpm_config CONFIG.PS_PMC_CONFIG $pmc_config] $cips

    # Controller 1 feeds NDK endpoint 0, controller 0 endpoint 1, so the ports are named by endpoint.
    foreach {ctrl ep} {1 ep0 0 ep1} {
        set refclk [create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 ${ep}_gt_refclk]
        set_property CONFIG.FREQ_HZ {100000000} $refclk
        connect_bd_intf_net $refclk [get_bd_intf_pins $cips/gt_refclk${ctrl}]

        make_bd_intf_pins_external -name ${ep}_gt [get_bd_intf_pins $cips/PCIE${ctrl}_GT]

        foreach intf [get_bd_intf_pins -quiet -of_objects $cips -filter "NAME =~ pcie${ctrl}_*"] {
            set suffix [string range [get_property NAME $intf] [string length "pcie${ctrl}_"] end]
            make_bd_intf_pins_external -name ${ep}_${suffix} $intf
        }
        foreach pin [get_bd_pins -quiet -of_objects $cips -filter "NAME =~ pcie${ctrl}_* && INTF == FALSE"] {
            set suffix [string range [get_property NAME $pin] [string length "pcie${ctrl}_"] end]
            make_bd_pins_external -name ${ep}_${suffix} $pin
        }
    }

    # The free-running 100 MHz PL0 clock and its reset leave the BD for the NDK MI and reset logic.
    make_bd_pins_external -name pl0_ref_clk [get_bd_pins $cips/pl0_ref_clk]
    make_bd_pins_external -name pl0_resetn  [get_bd_pins $cips/pl0_resetn]
}

# Adds the HBM-only axi_noc (stack 0 channel 0) and its refclk port to the current BD. ECC is off because PG313 makes ECC and the write data mask exclusive and WSTRB partial writes need the mask.
proc v80_add_hbm_noc {} {
    set noc_hbm [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_noc axi_noc_hbm]
    set_property -dict [list \
        CONFIG.NUM_SI                 {0} \
        CONFIG.NUM_MI                 {0} \
        CONFIG.NUM_CLKS               {0} \
        CONFIG.NUM_HBM_BLI            {0} \
        CONFIG.HBM_NUM_CHNL           {1} \
        CONFIG.HBM_CHNL_EN_0          {true} \
        CONFIG.HBM_REF_CLK_SELECTION  {External} \
        CONFIG.HBM_REF_CLK_FREQ0      {200.000} \
        CONFIG.HBM_PHYIO_CNTRL_BLOCK  {false} \
        CONFIG.HBM_CHNL0_CONFIG       [v80_hbm_chnl_config] \
    ] $noc_hbm

    set hbm_ref_clk_0 [create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 hbm_ref_clk_0]
    set_property CONFIG.FREQ_HZ {200000000} $hbm_ref_clk_0
    connect_bd_intf_net $hbm_ref_clk_0 [get_bd_intf_pins $noc_hbm/hbm_ref_clk0]
}

# CIPS BD the CPM5 arch of PCIE_CORE instantiates (wrapper <bd_name>_wrapper, cpm5_cips in the NDK build).
proc create_v80_cips_bd {bd_name {ep0_pf0_id c000} {ep0_pf1_id c020} {ep1_pf0_id c021} {ep1_pf1_id c022}} {
    create_bd_design $bd_name
    current_bd_design $bd_name
    v80_add_cips $ep0_pf0_id $ep0_pf1_id $ep1_pf0_id $ep1_pf1_id
    validate_bd_design
    save_bd_design
}

# HBM BD the application instantiates next to its NMUs (wrapper <bd_name>_wrapper).
proc create_v80_hbm_bd {bd_name} {
    create_bd_design $bd_name
    current_bd_design $bd_name
    v80_add_hbm_noc
    validate_bd_design
    save_bd_design
}

# Single BD with both, the layout the platform prototype proved; kept for flows that want one BD.
proc create_v80_platform_bd {bd_name {ep0_pf0_id c000} {ep0_pf1_id c020} {ep1_pf0_id c021} {ep1_pf1_id c022}} {
    create_bd_design $bd_name
    current_bd_design $bd_name
    v80_add_cips $ep0_pf0_id $ep0_pf1_id $ep1_pf0_id $ep1_pf1_id
    v80_add_hbm_noc
    validate_bd_design
    save_bd_design
}
