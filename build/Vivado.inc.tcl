# Vivado.inc.tcl: Vivado global include tcl script to compile all design
# Copyright (C) 2013 CESNET
# Author: Viktor Puš <pus@cesnet.cz>
#         Jiri Matousek <xmatou06@stud.fit.vutbr.cz>
#
# SPDX-License-Identifier: BSD-3-Clause

set TIMING_MET 0

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
        add_files -norecurse $FNAME
        if {$opt(LIBRARY) != "work"} {
            set_property LIBRARY $opt(LIBRARY) [get_files $FNAME]
        }
        set vhdlfiles [get_files -quiet -filter {FILE_TYPE == VHDL} $FNAME]
        if {$vhdlfiles ne ""} {set_property FILE_TYPE {VHDL 2008} $vhdlfiles}
        puts "Library $opt(LIBRARY): File added: $FNAME"
    } elseif {$opt(TYPE) == "CONSTR_VIVADO"} {
        puts "Constraints file added: $FNAME"
        add_files -fileset constrs_1 -norecurse $FNAME
    } elseif {$opt(TYPE) == "VIVADO_IP_XACT"} {
        add_files -norecurse $FNAME
        puts "IP added: $FNAME"
    } elseif {$opt(TYPE) == "VIVADO_BD"} {
        add_files -norecurse $FNAME
        puts "BD added: $FNAME"
        generate_target all [get_files $FNAME] -force
        upgrade_ip [get_ips *] -quiet
    } elseif {$opt(TYPE) == "VIVADO_TCL"} {
        EvalTclScript $FNAME $OPT
    }

    SetFileProperties $FNAME $OPT
}

# ---------------------------------------------------------------------
# Procedure filelist_rebase_paths
# Rewrites repository paths in IP parameters, also in nested lists, to a placeholder that the generated script resolves
# with a string map, as the value sits in a brace-quoted dict.
#
proc filelist_rebase_paths {token combo_base git_root_token} {
    if {[llength $token] > 1} {
        set out [list]
        foreach el $token {
            lappend out [filelist_rebase_paths $el $combo_base $git_root_token]
        }
        return $out
    }

    if {[string first "/" $token] < 0} {
        return $token
    }

    set norm [file normalize $token]
    if {!([string match "${combo_base}/*" $norm] || $norm eq $combo_base)} {
        return $token
    }

    set rel [string range $norm [string length $combo_base] end]
    return "${git_root_token}${rel}"
}

# Placeholder for the repository root inside brace-quoted IP parameter dicts, where ${shell_git_root} would not be
# substituted.
set FILELIST_GIT_ROOT_TOKEN "@@SHELL_GIT_ROOT@@"

# ---------------------------------------------------------------------
# Procedure filelist_set
# The commands that set a variable of the generated script to a value, with the repository paths in it relative to
# ${shell_git_root}.
#
proc filelist_set {name value} {
    global COMBO_BASE FILELIST_GIT_ROOT_TOKEN

    set value [filelist_rebase_paths $value [file normalize $COMBO_BASE] $FILELIST_GIT_ROOT_TOKEN]
    set cmds "set $name [list $value]\n"
    # Resolve the placeholder to the real root at source time.
    if {[string first $FILELIST_GIT_ROOT_TOKEN $value] >= 0} {
        append cmds "set $name \[string map \[list $FILELIST_GIT_ROOT_TOKEN \$shell_git_root] \$$name]\n"
    }
    return $cmds
}

# ---------------------------------------------------------------------
# Procedure filelist_proc
# The definition of a proc of this flow as a command, so that the generated script runs the same code as the flow.
#
proc filelist_proc {name} {
    return "proc $name [list [info args $name]] [list [info body $name]]\n"
}

