// /////////////////////////////////////////////////
// Description: Parametric shift register
// Author     : Ahmet Can Mert, TU Graz
////////////////////////////////////////////////////

`timescale 1ns / 1ps
// import config_pkg::*;

// (* keep_hierarchy = `KEEP_HIERARCHY *)
module shiftreg #(
    parameter SHIFT = 1, 
    parameter DATA  = 64,
    parameter RST   = 0,
    parameter ALWAYS_EN = 1
)(
    input                 clk,
    input                 rst,
    input                 en,
    input      [DATA-1:0] data_in,
    output reg [DATA-1:0] data_out
);

reg [DATA-1:0] shift_array [SHIFT-1:0];

always @(posedge clk) begin
    if(RST && rst)
        shift_array[0] <= {DATA{1'd0}};
    else if (en || ALWAYS_EN) begin
        shift_array[0] <= data_in;
    end else begin
        shift_array[0] <= shift_array[0];
    end
end

generate
    for(genvar shft=0; shft < SHIFT-1; shft=shft+1) begin: DELAY_BLOCK
        always @(posedge clk) begin
          if(RST && rst)
            shift_array[shft+1] <= {DATA{1'd0}};
          else if (en || ALWAYS_EN) begin
            shift_array[shft+1] <= shift_array[shft];
          end else begin
            shift_array[shft+1] <= shift_array[shft+1];
          end
        end
    end
endgenerate

always @(*) begin
    data_out = (SHIFT == 0) ? data_in : shift_array[SHIFT-1];
end

endmodule