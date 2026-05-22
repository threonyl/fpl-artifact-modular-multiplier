#
open_hw_manager
connect_hw_server -allow_non_jtag

# open the U280 target
open_hw_target {localhost:3121/xilinx_tcf/Xilinx/21760322701LA}
current_hw_device [get_hw_devices xcu280_u55c_0]
refresh_hw_device -update_hw_probes false [lindex [get_hw_devices xcu280_u55c_0] 0]

# program U280:
set_property PROBES.FILE {} [get_hw_devices xcu280_u55c_0]
set_property FULL_PROBES.FILE {} [get_hw_devices xcu280_u55c_0]

set_property PROGRAM.FILE {./../proj/logjump/project_1/project_1.runs/impl_1/design_1_wrapper.bit} [get_hw_devices xcu280_u55c_0]
program_hw_devices [get_hw_devices xcu280_u55c_0]
refresh_hw_device [lindex [get_hw_devices xcu280_u55c_0] 0]