# ---------------------------------------------------------------------
# Procedure filelist_EvalFile
# The counterpart of EvalFile for target_filelist: collects the read_* and source commands of a source file, with its
# path relative to ${shell_git_root}, in filelist_chunks.
#
proc filelist_EvalFile {FNAME OPT} {
    global COMBO_BASE filelist_chunks

    set opt(LIBRARY) "work"
    array set opt $OPT

    # The device tree entries carry no real path.
    if {$opt(TYPE) == "DEVTREE"} {
        return
    }

    set fext [file extension $FNAME]
    set fname "\$\{shell_git_root\}[string range $FNAME [string length [file normalize $COMBO_BASE]] end]"
    set cmds ""

    if {$opt(TYPE) == ""} {
        if {$fext == ".vhd" || $fext == ".vhdl"} {
            append cmds "read_vhdl -library $opt(LIBRARY) -vhdl2008 $fname\n"
        } elseif {$fext == ".v"} {
            append cmds "read_verilog -library $opt(LIBRARY) $fname\n"
        } elseif {$fext == ".sv" || $fext == ".svp"} {
            append cmds "read_verilog -library $opt(LIBRARY) -sv $fname\n"
        }
    } elseif {$opt(TYPE) == "CONSTR_VIVADO" && $fext == ".xdc"} {
        append cmds "read_xdc $fname\n"
    } elseif {$opt(TYPE) == "CONSTR_VIVADO" && $fext == ".tcl"} {
        append cmds "read_xdc -unmanaged $fname\n"
    } elseif {$opt(TYPE) == "VIVADO_IP_XACT"} {
        append cmds "read_ip $fname\n"
        append cmds "generate_target all \[get_files $fname\]\n"
    } elseif {$opt(TYPE) == "VIVADO_BD"} {
        append cmds "read_bd $fname\n"
        append cmds "generate_target all \[get_files $fname\] -force\n"
    } elseif {$opt(TYPE) == "VIVADO_TCL" && [tcl_script_runs $OPT]} {
        # VARS is a flat {name value name value ...} list.
        if {[info exists opt(VARS)]} {
            foreach {var_name var_value} $opt(VARS) {
                append cmds [filelist_set $var_name $var_value]
            }
        }
        set keyed_ip_dir [ip_dir_keyed $OPT]
        if {$keyed_ip_dir ne ""} {
            append cmds [filelist_set filelist_ip_dir $keyed_ip_dir] "ip_dir_prepare \$filelist_ip_dir\n"
        }
        append cmds "source $fname\n"
        if {$keyed_ip_dir ne ""} {
            append cmds "ip_dir_finish \$filelist_ip_dir\n"
        }
    }

    foreach property [file_properties $OPT] {
        append cmds "[list set_property {*}$property] \[get_files [list [file tail $fname]]\]\n"
    }
    lappend filelist_chunks $cmds
}

# ---------------------------------------------------------------------
# Procedure target_filelist
# Writes a stand-alone script (default "filelist.tcl") of read_* and source commands for every design source, with
# paths relative to ${shell_git_root}, which the sourcing shell defines. Invoked through "make filelist".
#
proc target_filelist { {filename "filelist.tcl"} } {
    global SYNTH_FLAGS HIERARCHY filelist_chunks

    # Make sure dynamically generated sources (DevTree.vhd, netcope_const.vhd,
    # combo_user_const.vhd, ...) exist on disk so the file list can reference them.
    DevTree_init
    foreach gen_file $SYNTH_FLAGS(NB_GENERATED_FILES) {
        foreach gen_name [lindex $gen_file 0] {
            target_generate_file [SimplPath $gen_name]
        }
    }

    # EvalFileDevTree_paths only records the device-tree paths and filelist_EvalFile only collects text; neither runs
    # a Vivado command, so this works under bare tclsh (see the ttarget_% rule).
    set filelist_chunks [list]
    AddInputFiles SYNTH_FLAGS HIERARCHY [list EvalFileDevTree_paths filelist_EvalFile] ""

    set content "# This is an automatically generated file.\n"
    append content "# You can regenerate it using \"make filelist\".\n\n"

    append content "if \{!\[info exists shell_git_root]\} {
    error \"The shell_git_root variable is undefined! Initialize it in a calling shell.\"
}\n\n"
    append content [filelist_proc ip_dir_prepare] [filelist_proc ip_dir_finish] "\n"
    # AddInputFiles lists the files in the reverse of the order in which it adds them.
    append content [join [lreverse $filelist_chunks] ""]

    append content "generate_target all \[get_ips\]\n"
    append content "synth_ip \[get_ips\]\n"

    file delete "DevTree_paths.txt"
    nb_file_update $filename $content
}

