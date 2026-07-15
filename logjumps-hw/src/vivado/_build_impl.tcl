# --------------------------------------------------------------
# _build_impl.tcl, Generic OOC synth + impl flow
# Target: user-specified FPGA part (default: Alveo U55C)
#
# Invoked via build.tcl (which sources this with -notrace).
#
# Reserved parameters (consumed by this script):
#   F_FILE    , path to .f source list          (REQUIRED)
#   TOP       , top-level module name            (default: from .f name)
#   PART      , FPGA part                        (default: xcu55c-fsvh2892-2L-e)
#   FREQ      , target frequency in MHz          (default: 455)
#   CLK       , clock port name                  (default: clk)
#   ELAB      , RTL elaboration pass (0/1)       (default: 1)
#   ELAB_DEPTH, hierarchy depth to display       (default: -1 = all)
#                0 = top only, 1 = +direct children, etc.
#   EFFORT    , implementation effort level       (default: 0)
#                0 = normal, 1 = high, 2 = aggressive, 3 = ultra
#
# All other KEY=VALUE pairs are forwarded to synth_design -generic.
# --------------------------------------------------------------

set proj_dir [file dirname [info script]]

# -- Helpers --------------------------------------------------
proc hr {} { puts [string repeat "-" 60] }

proc puts_kv {key val {indent 2}} {
    set pad [expr {18 - [string length $key]}]
    if {$pad < 1} { set pad 1 }
    puts "[string repeat { } $indent]${key}[string repeat { } $pad]${val}"
}

