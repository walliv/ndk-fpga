# Vivado_common.inc.tcl: procedures shared by the project (Vivado.inc.tcl) and non-project (Vivado_non_prj.inc.tcl) flows
# Copyright (C) 2013 CESNET
# Author: Viktor Puš <pus@cesnet.cz>
#         Jiri Matousek <xmatou06@stud.fit.vutbr.cz>
#
# SPDX-License-Identifier: BSD-3-Clause

if {![info exists $env(OFM_PATH)]} {
    set OFM_PATH $env(OFM_PATH)
}

if {![info exists $env(FIRMWARE_BASE)]} {
    set FIRMWARE_BASE $env(FIRMWARE_BASE)
}

# Hack for older synth scripts: set OFM_PATH from FIRMWARE_BASE
# This hack is only for components inside OFM repository

if {![info exists OFM_PATH]} {
    set OFM_PATH $FIRMWARE_BASE
}

# Source scripts with further procedures utilized during design compilation
source $OFM_PATH/build/Shared.tcl
source $OFM_PATH/build/DevTree.tcl
source $OFM_PATH/build/targets.tcl

# Including filtering procedures
source $OFM_PATH/build/scripts/vivado/msg_filter/tcl_msg_filters.tcl

# ---------------------------------------------------------------------
#                     Procedures and functions
# ---------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Procedure ip_dir_prepare / ip_dir_finish / ip_dir_record
# create_ip -dir needs its keyed directory to exist and renames a taken output folder to <name>_N, but not every IP
# script passes -dir. The directory is emptied and made before the script runs, then removed if empty or else recorded
# for "make clean".
#
proc ip_dir_prepare {dir} {
    if {[string match ipcfg_* [file tail $dir]]} {
        file delete -force $dir
    }
    file mkdir $dir
}

proc ip_dir_finish {dir} {
    if {![llength [glob -nocomplain -directory $dir *]]} {
        file delete $dir
    }
}

proc ip_dir_record {dir list_file} {
    set dir [file normalize $dir]
    if {[file exists $list_file]} {
        set fh [open $list_file r]
        set known [split [read $fh] "\n"]
        close $fh
        if {$dir in $known} {
            return
        }
    }
    set fh [open $list_file a]
    puts $fh $dir
    close $fh
}

# -----------------------------------------------------------------------------
# Procedure ip_dir_keyed
# The keyed output directory of the IP script that a source entry runs, or an empty string if the entry has none.
#
proc ip_dir_keyed {OPT} {
    array set opt $OPT
    if {[info exists opt(IP_DIR_KEYED)] && $opt(IP_DIR_KEYED)} {
        return $opt(IP_BUILD_DIR)
    }
    return ""
}

# -----------------------------------------------------------------------------
# Procedure file_properties
# The properties that the options of a source file ask for, each as the arguments of set_property before its object.
# EvalFile sets them in the project and filelist_EvalFile writes them to the filelist.
#
proc file_properties {OPT} {
    array set opt $OPT
    set properties [list]

    if {$opt(TYPE) == "CONSTR_VIVADO"} {
        foreach name {SCOPED_TO_REF PROCESSING_ORDER USED_IN} {
            if {[info exists opt($name)]} {
                lappend properties [list $name $opt($name)]
            }
        }
    }

    foreach {param_name param_value} $OPT {
        if {$param_name == "VIVADO_SET_PROPERTY"} {
            lappend properties $param_value
        }
    }
    return $properties
}

# -----------------------------------------------------------------------------
# Procedure tcl_script_runs
# Whether the Tcl script of a source entry runs while the files are added.
#
proc tcl_script_runs {OPT} {
    array set opt $OPT
    return [expr {[info exists opt(PHASE)] && "ADD_FILES" in $opt(PHASE)}]
}