# ---------------------------------------------------------------------
# Procedure SetupDesign - creates a new project with the name defined in MODULE
# parameter. If the project already exists, it removes the project including
# all its implementations. It sets the type of FPGA chip, for the synthesis is
# performed and finaly it sets the name of the output edif file defined in
# OUTPUT parameter.
#
proc SetupDesign {synth_flags} {
    # HACK for toplevel TCL files which doesn't use nb_main
    global NB_MAIN_CALLED
    if {![info exist NB_MAIN_CALLED]} {
        set NB_MAIN_CALLED 1
        nb_main
    }

    upvar 1 $synth_flags SYNTH_FLAGS

    puts "Using FPGA part: $SYNTH_FLAGS(FPGA)"

    # Create and open a new project with name specified by variable OUTPUT
    create_project -part $SYNTH_FLAGS(FPGA) -force $SYNTH_FLAGS(OUTPUT)

    # Define default target language
    set_param project.enableVHDL2008 1
    set_property target_language VHDL [current_project]
    set_property enable_vhdl_2008 1 [current_project]

    # Manual compile order (automatic is buggy in Vivado)
    set_property source_mgmt_mode DisplayOnly [current_project]

    set_param messaging.defaultLimit 3000

    # setup IP repos for blocks designs
    if { [info exists SYNTH_FLAGS(IP_REPO_PATHS)] } {
        puts "Using IP REPO path: $SYNTH_FLAGS(IP_REPO_PATHS)"
        set_property  ip_repo_paths  $SYNTH_FLAGS(IP_REPO_PATHS) [current_project]
        update_ip_catalog
    }

    # Opt-in OOC IP synthesis cache: create_project -force deletes the project-local one, so NDK_IP_CACHE_DIR names
    # a directory that outlives the project, with a subdirectory per Vivado version.
    if {[info exists ::env(NDK_IP_CACHE_DIR)] && $::env(NDK_IP_CACHE_DIR) ne ""} {
        # An unusable directory disables the cache instead of caching somewhere unintended.
        if {[catch {
            set ip_cache_dir [file normalize [file join $::env(NDK_IP_CACHE_DIR) [version -short]]]
            file mkdir $ip_cache_dir
            set ip_cache_probe [file join $ip_cache_dir .writable]
            close [open $ip_cache_probe w]
            file delete -force $ip_cache_probe
            config_ip_cache -use_cache_location $ip_cache_dir
            set_property IP_CACHE_PERMISSIONS {read write} [current_project]
        } ip_cache_err]} {
            puts "WARNING: IP synthesis cache disabled ($ip_cache_err)"
        } else {
            puts "IP synthesis cache: $ip_cache_dir"
        }
    }

    # Apply user settings
    foreach i $SYNTH_FLAGS(SETUP_FLAGS) {
        if { $i == "USE_XPM_LIBRARIES" } {
            set_property XPM_LIBRARIES {XPM_CDC XPM_MEMORY XPM_FIFO} [current_project]
        } elseif { $i == "COMPILE_ORDER_AUTO" } {
            set_property source_mgmt_mode All [current_project]
        }
        # TODO: Implement when needed
    }
}