proc verilog_to_int {val} {
    if {[regexp {^\d+'b([01]+)$} $val -> bits]} {
        return [expr 0b$bits]
    } elseif {[regexp {^\d+'h([0-9a-fA-F]+)$} $val -> hex]} {
        return [expr 0x$hex]
    } elseif {[regexp {^\d+'d(\d+)$} $val -> dec]} {
        return $dec
    }
    return $val
}

# Format a KEY=VALUE generic for a SystemVerilog instantiation.
# Integer values  -> .KEY(val)
# Hex strings     -> .KEY(width'hval)
proc generic_to_sv_param {kv} {
    if {![regexp {^(\w+)=(.+)$} $kv -> k v]} { return "" }
    if {[regexp {[a-fA-F]} $v]} {
        # Contains hex chars -> treat as hex literal
        set width [expr {[string length $v] * 4}]
        return ".${k}(${width}'h${v})"
    }
    return ".${k}(${v})"
}

# Extract user-defined parameters from a Vivado cell object.
# Filters out known Vivado metadata properties.
proc extract_user_params {obj} {
    set _skip {
        CLASS NAME PARENT REF_NAME ORIG_REF_NAME
        FILE_NAME FILE_NAMES LINE_NUMBER
        HIERARCHICALNAME
        ID TYPE STATUS
        IS_BLACKBOX IS_HIERARCHICAL IS_PRIMITIVE IS_SEQUENTIAL
        IS_LOC_FIXED IS_BEL_FIXED IS_CONNECTED
        IS_BOUNDARY_INST IS_DEBUGGABLE IS_ENCRYPTED
        IS_MATCHED IS_ORIG_CELL IS_REUSED
        PRIMITIVE_COUNT PRIMITIVE_GROUP PRIMITIVE_LEVEL
        PRIMITIVE_SUBGROUP PRIMITIVE_TYPE
        LIB_CELL CELL_COUNT
        XLNX_LINE_COL
    }
    set result [list]
    foreach p [list_property -quiet $obj] {
        if {$p in $_skip} { continue }
        if {[regexp {^[a-z]} $p] || [string match "*.*" $p]} { continue }
        if {[catch {set val [get_property $p $obj]}]} { continue }
        if {$val eq ""} { continue }
        set val [verilog_to_int $val]
        lappend result [list $p $val]
    }
    return $result
}

# -- Defaults -------------------------------------------------
set F_FILE     ""
set TOP        ""
set PART       "xcu55c-fsvh2892-2L-e"
set FREQ       455
set CLK        "clk"
set ELAB       1
set ELAB_DEPTH -1
set EFFORT     0
set PRE_HOOK   ""

# -- Parse arguments ------------------------------------------
set generic_args [list]

foreach arg $::argv {
    if {![regexp {^(\w+)=(.+)$} $arg -> key val]} {
        puts "WARNING: Ignoring unrecognised argument: $arg"
        continue
    }
    switch -exact -- $key {
        F_FILE     { set F_FILE     $val }
        TOP        { set TOP        $val }
        PART       { set PART       $val }
        FREQ       { set FREQ       $val }
        CLK        { set CLK        $val }
        ELAB       { set ELAB       $val }
        ELAB_DEPTH { set ELAB_DEPTH $val }
        EFFORT     { set EFFORT     $val }
        PRE_HOOK   { set PRE_HOOK   $val }
        default    { lappend generic_args $key=$val }
    }
}

# -- Validate F_FILE ------------------------------------------
if {$F_FILE eq ""} {
    puts "ERROR: F_FILE is required.  Pass F_FILE=<path> as first tclarg."
    exit 1
}
if {![file exists $F_FILE]} {
    puts "ERROR: Source list not found: $F_FILE"
    exit 1
}

# -- Derive TOP from .f filename if not given -----------------
if {$TOP eq ""} {
    set stem [file rootname [file tail $F_FILE]]
    regsub {^impl_} $stem {} TOP
    if {$TOP eq ""} {
        puts "ERROR: Could not derive TOP from filename '$F_FILE'.  Pass TOP=<name> explicitly."
        exit 1
    }
}

# -- Pre-hook ------------------------------------------------
# A hook is a Tcl script sourced before the build begins.
# It sees (and may modify) generic_args, TOP, FREQ, etc.
# Use hook_pop inside the hook to consume hook-only parameters
# so they are not forwarded to synth_design -generic.
proc hook_pop {key {default ""}} {
    upvar generic_args ga
    set idx 0
    foreach g $ga {
        if {[regexp "^${key}=(.+)\$" $g -> val]} {
            set ga [lreplace $ga $idx $idx]
            return $val
        }
        incr idx
    }
    return $default
}

if {$PRE_HOOK ne ""} {
    set _hook $PRE_HOOK
    if {[file pathtype $_hook] ne "absolute"} {
        set _hook [file normalize [file join [file dirname $F_FILE] $_hook]]
    }
    if {![file exists $_hook]} {
        puts "ERROR: PRE_HOOK not found: $_hook"
        exit 1
    }
    puts "Running pre-hook: $_hook"
    source $_hook
    puts ""
}

# -- Derived values -------------------------------------------
set period_ns   [expr {1000.0 / $FREQ}]
set half_period [expr {$period_ns / 2.0}]

set config_tag "${TOP}_${FREQ}mhz"
if {[llength $generic_args] > 0} {
    set params_tag [join $generic_args "_"]
    regsub -all {=} $params_tag {-} params_tag

    # Filesystem path components are limited to 255 bytes.
    # When expanded generics (e.g. large hex constants) would exceed
    # that, replace the params portion with an 8-char MD5 fingerprint.
    set max_tag_len [expr {255 - 1}]   ;# leave room for safety
    set full_tag "${config_tag}_${params_tag}"

    if {[string length $full_tag] > $max_tag_len} {
        package require md5
        set hash [string range [md5::md5 -hex $params_tag] 0 7]
        append config_tag "_${hash}"
    } else {
        append config_tag "_${params_tag}"
    }
}
set build_dir ${proj_dir}/build/${config_tag}
file mkdir ${build_dir}

# Write a manifest so the hash can always be traced back to exact params.
set _manifest ${build_dir}/params.manifest
set _mfh [open $_manifest w]
puts $_mfh "# Build parameters for: $config_tag"
puts $_mfh "# Generated: [clock format [clock seconds]]"
puts $_mfh ""
puts $_mfh "TOP   = $TOP"
puts $_mfh "FREQ  = $FREQ"
puts $_mfh "PART  = $PART"
foreach g $generic_args {
    puts $_mfh $g
}
close $_mfh

# -- Banner ---------------------------------------------------
puts ""
hr
puts "  Vivado OOC Build"
hr
puts_kv "Top module"  $TOP
puts_kv "Part"        $PART
puts_kv "Frequency"   "${FREQ} MHz  (period = ${period_ns} ns)"
puts_kv "Clock port"  $CLK
puts_kv "Source list"  $F_FILE
if {[llength $generic_args] > 0} {
    puts_kv "Generics" [join $generic_args " "]
}
puts_kv "Build dir"   $build_dir
puts_kv "Elaboration" [expr {$ELAB ? "on" : "off (ELAB=0)"}]
set _effort_labels {0 "normal" 1 "high" 2 "aggressive" 3 "ultra"}
puts_kv "Effort"      "[dict get $_effort_labels $EFFORT] (EFFORT=$EFFORT)"
if {$ELAB} {
    if {$ELAB_DEPTH < 0} {
        puts_kv "  Depth" "all"
    } elseif {$ELAB_DEPTH == 0} {
        puts_kv "  Depth" "top module only"
    } else {
        puts_kv "  Depth" "$ELAB_DEPTH level(s) below top"
    }
}
hr
puts ""

# -- Read sources from .f file --------------------------------
set f_dir [file dirname $F_FILE]
set fh [open $F_FILE r]
set src_count 0

puts "Reading sources:"

while {[gets $fh line] >= 0} {
    set line [string trim $line]
    if {$line eq "" || [string index $line 0] eq "#"} { continue }

    # +incdir+ directives
    if {[regexp {^\+incdir\+(.+)$} $line -> incpath]} {
        set abs_inc [file normalize [file join $f_dir $incpath]]
        if {![file isdirectory $abs_inc]} {
            puts "  WARNING: include dir not found: $abs_inc (skipping)"
            continue
        }
        puts "  +incdir+ $abs_inc"
        set_property verilog_include_dirs $abs_inc [current_fileset -quiet] 2>/dev/null
        continue
    }

    set read_opts [list]
    set filepath  $line

    # Lines with leading flags: "-library work path/to/file.sv"
    if {[string index $line 0] eq "-"} {
        set parts [regexp -all -inline {\S+} $line]
        set filepath [lindex $parts end]
        set read_opts [lrange $parts 0 end-1]
    }

    # Resolve relative paths against .f file directory
    if {[string index $filepath 0] ne "/"} {
        set filepath [file normalize [file join $f_dir $filepath]]
    }

    if {![file exists $filepath]} {
        puts "  ERROR: source file not found: $filepath"
        puts "         (listed in $F_FILE)"
        close $fh
        exit 1
    }

    set ext [string tolower [file extension $filepath]]
    switch -glob -- $ext {
        .sv - .svh {
            puts "  \[SV\]   $filepath"
            eval read_verilog -sv $read_opts [list $filepath]
        }
        .v - .vh {
            puts "  \[V\]    $filepath"
            eval read_verilog $read_opts [list $filepath]
        }
        .vhd - .vhdl {
            puts "  \[VHDL\] $filepath"
            eval read_vhdl $read_opts [list $filepath]
        }
        .xdc {
            puts "  \[XDC\]  $filepath"
            read_xdc $filepath
        }
        .xci {
            puts "  \[IP\]   $filepath"
            read_ip $filepath
        }
        .edf - .edif {
            puts "  \[EDIF\] $filepath"
            read_edif $filepath
        }
        default {
            puts "  WARNING: unknown extension '$ext', treating as Verilog: $filepath"
            eval read_verilog $read_opts [list $filepath]
        }
    }
    incr src_count
}
close $fh

if {$src_count == 0} {
    puts "ERROR: No source files were read from $F_FILE."
    exit 1
}
puts ""
puts "  Loaded $src_count source file(s)."
puts ""

# ==============================================================
# Optional hook-generated top wrapper
# ==============================================================
# A PRE_HOOK may synthesize a thin top wrapper on the fly (e.g. to
# shrink out-of-context I/O for fixed-modulus designs) by setting
# TOP_WRAPPER_SRC to its SystemVerilog source and TOP to the wrapper's
# module name.  We write it into build_dir (so it is captured as a
# build artifact) and read it after the .f sources so it can reference
# modules defined there.
if {[info exists TOP_WRAPPER_SRC] && $TOP_WRAPPER_SRC ne ""} {
    set _twf ${build_dir}/gen_top_wrapper.sv
    set _twh [open $_twf w]
    puts $_twh $TOP_WRAPPER_SRC
    close $_twh
    read_verilog -sv $_twf
    puts "  Generated top wrapper: $_twf  (top = $TOP)"
    puts ""
}

# ==============================================================
# RTL Elaboration & Parameter Introspection
# ==============================================================
# When TOP is the design root, Vivado does not expose its
# parameters/localparams as cell properties (it's not a cell).
# To work around this, we auto-generate a thin wrapper that
# instantiates TOP, making it cell "u_top" whose properties
# we can read.  The wrapper is used ONLY for introspection
# and is discarded before real synthesis.
# --------------------------------------------------------------
if {$ELAB} {
    puts ""
    hr
    puts "  RTL Elaboration, parameter introspection"
    hr
    puts ""

    # -- Generate elaboration wrapper -------------------------
    set wrapper_file ${build_dir}/__elab_wrapper.sv
    set wfd [open $wrapper_file w]
    puts $wfd "// Auto-generated for parameter introspection, not used in synthesis"
    puts $wfd "module __elab_wrapper;"

    # Build parameter override list for the instantiation
    set param_lines [list]
    foreach g $generic_args {
        set sv [generic_to_sv_param $g]
        if {$sv ne ""} { lappend param_lines "        $sv" }
    }

    if {[llength $param_lines] > 0} {
        puts $wfd "    $TOP #("
        puts $wfd [join $param_lines ",\n"]
        puts $wfd "    ) u_top ();"
    } else {
        puts $wfd "    $TOP u_top ();"
    }

    puts $wfd "endmodule"
    close $wfd

    read_verilog -sv $wrapper_file
    puts "  Generated introspection wrapper: $wrapper_file"
    puts ""

    # -- Elaborate the wrapper --------------------------------
    # No -generic needed: parameters are hardcoded in the wrapper.
    synth_design -rtl -top __elab_wrapper -part $PART

    # -- Collect parameters from u_top and its sub-hierarchy --
    set elab_report {}

    # TOP module -> cell "u_top"
    set top_cell [get_cells -quiet u_top]
    if {[llength $top_cell] > 0} {
        set top_ref [get_property -quiet REF_NAME $top_cell]
        set top_params [extract_user_params $top_cell]
        if {[llength $top_params] > 0} {
            # depth 0 = top module
            lappend elab_report [list $TOP $top_ref $top_params 0]
        }
    }

    # Sub-instances under u_top
    # Note: get_cells -hier u_top/* won't cross / boundaries,
    # so we get ALL cells and filter in Tcl.
    set all_cells [get_cells -hier -quiet]
    foreach cell $all_cells {
        # Only cells under u_top/
        if {![string match "u_top/*" $cell]} { continue }
        set ref [get_property -quiet REF_NAME $cell]
        # Skip RTL primitives
        if {[string match "RTL_*" $ref]} { continue }

        set user_params [extract_user_params $cell]
        if {[llength $user_params] > 0} {
            # Strip "u_top/" prefix for display; depth = slash count in remainder
            set display_name [regsub {^u_top/} $cell {}]
            set depth [llength [split $display_name /]]
            lappend elab_report [list $display_name $ref $user_params $depth]
        }
    }

    # -- Print the parameter tree -----------------------------
    if {[llength $elab_report] > 0} {
        puts ""
        puts "  Elaborated hierarchy, parameters & localparams"
        puts "  (values computed by the RTL before synthesis)"
        puts ""

        set printed 0
        set skipped 0
        foreach entry $elab_report {
            lassign $entry display_name ref params depth

            # ELAB_DEPTH filtering
            if {$ELAB_DEPTH >= 0 && $depth > $ELAB_DEPTH} {
                incr skipped
                continue
            }

            set indent [string repeat "  " [expr {$depth + 1}]]
            puts "${indent}${display_name}  (${ref})"

            # Aligned key=value display
            set maxlen 0
            foreach pv $params {
                set klen [string length [lindex $pv 0]]
                if {$klen > $maxlen} { set maxlen $klen }
            }
            foreach pv $params {
                set k [lindex $pv 0]
                set v [lindex $pv 1]
                set pad [expr {$maxlen - [string length $k] + 1}]
                puts "${indent}  ${k}[string repeat { } $pad]= ${v}"
            }
            puts ""
            incr printed
        }

        if {$skipped > 0} {
            puts "  ($skipped deeper cell(s) hidden, use ELAB_DEPTH=-1 to show all)"
        }

        # -- Save full report (always unfiltered) -------------
        set elab_file ${build_dir}/elaboration_params.rpt
        set efh [open $elab_file w]
        puts $efh "# RTL Elaboration, Parameters & Localparams"
        puts $efh "# Top: $TOP  |  Part: $PART  |  Generics: [join $generic_args { }]"
        puts $efh "# Generated: [clock format [clock seconds]]"
        puts $efh ""
        foreach entry $elab_report {
            lassign $entry display_name ref params depth
            set indent [string repeat "  " $depth]
            puts $efh "${indent}${display_name}  (${ref})"
            foreach pv $params {
                puts $efh "${indent}  [lindex $pv 0] = [lindex $pv 1]"
            }
            puts $efh ""
        }
        close $efh
        puts "  Full parameter report saved to: $elab_file"
    } else {
        puts "  (no user-defined parameters found in elaborated hierarchy)"
    }
    puts ""

    close_design

    # Remove wrapper from fileset so it doesn't interfere with synthesis
    catch { remove_files $wrapper_file }
}

# -- Generate OOC constraints --------------------------------
# Deferred to after elaboration so the wrapper doesn't see them.
set xdc_file ${build_dir}/constraints.xdc
set xdc_fd [open ${xdc_file} w]
puts ${xdc_fd} "# Auto-generated OOC constraints, ${FREQ} MHz on port '${CLK}'"
puts ${xdc_fd} "create_clock -period ${period_ns} -name ${CLK} \[get_ports ${CLK}\]"
puts ${xdc_fd} "set_input_delay  -clock ${CLK} ${half_period} \[get_ports -filter {NAME != ${CLK}} \[all_inputs\]\]"
puts ${xdc_fd} "set_output_delay -clock ${CLK} ${half_period} \[all_outputs\]"
close ${xdc_fd}
read_xdc ${xdc_file}
puts "Constraints:  ${xdc_file}"
puts ""

# -- Synthesis ------------------------------------------------
puts ""
hr
puts "  Synthesizing ${TOP} (OOC) ..."
hr
puts ""

set synth_cmd [list synth_design \
    -top  $TOP \
    -part $PART \
    -mode out_of_context]

if {$EFFORT >= 2} {
    lappend synth_cmd -directive PerformanceOptimized -retiming
} elseif {$EFFORT >= 1} {
    lappend synth_cmd -retiming
}

foreach g $generic_args {
    lappend synth_cmd -generic $g
}

puts "synth_design command:"
puts "  $synth_cmd"
puts ""

eval $synth_cmd

write_checkpoint -force ${build_dir}/post_synth.dcp
report_utilization    -file ${build_dir}/post_synth_util.rpt
report_timing_summary -file ${build_dir}/post_synth_timing.rpt

puts ""
puts "Post-synthesis reports written."

# -- Implementation -------------------------------------------
puts ""
hr
puts "  Implementing ${TOP}  (EFFORT=$EFFORT) ..."
hr
puts ""

switch -exact -- $EFFORT {
    0 {
        # -- Normal: single-pass, default directives ----------
        opt_design
        place_design
        phys_opt_design
        route_design
    }
    1 {
        # -- High: explore directives + post-route phys_opt ---
        opt_design -directive ExploreWithRemap
        place_design -directive ExtraNetDelay_high
        phys_opt_design -directive AggressiveExplore
        route_design -directive AggressiveExplore
        phys_opt_design -directive AggressiveExplore
    }
    2 {
        # -- Aggressive: SSI spread, multi-pass phys_opt ------
        opt_design -directive ExploreWithRemap

        place_design -directive SSI_SpreadLogic_low

        # Multi-pass physical optimisation before routing
        phys_opt_design -directive AggressiveExplore
        phys_opt_design -directive AggressiveFanoutOpt
        phys_opt_design -directive AlternateFlowWithRetiming

        route_design -directive AggressiveExplore -tns_cleanup

        # Post-route phys_opt with retime
        phys_opt_design -directive AggressiveExplore

        report_timing_summary -file ${build_dir}/post_route_timing_effort2.rpt
    }
    3 {
        # -- Ultra: everything in 2, then incremental retry ---
        opt_design -directive ExploreWithRemap

        place_design -directive SSI_SpreadLogic_high

        phys_opt_design -directive AggressiveExplore
        phys_opt_design -directive AggressiveFanoutOpt
        phys_opt_design -directive AlternateFlowWithRetiming

        route_design -directive AggressiveExplore -tns_cleanup

        phys_opt_design -directive AggressiveExplore

        # Check if timing is met; if not, do an incremental pass
        set _wns_check [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
        if {$_wns_check < 0} {
            puts ""
            puts "  WNS = ${_wns_check} ns, timing not met, running incremental pass..."
            puts ""

            # Re-place with Explore on the current placement
            place_design -directive ExtraNetDelay_high -post_place_opt

            phys_opt_design -directive AggressiveExplore
            phys_opt_design -directive AlternateFlowWithRetiming

            route_design -directive AggressiveExplore -tns_cleanup

            phys_opt_design -directive AggressiveExplore

            report_timing_summary -file ${build_dir}/post_route_timing_effort3_incr.rpt
        } else {
            puts "  WNS = ${_wns_check} ns, timing met after first pass, skipping incremental."
        }
    }
    default {
        puts "WARNING: Unknown EFFORT level '$EFFORT', falling back to EFFORT=0."
        opt_design
        place_design
        phys_opt_design
        route_design
    }
}

write_checkpoint -force ${build_dir}/post_route.dcp

# -- Post-route reports ---------------------------------------
report_utilization    -file ${build_dir}/post_route_util.rpt
report_timing_summary -file ${build_dir}/post_route_timing.rpt
report_timing -max_paths 20 -nworst 5 -sort_by slack \
    -file ${build_dir}/post_route_critical_paths.rpt
report_drc -file ${build_dir}/post_route_drc.rpt

# -- Final summary --------------------------------------------
set wns [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -hold]]

set lut_used  "?"
set ff_used   "?"
set dsp_used  "?"
set bram_used "?"
set lut_avail ""; set lut_pct ""
set ff_avail  ""; set ff_pct  ""
set dsp_avail ""; set dsp_pct ""
set bram_avail ""; set bram_pct ""
catch {
    set rpt_file ${build_dir}/post_route_util.rpt
    set rfh [open $rpt_file r]
    set rpt_data [read $rfh]
    close $rfh
    # Match: | Label | Used | Fixed | Prohibited | Available | Util% |
    set _row {\s*\|\s*(\d+)\s*\|\s*\d+\s*\|\s*\d+\s*\|\s*(\d+)\s*\|\s*(\S+)\s*\|}
    if {[regexp "CLB LUTs${_row}"      $rpt_data -> val avail pct]} { set lut_used  $val; set lut_avail  $avail; set lut_pct  $pct }
    if {[regexp "CLB Registers${_row}" $rpt_data -> val avail pct]} { set ff_used   $val; set ff_avail   $avail; set ff_pct   $pct }
    if {[regexp "DSPs${_row}"          $rpt_data -> val avail pct]} { set dsp_used  $val; set dsp_avail  $avail; set dsp_pct  $pct }
    if {[regexp "Block RAM Tile${_row}" $rpt_data -> val avail pct]} { set bram_used $val; set bram_avail $avail; set bram_pct $pct }
}

proc fmt_resource {used avail pct} {
    if {$used eq "?"} { return "?" }
    if {$avail eq ""} { return $used }
    return "${used} / ${avail}  (${pct}%)"
}

set max_freq "?"
if {$wns ne "" && $wns >= 0} {
    set max_freq [format "%.1f" [expr {1000.0 / ($period_ns - $wns)}]]
}

puts ""
puts ""
hr
puts "  BUILD COMPLETE"
hr
puts ""
puts_kv "Top module"  $TOP
puts_kv "Part"        $PART
puts_kv "Target freq" "${FREQ} MHz"
puts ""
puts_kv "WNS (setup)" [format "%.3f ns" $wns]
puts_kv "WHS (hold)"  [format "%.3f ns" $whs]
if {$max_freq ne "?"} {
    puts_kv "Fmax (est.)" "${max_freq} MHz"
}
if {$wns < 0} {
    puts ""
    puts "  *** TIMING NOT MET ***"
}
puts ""
puts_kv "LUTs"   [fmt_resource $lut_used  $lut_avail  $lut_pct]
puts_kv "FFs"    [fmt_resource $ff_used   $ff_avail   $ff_pct]
puts_kv "DSPs"   [fmt_resource $dsp_used  $dsp_avail  $dsp_pct]
puts_kv "BRAM"   [fmt_resource $bram_used $bram_avail $bram_pct]
puts ""
puts_kv "Reports" $build_dir
puts ""
hr
puts ""