# -----------------------------------------------------------------------------
# Procedure EvalTclScript
# Runs the Tcl script of a source entry while the files are added.
#
proc EvalTclScript {FNAME OPT} {
    if {![tcl_script_runs $OPT]} {
        return
    }
    array set opt $OPT
    puts "Running script: $FNAME"

    set vars ""
    if {[info exists opt(VARS)]} {
        set vars $opt(VARS)
    }
    set keyed_ip_dir [ip_dir_keyed $OPT]
    if {$keyed_ip_dir ne ""} {
        ip_dir_prepare $keyed_ip_dir
    }
    source_with_vars $FNAME $vars
    if {$keyed_ip_dir ne ""} {
        ip_dir_finish $keyed_ip_dir
        if {[file isdirectory $keyed_ip_dir]} {
            ip_dir_record $keyed_ip_dir ipcfg_dirs.txt
        }
    }
}

# -----------------------------------------------------------------------------
# Procedure SetFileProperties
# Sets the properties that the options of an added source file ask for.
#
proc SetFileProperties {FNAME OPT} {
    foreach property [file_properties $OPT] {
        puts "- file property: $property"
        set_property {*}$property [get_files [file tail $FNAME]]
    }
}

# Call component's local Vivado_presynth.tcl
# (used for local constraints application before synthesis)
proc EvalComp {ENTITY ENTITY_BASE ARCHGRP} {
    # Vivado_presynth: DEPRECATED
    set ENTITY_VFILE "$ENTITY_BASE/Vivado_presynth.tcl"

    if {[file exists $ENTITY_VFILE]} {
        source $ENTITY_VFILE
    }
}

# -----------------------------------------------------------------------------
# Procedure AddInputFiles
# Recursively goes through the components hierarchy and adds all design files to project.
#
proc AddInputFiles {synth_flags hierarchy {eval_mod_proc "EvalFile"} {eval_comp_proc "EvalComp"}} {
    # Define auxiliary variables
    upvar 1 $hierarchy HIERARCHY
    upvar 1 $synth_flags SYNTH_FLAGS

    set FILES [list ]
    set SV_LIBS [list ]

    # Add packages
    PrintLabel "Packages compilation"

    ApplyToMods $HIERARCHY(PACKAGES) $eval_mod_proc FILES

    # Add components
    PrintLabel "Components compilation"
    ApplyToComponents $HIERARCHY(COMPONENTS) $eval_mod_proc FILES SV_LIBS 1 $eval_comp_proc

    # Add modules
    PrintLabel "Modules compilation"
    ApplyToMods $HIERARCHY(MOD) $eval_mod_proc FILES
    ApplyToMods $HIERARCHY(TOP_LEVEL) $eval_mod_proc FILES

    # Add constraints
    PrintLabel "Constraints compilation"
    ApplyToMods $SYNTH_FLAGS(CONSTR) $eval_mod_proc FILES "CONSTR_VIVADO"

    return $FILES
}

# -----------------------------------------------------------------------------
# Procedure ParseDirective
# If the directive passed from the user already contains '-directive' switch
# then parse it as it is. However, when the directive only contains the name
# of the directive, then prepend '-directive' keyword before that. This is
# to allow user to choose either one specified directive or pass the combination
# of switches of his choice.
proc ParseDirective {switch_list} {

    # puts "ParseDirective switches: $switch_list"
    # Check if the string DOES NOT contain switch-like patterns and
    # is longer than 0
    if {
        (![regexp {\-(\S+)\s+(?:\S+)} $switch_list match sw value])
        && [string length $switch_list] > 0
    } {
        # String does not contain switch-like patterns, add a default switch
        puts "Switch list DOES NOT contain switch-like patterns"
        return [list "-directive" $switch_list]
    }

    # String contains switch-like patterns, parse it as it is
    puts "Switch list DOES contain switch-like patterns"
    return $switch_list
}