proc SynthesizeDesignSetup {synth_flags} {
    # Define auxiliary variables
    upvar 1 $synth_flags SYNTH_FLAGS

    PrintLabel "Synthesis Properties Setting"

    # Define top level module (if defined)
    if { [info exist SYNTH_FLAGS(MODULE)] } {
        set_property top $SYNTH_FLAGS(MODULE) [current_fileset]
    }

    # VHDL standard settings (VHDL-2008 support, backward compatibility)
    if { [info exist SYNTH_FLAGS(VHDL2008)] } {
        puts "VHDL-2008 standard support set to: $SYNTH_FLAGS(VHDL2008)"
        if { !$SYNTH_FLAGS(VHDL2008) } {
            set_property FILE_TYPE {VHDL} [get_files -quiet -filter {FILE_TYPE == {VHDL 2008}}]
        }
    }

    set more_options [list]
    foreach setting [SynthSettings SYNTH_FLAGS] {
        lassign $setting property value arguments
        if {$property eq ""} {
            lappend more_options {*}$arguments
        } else {
            set_property -name STEPS.SYNTH_DESIGN.ARGS.$property -value $value -objects [get_runs synth_1]
        }
    }
    if {[llength $more_options]} {
        set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} -value [join $more_options] -objects [get_runs synth_1]
    }

    SynthMsgConfig SYNTH_FLAGS

    if {$SYNTH_FLAGS(UPGRADE_IP)} {
        PrintLabel "Upgrading IP cores"
        foreach ip [get_ips] {
            upgrade_ip $ip
        }
    }
}

proc SynthesizeDesignRun {synth_flags} {
    # Define auxiliary variables
    upvar 1 $synth_flags SYNTH_FLAGS

    PrintLabel "Synthesize"
    launch_runs synth_1
    wait_on_run synth_1
    open_run synth_1

    ReportSynthesis SYNTH_FLAGS

    # Export to file
    if {[info exist SYNTH_FLAGS(WRITE_EDIF)] } {
        write_edif -force $SYNTH_FLAGS(OUTPUT)
    }
}

# -----------------------------------------------------------------------------
# Procedure ImplementDesign
# Sets implementation properties, runs implementation and reports
# timing/utilization after implementation.
#
proc ImplementDesign {synth_flags} {
    # Define auxiliary variables
    upvar 1 $synth_flags SYNTH_FLAGS
    global TIMING_MET

    ImplementDesignSetup SYNTH_FLAGS
    # Skip actual implementation if one of the variables is set to 1/true
    if {$SYNTH_FLAGS(PROJ_ONLY) || $SYNTH_FLAGS(SYNTH_ONLY)} {return}
    ImplementDesignRun SYNTH_FLAGS "impl_1"

    # Create Intelligent Design Run when the timing not met
    if {[info exist SYNTH_FLAGS(IDR)] && !$TIMING_MET} {

        set VIVADO_VER [version -short]
        set YEAR [string range $VIVADO_VER 0 3]
        set IDR_SUPPORTED [expr {$YEAR > 2020}]

        if {$IDR_SUPPORTED} {
            create_run -flow {Vivado IDR Flow 2022} -parent_run synth_1 idr_1
            set_property REFERENCE_RUN impl_1 [get_runs idr_1]
            ImplementDesignRun SYNTH_FLAGS idr_1
        }
    }

}

proc ImplementDesignSetup {synth_flags} {
    # Define auxiliary variables
    upvar 1 $synth_flags SYNTH_FLAGS

    PrintLabel "Implementation Properties Setting"
    # Run script wbs_pre.tcl before writing the bitstream
    global OFM_PATH
    set_property [list_property [get_runs impl_1] STEPS.WRITE_*.TCL.PRE] [file normalize $OFM_PATH/build/misc/vivado_wbs_pre.tcl] [get_runs impl_1]

    set run [get_runs impl_1]
    foreach {key step command suffix} [ImplSteps] {
        if {![info exist SYNTH_FLAGS($key)]} {
            continue
        }
        puts "$key set to: $SYNTH_FLAGS($key)"
        # place_design and route_design always run, so only the other steps have IS_ENABLED (See Xilinx UG904)
        if {$step ni {PLACE_DESIGN ROUTE_DESIGN}} {
            set_property -name STEPS.$step.ARGS.IS_ENABLED -value true -objects $run
        }
        set_property -name STEPS.$step.ARGS.DIRECTIVE -value $SYNTH_FLAGS($key) -objects $run
        if {$step eq "OPT_DESIGN"} {
            set_property -name STEPS.OPT_DESIGN.ARGS.VERBOSE -value $SYNTH_FLAGS(SOPT_VERBOSE) -objects $run
        } else {
            set_property -name "STEPS.$step.ARGS.MORE OPTIONS" -value {-verbose} -objects $run
        }
    }

    # backward compatibility (run power_opt_design by default)
    if {![info exist SYNTH_FLAGS(POWER_OPT_DESIGN)] } {
        set SYNTH_FLAGS(POWER_OPT_DESIGN) true
    }

    # power_opt_design
    puts "Run Power Opt Design: $SYNTH_FLAGS(POWER_OPT_DESIGN)"
    set_property -name {STEPS.POWER_OPT_DESIGN.ARGS.IS_ENABLED} \
        -value $SYNTH_FLAGS(POWER_OPT_DESIGN) -objects $run
    set_property -name {STEPS.POWER_OPT_DESIGN.ARGS.MORE OPTIONS} \
        -value {-verbose} -objects $run

    # Incremental synthesis
    if {[info exist SYNTH_FLAGS(DCP)] } {
        puts "Incremental compile checkpoint: $SYNTH_FLAGS(DCP)"
        set_property incremental_checkpoint $SYNTH_FLAGS(DCP) [get_runs impl_1]
    }
}

