# build.tcl, Bootstrap for Vivado OOC build
# Sources the implementation with -notrace to suppress command echo.
set _dir [file dirname [info script]]
source -notrace [file join $_dir _build_impl.tcl]