# -----------------------------------------------------------------------------
# Procedure SynthSettings
# The synthesis settings that SYNTH_FLAGS asks for, each as {synth_1 run property, its value, synth_design arguments}.
# An empty property marks arguments that only the run's MORE OPTIONS can pass.
#
proc SynthSettings {synth_flags} {
    upvar 1 $synth_flags SYNTH_FLAGS

    puts "VHDL assert enabled!"
    set settings [list [list ASSERT true -assert]]

    foreach {key option property} {
        FANOUT_LIMIT      -control_set_opt_threshold CONTROL_SET_OPT_THRESHOLD
        RESOURCE_SHARING  -resource_sharing          RESOURCE_SHARING
        BUFG              -bufg                      BUFG
        FLATTEN_HIERARCHY -flatten_hierarchy         FLATTEN_HIERARCHY
    } {
        if {[info exist SYNTH_FLAGS($key)]} {
            puts "$key set to: $SYNTH_FLAGS($key)"
            lappend settings [list $property $SYNTH_FLAGS($key) [list $option $SYNTH_FLAGS($key)]]
        }
    }

    if {[info exist SYNTH_FLAGS(NO_LUT_COMBINE)]} {
        puts "LUT combining disabled: $SYNTH_FLAGS(NO_LUT_COMBINE)"
        set no_lc [expr {$SYNTH_FLAGS(NO_LUT_COMBINE) ? "-no_lc" : ""}]
        lappend settings [list NO_LC $SYNTH_FLAGS(NO_LUT_COMBINE) $no_lc]
    }

    if {[info exist SYNTH_FLAGS(RETIMING)]} {
        puts "Retiming enabled: $SYNTH_FLAGS(RETIMING)"
        set retiming [expr {$SYNTH_FLAGS(RETIMING) ? "on" : "off"}]
        lappend settings [list GLOBAL_RETIMING $retiming [list -global_retiming $retiming]]
    }

    if {[info exist SYNTH_FLAGS(SYNTH_DIRECTIVE)]} {
        puts "Synthesis directive set to: $SYNTH_FLAGS(SYNTH_DIRECTIVE)"
        lappend settings [list DIRECTIVE $SYNTH_FLAGS(SYNTH_DIRECTIVE) [ParseDirective $SYNTH_FLAGS(SYNTH_DIRECTIVE)]]
    }

    foreach g $SYNTH_FLAGS(USER_GENERICS) {
        lappend settings [list "" "" [list -generic "[lindex $g 0]=[lindex $g 1]"]]
    }
    if {[llength $SYNTH_FLAGS(USER_GENERICS)]} {
        puts "User-defined generics: $SYNTH_FLAGS(USER_GENERICS)"
    }

    if {[info exist SYNTH_FLAGS(OOC_MODE)] && $SYNTH_FLAGS(OOC_MODE) == "1"} {
        puts "Out-of-context mode set"
        lappend settings [list "" "" [list -mode out_of_context]]
    }
    return $settings
}

# -----------------------------------------------------------------------------
# Procedure SynthMsgConfig
# Raises the synthesis warnings that hide design errors to errors.
#
proc SynthMsgConfig {synth_flags} {
    upvar 1 $synth_flags SYNTH_FLAGS

    # Set assertion severity level
    if {[info exist SYNTH_FLAGS(ASSERT_SEVERITY)]} {
        set_msg_config -id {Synth 8-63} -severity WARNING -new_severity $SYNTH_FLAGS(ASSERT_SEVERITY)
        puts "Assertion severity level set to: $SYNTH_FLAGS(ASSERT_SEVERITY)"
    } else {
        set_msg_config -id {Synth 8-63} -severity WARNING -new_severity ERROR
    }

    # Set severity of 'multi-driven net on pin ...'
    set_msg_config -id {Synth 8-6858} -severity WARNING -new_severity ERROR
    set_msg_config -id {Synth 8-6859} -severity WARNING -new_severity ERROR
    # Set severity of 'sensitivity list mistake'
    set_msg_config -id {Synth 8-614} -severity WARNING -new_severity ERROR
}

# -----------------------------------------------------------------------------
# Procedure ImplSteps
# The implementation steps that take a directive, in their order, each as {SYNTH_FLAGS directive key, impl_1 run step,
# command, checkpoint suffix}. The phys_opt_design steps run only when their directive is set.
#
proc ImplSteps {} {
    return {
        SOPT_DIRECTIVE            OPT_DESIGN                 opt_design      opt
        PLACE_DIRECTIVE           PLACE_DESIGN               place_design    place
        PPLACE_PHYS_OPT_DIRECTIVE PHYS_OPT_DESIGN            phys_opt_design pplace_phys_opt
        ROUTE_DIRECTIVE           ROUTE_DESIGN               route_design    route
        PROUTE_PHYS_OPT_DIRECTIVE POST_ROUTE_PHYS_OPT_DESIGN phys_opt_design proute_phys_opt
    }
}