proc ImplementDesignRun {synth_flags RUN_NAME} {
    # Define auxiliary variables
    upvar 1 $synth_flags SYNTH_FLAGS
    global TIMING_MET

    PrintLabel "Implement"

    launch_runs $RUN_NAME
    wait_on_run $RUN_NAME
    open_run $RUN_NAME

    set TIMING_MET [expr {[get_property SLACK [get_timing_paths]] >= 0}]
    # set TIMING_MET [expr {[get_property STATS.WNS [get_runs $RUN_NAME]] < 0}]

    ReportImplementation SYNTH_FLAGS

    if {[info exist SYNTH_FLAGS(DCP)] } {
        PrintLabel "Report Incremental Reuse"
        report_incremental_reuse -file $SYNTH_FLAGS(OUTPUT)_par.reuse
    }

    # Write checkpoint for future reuse
    write_checkpoint -force $SYNTH_FLAGS(OUTPUT).dcp
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
    if {[list_property [get_runs impl_1] STEPS.WRITE_*.TCL.PRE] eq "STEPS.WRITE_DEVICE_IMAGE.TCL.PRE"} {
        write_device_image -force $ROOTNAME.pdi
        if {$SYNTH_FLAGS(BITSTREAM) == "COMBINE_DBMC"} {
            write_hw_platform -fixed -force -file ./FPGA.xsa
        }
    } else {
        write_bitstream -force $ROOTNAME.bit
    }

    close_project

    # Create combined pdi file with design & DBMC
    if { [info exists SYNTH_FLAGS(BITSTREAM)] && $SYNTH_FLAGS(BITSTREAM) == "COMBINE_DBMC"} {
        nb_run_combine_dbmc SYNTH_FLAGS
    }

    # INFO: Create archive AFTER close_project - random issues with insufficient memory
    nb_nfw_archive_create SYNTH_FLAGS
}

proc nb_run_combine_dbmc {synth_flags} {
    global env
    upvar 1 $synth_flags SYNTH_FLAGS

    file copy -force $SYNTH_FLAGS(OUTPUT).pdi fpga.pdi
    exec cp -f $SYNTH_FLAGS(COMBINE_DBMC_SCRIPT_DIR)/combine_pdi.bif ./
    exec cp -rf $SYNTH_FLAGS(DBMC_DIR) ./
    puts "Run build DBMC ..."
    if {[catch {exec ./dbmc/build.sh --debug --xsa ./FPGA.xsa --make} msg]} {
        puts stderr "Building DBMC failed:\n$msg"
    }
    exec ./dbmc/build.sh --install
    puts "Run create combined PDI for firmware & DBMC..."
    if {[catch {exec bootgen -arch versal -image ./combine_pdi.bif -w -o ./combined.pdi} msg]} {
        puts stderr "Combining the firmware & DBMC failed:\n$msg"
    }
}

nb_sanitize_vars SYNTH_FLAGS HIERARCHY
