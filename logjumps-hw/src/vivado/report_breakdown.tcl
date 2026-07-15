# report_breakdown.tcl -> per-module area AND latency breakdown for modmul builds.
#
# For each build directory it prints, per sub-module (ModMul, IntMul, ModRed,
# ModAcc): the pipeline depth in cycles ("Stages") and the LUT / FF / DSP use,
# plus the point's target frequency, worst slack, and Fmax.
#
# Usage (each argument is a build DIRECTORY, or a post_route.dcp path):
#   cd src/vivado
#   vivado -mode batch -source report_breakdown.tcl -tclargs build/<tag> [build/<tag2> ...]
#   vivado -mode batch -source report_breakdown.tcl -tclargs build/<tag>/post_route.dcp
#   # or, with no args, every routed build under build/ and Design_Points/:
#   vivado -mode batch -source report_breakdown.tcl
#
# A directory is required to also show the "Stages" column, which is read from
# <dir>/elaboration_params.rpt; passing a .dcp still works (its directory is
# used), but Stages show "?" if that directory has no elaboration_params.rpt.
#
# Module <-> RTL instance / latency localparam:
#   ModMul = modmul          (whole datapath)          Stages = LAT
#   IntMul = intmul_wrapper  (u_intmul)                Stages = MUL_LAT
#   ModRed = logjumps        (u_logjumps)              Stages = LJ_LAT
#   ModAcc = modacc          (u_modacc, in ModRed)     Stages = ACC_LAT

# -- collect build dirs ---------------------------------------------------
set dirs $argv
if {[llength $dirs] == 0} {
    foreach g [concat [glob -nocomplain build/*] [glob -nocomplain Design_Points/*/*]] {
        if {[file exists $g/post_route.dcp]} { lappend dirs $g }
    }
}
if {[llength $dirs] == 0} { puts "ERROR: no build dirs given and none found under build/ or Design_Points/"; exit 1 }

# -- helpers --------------------------------------------------------------
# First "KEY = VALUE" in an elaboration_params.rpt (top modmul LAT/MUL_LAT/
# LJ_LAT come first; ACC_LAT first appears in the logjumps block = ModAcc).
proc elab_val {file key} {
    if {![file exists $file]} { return "?" }
    set fh [open $file r]; set data [read $fh]; close $fh
    foreach line [split $data "\n"] {
        if {[regexp "^\\s*${key}\\s*=\\s*(\\d+)" $line -> v]} { return $v }
    }
    return "?"
}
# Row of "report_utilization -hierarchical" whose Module column equals $mod.
proc util_row {rpt mod} {
    foreach line [split $rpt "\n"] {
        set cols [split $line "|"]
        if {[llength $cols] < 12} continue
        if {[string trim [lindex $cols 2]] eq $mod} { return $cols }
    }
    return ""
}
proc cell {cols i} { if {$cols eq ""} { return "?" }; return [string trim [lindex $cols $i]] }

# -- report each dir ------------------------------------------------------
foreach arg $dirs {
    # Accept either a build directory or a post_route.dcp path.
    if {[string match *.dcp $arg]} {
        set dcp $arg
        set dir [file dirname $arg]
    } else {
        set dir [string trimright $arg /]
        set dcp $dir/post_route.dcp
    }
    if {![file exists $dcp]} { puts "SKIP $arg (no post_route.dcp)"; continue }

    open_checkpoint $dcp
    set rpt   [report_utilization -hierarchical -return_string]
    set wns   [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
    set clk   [lindex [get_clocks] 0]
    set per   [get_property PERIOD $clk]
    set fmax  [expr {$per > $wns ? 1000.0 / ($per - $wns) : 0}]
    set elab  $dir/elaboration_params.rpt

    set mm [util_row $rpt modmul]
    if {$mm eq ""} { set mm [util_row $rpt "(top)"] }
    set im [util_row $rpt intmul_wrapper]
    set mr [util_row $rpt logjumps]
    set ma [util_row $rpt modacc]

    puts ""
    puts "==== [file tail $dir] ===="
    puts [format "  target %.0f MHz   WNS %+0.3f ns   Fmax %.0f MHz%s" \
              [expr {1000.0/$per}] $wns $fmax [expr {$wns < 0 ? "   (TIMING NOT MET)" : ""}]]
    puts [format "  %-8s %-7s %-9s %-9s %s" Module Stages LUT FF DSP]
    puts [format "  %-8s %-7s %-9s %-9s %s" ModMul [elab_val $elab LAT]     [cell $mm 3] [cell $mm 7] [cell $mm 11]]
    puts [format "  %-8s %-7s %-9s %-9s %s" IntMul [elab_val $elab MUL_LAT] [cell $im 3] [cell $im 7] [cell $im 11]]
    puts [format "  %-8s %-7s %-9s %-9s %s" ModRed [elab_val $elab LJ_LAT]  [cell $mr 3] [cell $mr 7] [cell $mr 11]]
    puts [format "  %-8s %-7s %-9s %-9s %s" ModAcc [elab_val $elab ACC_LAT] [cell $ma 3] [cell $ma 7] [cell $ma 11]]

    close_project
}
puts ""