# -----------------------------------------------------------------------------
# Procedure ReportSynthesis
# Writes the reports of the synthesized design.
#
proc ReportSynthesis {synth_flags} {
    upvar 1 $synth_flags SYNTH_FLAGS

    PrintLabel "Report timing"
    set_delay_model -interconnect estimated
    report_timing_summary -delay_type min_max -report_unconstrained -check_timing_verbose -max_paths 10 -input_pins -name timing_1 -file $SYNTH_FLAGS(OUTPUT)_synth.tim

    PrintLabel "Report Utilization"
    report_utilization -file $SYNTH_FLAGS(OUTPUT)_synth.util

    # Load user DRC
    global OFM_PATH
    source $OFM_PATH/build/scripts/vivado/user_drc/load.tcl

    PrintLabel "Report DRC"
    report_drc -file $SYNTH_FLAGS(OUTPUT)_synth.drc

    # Write VHDL file for netlist simulation
    if {$SYNTH_FLAGS(WRITE_VHDL)} {
        write_vhdl -mode funcsim -force "$SYNTH_FLAGS(OUTPUT).vhd"
    }
}

# -----------------------------------------------------------------------------
# Procedure ReportImplementation
# Writes the reports of the implemented design.
#
proc ReportImplementation {synth_flags} {
    upvar 1 $synth_flags SYNTH_FLAGS

    PrintLabel "Report Timing"
    set_delay_model -interconnect actual
    report_timing_summary -delay_type min_max -report_unconstrained -check_timing_verbose -max_paths 10 -input_pins -name timing_1 -file $SYNTH_FLAGS(OUTPUT)_par.tim

    PrintLabel "Report Utilization"
    report_utilization -file $SYNTH_FLAGS(OUTPUT)_par.util

    if {$SYNTH_FLAGS(POWER_ANALYSIS_EN)} {
        PrintLabel "Report Power"
        report_power -file $SYNTH_FLAGS(OUTPUT)_par.pow
    }

    # Load user DRC
    global OFM_PATH
    source $OFM_PATH/build/scripts/vivado/user_drc/load.tcl

    PrintLabel "Report DRC"
    report_drc -file $SYNTH_FLAGS(OUTPUT)_par.drc
}

# -----------------------------------------------------------------------------
# Procedure SynthesizeDesign
# Sets synthesis properties, runs synthesis and reports timing/utilization
# after synthesis.
#
proc SynthetizeDesign {synth_flags} {
    # Define auxiliary variables
    upvar 1 $synth_flags SYNTH_FLAGS

    SynthesizeDesignSetup SYNTH_FLAGS
    # Skip actual implementation if one of the variables is set to 1/true
    if {$SYNTH_FLAGS(PROJ_ONLY)} {return}
    SynthesizeDesignRun SYNTH_FLAGS
}

proc nb_nfw_archive_create {synth_flags} {
    global env
    upvar 1 $synth_flags SYNTH_FLAGS

    # Create temporary directory
    file mkdir $env(NETCOPE_TEMP)build_save_design

    # List of target files to be copied
    lappend NFW_FILES

    # FIXME: Add output bitstream to .nfw archive
    if {[file exists $SYNTH_FLAGS(OUTPUT).bit]} {
        lappend SYNTH_FLAGS(NFW_FILES) [list $SYNTH_FLAGS(OUTPUT).bit $SYNTH_FLAGS(FPGA).bit]
    } else {
        if { [info exists SYNTH_FLAGS(BITSTREAM)] && $SYNTH_FLAGS(BITSTREAM) == "COMBINE_DBMC"} {
            lappend SYNTH_FLAGS(NFW_FILES) [list combined.pdi $SYNTH_FLAGS(FPGA).pdi]
        } else {
            lappend SYNTH_FLAGS(NFW_FILES) [list $SYNTH_FLAGS(OUTPUT).pdi $SYNTH_FLAGS(FPGA).pdi]
        }
    }

    # Copy each file from SYNTH_FLAGS(NFW_FILES) list to temporary directory
    foreach f $SYNTH_FLAGS(NFW_FILES) {
        file copy [lindex $f 0] $env(NETCOPE_TEMP)build_save_design/[lindex $f 1]
        lappend NFW_FILES [lindex $f 1]
    }

    # Run tar utility
    if {[catch {exec tar -czf $SYNTH_FLAGS(OUTPUT).nfw -C $env(NETCOPE_TEMP)build_save_design {*}$NFW_FILES} msg]} {
        puts stderr "Packaging the firmware file failed:\n$msg"
    }

    # Delete temporary directory
    file delete -force $env(NETCOPE_TEMP)build_save_design
}

