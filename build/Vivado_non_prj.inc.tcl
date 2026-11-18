# Vivado_non_prj.inc.tcl: Vivado global include tcl script to compile all design in non-project mode
# Copyright (C) 2013 CESNET
# Author: Viktor Puš <pus@cesnet.cz>
#         Jiri Matousek <xmatou06@stud.fit.vutbr.cz>
#
# SPDX-License-Identifier: BSD-3-Clause

source [file join [file dirname [info script]] Vivado_common.inc.tcl]

# ---------------------------------------------------------------------
#                     Procedures and functions
# ---------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Procedure EvalFile
# Add file to the project
#
proc EvalFile {FNAME OPT} {
    set opt(LIBRARY) "work"
    array set opt $OPT

    set FEXT [file extension $FNAME]

    if {$opt(TYPE) == ""} {
        if { $FEXT == ".vhd" } {
            # VHDL file
            read_vhdl -library $opt(LIBRARY) -vhdl2008 $FNAME
            puts "INFO: Library $opt(LIBRARY): File added: $FNAME"
        } elseif { $FEXT == ".v" } {
            # Verilog file
            read_verilog -library $opt(LIBRARY) $FNAME
            puts "INFO: Library $opt(LIBRARY): File added: $FNAME"
        } elseif { $FEXT == ".sv" || $FEXT == ".svp" } {
            # System Verilog file
            read_verilog -library $opt(LIBRARY) -sv $FNAME
            puts "INFO: Library $opt(LIBRARY): File added: $FNAME"
        } elseif { $FEXT == ".edif" } {
            # EDIF file
            read_edif $FNAME
            puts "INFO: EDIF file added: $FNAME"
        } elseif { $FEXT == ".dcp" } {
            # DCP file
            read_checkpoint $FNAME
            puts "INFO: DCP file added: $FNAME"
        } else {
            # Not yet supported file type
            puts "WARNING: Adding $FEXT files to the project is not yet supported."
            puts "WARNING: File was not added: $FNAME!"
        }
    } elseif {$opt(TYPE) == "CONSTR_VIVADO"} {
        puts "Constraints file added: $FNAME"
        read_xdc $FNAME
    } elseif {$opt(TYPE) == "VIVADO_IP_XACT"} {
        read_ip $FNAME
        puts "IP added: $FNAME"
        generate_target all [get_files $FNAME]
    } elseif {$opt(TYPE) == "VIVADO_BD"} {
        read_bd $FNAME
        puts "BD added: $FNAME"
        generate_target all [get_files $FNAME] -force
    } elseif {$opt(TYPE) == "VIVADO_TCL"} {
        EvalTclScript $FNAME $OPT
    }

    SetFileProperties $FNAME $OPT
}

# ---------------------------------------------------------------------
# Procedure SetupDesign
# Selects the FPGA part of the in-memory design.
#
proc SetupDesign {synth_flags} {
    # HACK for toplevel TCL files which doesn't use nb_main
    global NB_MAIN_CALLED
    if {![info exist NB_MAIN_CALLED]} {
        set NB_MAIN_CALLED 1
        nb_main
    }

    upvar 1 $synth_flags SYNTH_FLAGS

    set_param messaging.defaultLimit 3000

    puts "Using FPGA part: $SYNTH_FLAGS(FPGA)"
    set_part $SYNTH_FLAGS(FPGA)
}

proc SynthesizeDesignSetup {synth_flags} {
    # Define auxiliary variables
    upvar 1 $synth_flags SYNTH_FLAGS

    PrintLabel "Synthesis Properties Setting"

    set MOREOPT [list]
    foreach setting [SynthSettings SYNTH_FLAGS] {
        lappend MOREOPT {*}[lindex $setting 2]
    }
    set SYNTH_FLAGS(MOREOPT) $MOREOPT
    puts "Parsed synthesis options: $MOREOPT"

    SynthMsgConfig SYNTH_FLAGS

    if {$SYNTH_FLAGS(UPGRADE_IP)} {
        PrintLabel "Upgrading IP cores"
        foreach ip [get_ips] {
            puts "Upgrading and synthesizing IP: $ip"
            upgrade_ip $ip
            synth_ip $ip
        }
    }
}

proc SynthesizeDesignRun {synth_flags} {
    # Define auxiliary variables
    upvar 1 $synth_flags SYNTH_FLAGS

    PrintLabel "Synthesize"
    synth_design -top $SYNTH_FLAGS(MODULE) {*}$SYNTH_FLAGS(MOREOPT)

    # Export to file
    if {$SYNTH_FLAGS(WRITE_SYNTH_DCP)} {
        write_checkpoint -force "$SYNTH_FLAGS(OUTPUT)_synth"
    }

    ReportSynthesis SYNTH_FLAGS
}

# -----------------------------------------------------------------------------
# Procedure ImplementDesign
# Sets implementation properties, runs implementation and reports
# timing/utilization after implementation.
#
proc ImplementDesign {synth_flags} {
    # Define auxiliary variables
    upvar 1 $synth_flags SYNTH_FLAGS

    # Skip actual implementation if one of the variables is set to 1/true
    if {$SYNTH_FLAGS(PROJ_ONLY) || $SYNTH_FLAGS(SYNTH_ONLY)} {return}
    ImplementDesignRun SYNTH_FLAGS
}

