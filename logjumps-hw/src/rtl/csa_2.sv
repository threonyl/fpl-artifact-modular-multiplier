// --------------------------------------------------------------
// Module   : csa_2
// Purpose  : Carry-save adder (3-to-2 compressor)
//
//            Computes  x + y + z  in carry-save form:
//              sum[i], carry[i+1]  =  FA(x[i], y[i], z[i])
//
//            The carry vector is shifted left by one bit, so:
//              sum[WIDTH-1] = 0        (MSB of sum is always 0)
//              carry[0]     = 0        (LSB of carry is always 0)
//
//            When fewer than 3 operands are valid (NUM_OPERANDS < 3),
//            the unused inputs are ignored and the valid operands are
//            passed through without any adder logic.
//
// Usage    :
//   csa_2 #(
//       .WIDTH        (33),
//       .NUM_OPERANDS (3)
//   ) u_csa (
//       .x     (op_a),
//       .y     (op_b),
//       .z     (op_c),
//       .sum   (s),
//       .carry (c)
//   );
//
// Author(s): Ahmet Can Mert, TU Graz (2023)
//            Selim Kirbiyik, TU Graz (Modified, 23.2.2026)
// --------------------------------------------------------------

`timescale 1ns / 1ps

module csa_2 #(
    parameter int unsigned WIDTH        = 33,
    parameter int unsigned NUM_OPERANDS = 3    // valid operands: 0, 1, 2, or 3
)(
    input  logic [WIDTH-1:0] x,
    input  logic [WIDTH-1:0] y,
    input  logic [WIDTH-1:0] z,
    output logic [WIDTH-1:0] sum,
    output logic [WIDTH-1:0] carry
);

    generate
        if (NUM_OPERANDS == 3) begin : gen_compress
            // -- Full 3-to-2 compression ---------------------
            //   Bit-wise full-adder for bits [WIDTH-2:0].
            //   MSB of sum and LSB of carry are tied to zero
            //   because the carry is left-shifted by one bit.
            assign sum[WIDTH-1] = 1'b0;
            assign carry[0]     = 1'b0;

            for (genvar i = 0; i < WIDTH - 1; i++) begin : gen_fa
                assign {carry[i+1], sum[i]} = x[i] + y[i] + z[i];
            end

        end else if (NUM_OPERANDS == 2) begin : gen_pass2
            // -- Two valid operands: no compression needed ---
            assign sum   = x;
            assign carry = y;

        end else if (NUM_OPERANDS == 1) begin : gen_pass1
            // -- Single operand passthrough ------------------
            assign sum   = x;
            assign carry = '0;

        end else begin : gen_zero
            // -- No valid operands ---------------------------
            assign sum   = '0;
            assign carry = '0;
        end
    endgenerate

endmodule