# -----------------------------------------------------------------------------
# Procedure CheckTiming
#
proc CheckTiming {synth_flags} {
    upvar 1 $synth_flags SYNTH_FLAGS

    PrintLabel "Timing Check"

    set TREPORT $SYNTH_FLAGS(OUTPUT)_par.tim
    set fp [open $TREPORT]
    # Search the file for the sentence
    while {[gets $fp line] >= 0} {
        if {[regexp "Timing constraints are not met." $line]} {
            puts "Timing constraints were NOT met!"
            seek $fp 0
            # Search the file for TNS and WNS
            while {[gets $fp line] >= 0} {
                if {[regexp "WNS" $line]} {
                    gets $fp line
                    gets $fp line
                    set WNSTNS [regexp -all -inline {\S+} $line]
                    puts -nonewline "WNS = "
                    puts [lindex $WNSTNS 0]
                    puts -nonewline "TNS = "
                    puts [lindex $WNSTNS 1]
                    return -code error
                }
            }
            return -code error
        }
    }
    puts "All constraints were met."
}

# ---------------------------------------------------------------------
# Procedure SynthesizeProject - automaticly performs all previosly defined
# procedures. Alternatively to this function, user can manualy call
# previously defined procedures and use addition commands to customize
# synthesis process
#
proc SynthesizeProject {synth_flags hierarchy} {
    upvar 1 $synth_flags SYNTH_FLAGS
    upvar 1 $hierarchy HIERARCHY

    # synthesis setting
    SetupDesign SYNTH_FLAGS

    # add input files
    AddInputFiles SYNTH_FLAGS HIERARCHY

    # design synthesis
    SynthetizeDesign SYNTH_FLAGS

    # design implementation
    ImplementDesign SYNTH_FLAGS

    if {!$SYNTH_FLAGS(PROJ_ONLY) && !$SYNTH_FLAGS(SYNTH_ONLY)} {
        # Save implemented design
        if {$SYNTH_FLAGS(PHASE_SAVE)} {
            SaveDesign SYNTH_FLAGS
        }

        # Check design timing after implementation
        CheckTiming SYNTH_FLAGS

        # Filter Vivado messages
        PrintLabel "Filter Vivado Messages"
        filter_msg
    }
}

# -----------------------------------------------------------------------------
#                Procedures and functions for message filtering
# -----------------------------------------------------------------------------

# get_all_log_files
# This procedure parses all log files in the current directory and returns a
# unique list of paths to all log files utilized during the run of the Vivado.
# The list starts with names of the log files in the current directory and
# continues with paths to runme.log files utilized in different
# synthesis/implementation runs.
#
proc get_all_log_files {} {
    global env

    # filename of Vivado's main log
    set MAIN_LOGFILES $env(OUTPUT_NAME).log

    # construct a list of paths to all utilized log files
    set LOGFILES $MAIN_LOGFILES
    foreach LOGFILE $MAIN_LOGFILES {

        # open the current log file for reading
        set LOGFILE_HANDLE [open $LOGFILE "r"]

        # read the current log file and extract all references to runme.log files
        while { [gets $LOGFILE_HANDLE LINE] >= 0 } {
            # paths to runme.log files are in the vivado.tcl present on lines
            # starting with "Run output will be captured here: "
            if { [regexp "(^Run output will be captured here: )(.*)" $LINE -> MSG PATH] } {
                lappend LOGFILES $PATH
            }
        }
    }

    # return a list of unique paths
    return [lsort -unique $LOGFILES]
}

