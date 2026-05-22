`timescale 1ns / 1ps

module vadd_cdc_pipeline #(
        parameter WIDTH        = 512,
        parameter ADD_CONSTANT = 1,
        parameter PIPELINE_LAT = 10
    ) 
    (
    input                    rtl_clk,
    input                    rtl_rst,  // active high

    // AXI Slave interface
    input  logic [WIDTH-1:0] s_tdata,
    input  logic             s_tlast,
    input  logic             s_tvalid,
    output logic             s_tready,
    input  logic             s_tdest,

    // AXI Master interface
    output logic [WIDTH-1:0] m_tdata,
    output logic             m_tlast,
    output logic             m_tvalid,
    input  logic             m_prog_full,
    output logic             m_tdest
  );


  modmul modmul_inst (
    .clk(rtl_clk),
    .A(s_tdata[381-1:0]),
    .B(s_tdata[512+381-1:512]),
    .q('d0),
    .rho('d0),
    .mu('d0),
    .D(m_tdata[381-1:0])
  );
  assign m_tdata[WIDTH-1:381] = 'd0;


    /*
    logic [31:0] add_result;
    assign add_result = s_tdata[31:0] + ADD_CONSTANT + s_tdest;
    shiftreg #(
        .SHIFT      ( PIPELINE_LAT       ), 
        .DATA       ( WIDTH              )
    ) pipeline_inst (
        .clk        ( rtl_clk            ),
        .data_in    ( {s_tdata[WIDTH-1:32], add_result}),
        .data_out   ( m_tdata            )
    );

    */

    logic s_handshake;
    shiftreg #(
      .SHIFT   ( PIPELINE_LAT             ), 
      .DATA    ( 3                        ),
      .RST     ( 1                        )
    ) delay_inst (
        .clk     ( rtl_clk                ),
        .rst     ( rtl_rst                ),
        .data_in ( {s_handshake,s_tdest,s_tlast} ),
        .data_out( {m_tvalid,m_tdest,m_tlast} )
    );

    assign s_handshake = s_tvalid && !m_prog_full;
    assign s_tready = s_handshake;   


endmodule