proc ImplementDesignRun {synth_flags} {
    # Define auxiliary variables
    upvar 1 $synth_flags SYNTH_FLAGS

    PrintLabel "Implementation"

    # power_opt_design follows opt_design and place_design when enabled
    set power_opt_prefix [dict create OPT_DESIGN "" PLACE_DESIGN PPLACE_]

    foreach {key step command suffix} [ImplSteps] {
        if {![info exist SYNTH_FLAGS($key)]} {
            continue
        }
        PrintLabel $step
        puts "$key set to: $SYNTH_FLAGS($key)"
        $command -verbose {*}[ParseDirective $SYNTH_FLAGS($key)]

        if {$SYNTH_FLAGS([string map {_DIRECTIVE _DCP} WRITE_$key])} {
            write_checkpoint -force "$SYNTH_FLAGS(OUTPUT)_$suffix"
        }

        if {[dict exists $power_opt_prefix $step]} {
            set prefix [dict get $power_opt_prefix $step]
            if {$SYNTH_FLAGS(${prefix}POWER_OPT_EN)} {
                PrintLabel "${prefix}POWER_OPT_DESIGN"
                power_opt_design -verbose

                if {$SYNTH_FLAGS(WRITE_${prefix}POWER_OPT_DCP)} {
                    write_checkpoint -force "$SYNTH_FLAGS(OUTPUT)_[string tolower $prefix]power_opt"
                }
            }
        }
    }

    ReportImplementation SYNTH_FLAGS
}

# ---------------------------------------------------------------------
# Procedure SaveDesign - saves current project implementation. It copies the
# output edif file to root project directory, where the Makefile expects this
# output edif file. OUTPUT parameter specifies the name of output edif file.
# Finally it closes the project.
#
proc SaveDesign {synth_flags} {
    # Define auxiliary variables
    upvar 1 $synth_flags SYNTH_FLAGS

    # Manually run the pre-write bitstream script
    PrintLabel "Run pre-write bitstream script"
    global OFM_PATH
    source $OFM_PATH/build/misc/vivado_wbs_pre.tcl

    PrintLabel "Write bitstream"
    set ROOTNAME [pwd]/$SYNTH_FLAGS(OUTPUT)
    write_bitstream -force $ROOTNAME.bit

    close_project

    # INFO: Create archive AFTER close_project - random issues with insufficient memory
    nb_nfw_archive_create SYNTH_FLAGS
}

# ---------------------------------------------------------------------
# Procedure nb_sanitize_non_prj_vars
# Defaults of the settings that only the non-project flow reads; project mode tells an unset directive from an empty one.
#
proc nb_sanitize_non_prj_vars {synth_flags} {
    upvar 1 $synth_flags SYNTH_FLAGS

    lappend SYNTH_FLAGS(MOREOPT)

    # Synthesis settings
    if {![info exist SYNTH_FLAGS(WRITE_SYNTH_DCP)]} {
        set SYNTH_FLAGS(WRITE_SYNTH_DCP) false
    }

    # Implementation settings
    # Optimization
    if {![info exist SYNTH_FLAGS(SOPT_DIRECTIVE)]} {
        set SYNTH_FLAGS(SOPT_DIRECTIVE) ""
    }
    if {![info exist SYNTH_FLAGS(WRITE_SOPT_DCP)]} {
        set SYNTH_FLAGS(WRITE_SOPT_DCP) false
    }

    # Power optimization
    if {![info exist SYNTH_FLAGS(POWER_OPT_EN)]} {
        set SYNTH_FLAGS(POWER_OPT_EN) false
    }
    if {![info exist SYNTH_FLAGS(WRITE_POWER_OPT_DCP)]} {
        set SYNTH_FLAGS(WRITE_POWER_OPT_DCP) false
    }

    # Placement
    if {![info exist SYNTH_FLAGS(PLACE_DIRECTIVE)]} {
        set SYNTH_FLAGS(PLACE_DIRECTIVE) ""
    }
    if {![info exist SYNTH_FLAGS(WRITE_PLACE_DCP)]} {
        set SYNTH_FLAGS(WRITE_PLACE_DCP) false
    }

    # Post-placement power optimization
    if {![info exist SYNTH_FLAGS(PPLACE_POWER_OPT_EN)]} {
        set SYNTH_FLAGS(PPLACE_POWER_OPT_EN) false
    }
    if {![info exist SYNTH_FLAGS(WRITE_PPLACE_POWER_OPT_DCP)]} {
        set SYNTH_FLAGS(WRITE_PPLACE_POWER_OPT_DCP) false
    }

    # Post-placement physical optimization
    if {![info exist SYNTH_FLAGS(WRITE_PPLACE_PHYS_OPT_DCP)]} {
        set SYNTH_FLAGS(WRITE_PPLACE_PHYS_OPT_DCP) false
    }

    # Route design
    if {![info exist SYNTH_FLAGS(ROUTE_DIRECTIVE)]} {
        set SYNTH_FLAGS(ROUTE_DIRECTIVE) ""
    }
    if {![info exist SYNTH_FLAGS(WRITE_ROUTE_DCP)]} {
        set SYNTH_FLAGS(WRITE_ROUTE_DCP) false
    }

    # Post-route physical optimization
    if {![info exist SYNTH_FLAGS(WRITE_PROUTE_PHYS_OPT_DCP)]} {
        set SYNTH_FLAGS(WRITE_PROUTE_PHYS_OPT_DCP) false
    }
}

nb_sanitize_vars SYNTH_FLAGS HIERARCHY
nb_sanitize_non_prj_vars SYNTH_FLAGS