# -----------------------------------------------------------------------------
# get_all_msg_lines
# This procedure parses the given file and returns a list of all lines
# containing a message (lines starting with INFO, WARNING, CRITICAL WARNING or
# ERROR), which were extracted from the given file.
#
proc get_all_msg_lines { FILENAME } {

    # open the given file for reading
    set LOGFILE [open $FILENAME "r"]

    # extract all message lines into the MSG_LINES list
    set MSG_LINES [list ]
    while { [gets $LOGFILE LINE] >= 0 } {
        if { [regexp "^INFO" $LINE] } {
            lappend MSG_LINES $LINE
        } elseif { [regexp "^WARNING" $LINE] } {
            lappend MSG_LINES $LINE
        } elseif { [regexp "^CRITICAL WARNING" $LINE] } {
            lappend MSG_LINES $LINE
        } elseif { [regexp "^ERROR" $LINE] } {
            lappend MSG_LINES $LINE
        }
    }

    # return the list
    return $MSG_LINES
}

# -----------------------------------------------------------------------------
# isRealSynth: DEPRECATED
# Returns true if the Synthesis process is executed in this tcl session
#
proc isRealSynth { } {
    global env
    global SYNTH_FLAGS

    if {$SYNTH_FLAGS(PROJ_ONLY)} {
        return false
    }
    return true
}

proc nb_sanitize_vars {synth_flags hierarchy} {
    # Define auxiliary variables
    upvar 1 $synth_flags SYNTH_FLAGS
    upvar 1 $hierarchy HIERARCHY

    # Create empty lists
    lappend HIERARCHY(PACKAGES)
    lappend HIERARCHY(COMPONENTS)
    lappend HIERARCHY(MOD)
    lappend HIERARCHY(TOP_LEVEL)

    lappend SYNTH_FLAGS(SETUP_FLAGS)
    lappend SYNTH_FLAGS(USER_GENERICS)
    lappend SYNTH_FLAGS(CONSTR)
    lappend SYNTH_FLAGS(NFW_FILES)

    set SYNTH_FLAGS(TOOL) "vivado"

    global NB_PLATFORM_TAGS env
    if {[info exists env(PLATFORM_TAGS)]} {
        set NB_PLATFORM_TAGS "$env(PLATFORM_TAGS)"
    } else {
        set NB_PLATFORM_TAGS "xilinx"
    }

    if {[info commands version] != ""} {
        set SYNTH_FLAGS(TOOL_VERSION) [version -short]
    } elseif {[catch {exec vivado -version} VIVADO_VERSION]} {
        regexp {[Vv]ivado v([0-9\.]+) } "$VIVADO_VERSION" void SYNTH_FLAGS(TOOL_VERSION)
    } else {
        set SYNTH_FLAGS(TOOL_VERSION) "Unknown"
    }

    # Set default values
    if {![info exists SYNTH_FLAGS(PROJ_ONLY)]} {
        set SYNTH_FLAGS(PROJ_ONLY) false
    }
    if {![info exists SYNTH_FLAGS(SYNTH_ONLY)]} {
        set SYNTH_FLAGS(SYNTH_ONLY) false
    }
    if {![info exists SYNTH_FLAGS(PHASE_SAVE)]} {
        set SYNTH_FLAGS(PHASE_SAVE) true
    }
    if {![info exist SYNTH_FLAGS(WRITE_VHDL)]} {
        set SYNTH_FLAGS(WRITE_VHDL) false
    }
    if {![info exist SYNTH_FLAGS(UPGRADE_IP)] } {
        set SYNTH_FLAGS(UPGRADE_IP) true
    }
    if {![info exist SYNTH_FLAGS(SOPT_VERBOSE)] } {
        set SYNTH_FLAGS(SOPT_VERBOSE) false
    }
    if {![info exists SYNTH_FLAGS(POWER_ANALYSIS_EN)]} {
        set SYNTH_FLAGS(POWER_ANALYSIS_EN) true
    }
}
