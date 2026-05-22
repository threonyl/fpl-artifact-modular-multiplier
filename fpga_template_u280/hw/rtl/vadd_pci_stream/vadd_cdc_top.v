`timescale 1ns / 1ps


// Vadder module performs simple addition by ADD_CONSTANT using AXI stream interfaces
// The module takes two input streams and two output streams, concatenates them, puts them to the faster clock domainan and performs the computation there.
// i.e. 2x512b/cc @ 250MHz -> 1xPIPE_WIDTH(512 or 1024) b/cc @500MHz -> 2x512b/cc @ 250MHz. However, the U280 only supports 128Gbit/s PCI links. So, the input/output on U280 can only supply 1x 512bit/cc
//
// From XDMA master 0 ---> 512b/cc @ 250MHz -|       (PIPE_WIDTH = 512 or 1024)           |-> To XDMA slave 0 ---> 512b/cc @ 250MHz
//                         (PCI_WIDTH)       |-> CDC -> PIPE_WIDTH b/cc @ 500MHz -> CDC ->|
// From XDMA master 1 ---> 512b/cc @ 250MHz -|          pipeline (vadd)                   |-> To XDMA slave 0 ---> 512b/cc @ 250MHz
//
module vadd_cdc_top #(
    parameter PCI_WIDTH    = 512,
    parameter PIPE_WIDTH   = 512,
    parameter ADD_CONSTANT = 1
  )
  (
    input axis_clk,
    input rtl_clk,
    input axis_rst, // active low

    // AXI Slave interface 0
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_vadd_0 TDATA" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 250000000" *)
    input [PCI_WIDTH-1:0] s_tdata_0,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_vadd_0 TLAST" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 250000000" *)
    input s_tlast_0,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_vadd_0 TVALID" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 250000000" *)
    input s_tvalid_0,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_vadd_0 TREADY" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 250000000" *)
    output s_tready_0,

    // AXI Slave interface 1
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_vadd_1 TDATA" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 250000000" *)
    input [PCI_WIDTH-1:0] s_tdata_1,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_vadd_1 TLAST" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 250000000" *)
    input s_tlast_1,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_vadd_1 TVALID" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 250000000" *)
    input s_tvalid_1,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_vadd_1 TREADY" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 250000000" *)
    output s_tready_1,

    // AXI Master interface 0
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_vadd_0 TDATA" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 250000000" *)
    output [PCI_WIDTH-1:0] m_tdata_0,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_vadd_0 TLAST" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 250000000" *)
    output  m_tlast_0,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_vadd_0 TVALID" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 250000000" *)
    output  m_tvalid_0,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_vadd_0 TREADY" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 250000000" *)
    input m_tready_0,

    // AXI Master interface 1
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_vadd_1 TDATA" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 250000000" *)
    output [PCI_WIDTH-1:0] m_tdata_1,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_vadd_1 TLAST" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 250000000" *)
    output  m_tlast_1,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_vadd_1 TVALID" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 250000000" *)
    output  m_tvalid_1,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_vadd_1 TREADY" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 250000000" *)
    input m_tready_1
);


  vadd_cdc #(
    .PCI_WIDTH    ( PCI_WIDTH         ),
    .PIPE_WIDTH   ( PIPE_WIDTH        ),
    .ADD_CONSTANT ( ADD_CONSTANT      )
  ) vadd_cdc_inst (
    .axis_clk  ( axis_clk ),
    .rtl_clk   ( rtl_clk ),
    .axis_rst  (axis_rst ),

    // AXI Slave interface
    .s_tdata_0  ( s_tdata_0  ),
    .s_tlast_0  ( s_tlast_0  ),
    .s_tvalid_0 ( s_tvalid_0 ),
    .s_tready_0 ( s_tready_0 ),
    .s_tdata_1  ( s_tdata_1  ),
    .s_tlast_1  ( s_tlast_1  ),
    .s_tvalid_1 ( s_tvalid_1 ),
    .s_tready_1 ( s_tready_1 ),

    // AXI Master interface
    .m_tdata_0  ( m_tdata_0  ),
    .m_tlast_0  ( m_tlast_0  ),
    .m_tvalid_0 ( m_tvalid_0 ),
    .m_tready_0 ( m_tready_0 ),
    .m_tdata_1  ( m_tdata_1  ),
    .m_tlast_1  ( m_tlast_1  ),
    .m_tvalid_1 ( m_tvalid_1 ),
    .m_tready_1 ( m_tready_1 )
  );

   
endmodule
