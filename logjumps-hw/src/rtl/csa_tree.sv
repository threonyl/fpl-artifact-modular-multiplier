// --------------------------------------------------------------
// Module   : csa_tree
// Purpose  : Parametric carry-save-adder tree
//            Reduces NUM_INPUTS operands to a carry-save pair
//            (two outputs whose sum equals the sum of all inputs).
//
// Usage    :
//   import csa_tree_pkg::*;
//
//   localparam int unsigned W_IN  = 32;
//   localparam int unsigned N     = 10;
//   localparam int unsigned W_OUT = csa_tree_output_width(W_IN, N);
//
//   logic [W_IN-1:0]  operands [N];
//   logic [W_OUT-1:0] result   [2];   // result[0]+result[1] == sum(operands)
//
//   csa_tree #(
//       .INPUT_WIDTH  (W_IN),
//       .NUM_INPUTS   (N),
//       .OUTPUT_WIDTH (W_OUT)
//   ) u_tree (
//       .operands (operands),
//       .result   (result)
//   );
//
// Dependencies : csa_tree_pkg, csa_2
// Author(s): Ahmet Can Mert, TU Graz (2023)
//            Selim Kirbiyik, TU Graz (Modified, 23.2.2026)
// --------------------------------------------------------------

`timescale 1ns / 1ps

module csa_tree
    import csa_tree_pkg::*;
#(
    parameter int unsigned INPUT_WIDTH  = 32,
    parameter int unsigned NUM_INPUTS   = 10,
    parameter int unsigned OUTPUT_WIDTH = csa_tree_output_width(INPUT_WIDTH, NUM_INPUTS) // INPUT_WIDTH + ceil(log2(NUM_INPUTS))
)(
    input  logic [INPUT_WIDTH-1:0]  operands [NUM_INPUTS],
    output logic [OUTPUT_WIDTH-1:0] result   [2]
);

    // -- Reduction arithmetic ------------------------------------
    //   Each 3-to-2 compressor turns 3 operands into 2.
    //   Leftover operands (0, 1, or 2) pass through unchanged.
    localparam int unsigned NUM_CSA     = NUM_INPUTS / 3;
    localparam int unsigned REMAINDER   = NUM_INPUTS % 3;
    localparam int unsigned NEXT_INPUTS = NUM_CSA * 2 + REMAINDER;

    // Bit-width grows by exactly 1 per level (carry expansion),
    // capped at OUTPUT_WIDTH.
    localparam int unsigned NEXT_WIDTH  = (INPUT_WIDTH < OUTPUT_WIDTH)
                                        ? INPUT_WIDTH + 1
                                        : OUTPUT_WIDTH;

    // -- Zero-extend operands to NEXT_WIDTH for carry expansion --
    logic [NEXT_WIDTH-1:0] extended [NUM_INPUTS];

    for (genvar i = 0; i < NUM_INPUTS; i++) begin : gen_extend
        assign extended[i] = NEXT_WIDTH'(operands[i]);
    end

    // -- 3-to-2 compression + passthrough at NEXT_WIDTH ----------
    logic [NEXT_WIDTH-1:0] reduced [NEXT_INPUTS];

    for (genvar i = 0; i < NUM_CSA; i++) begin : gen_csa
        csa_2 #(
            .WIDTH        (NEXT_WIDTH),
            .NUM_OPERANDS (3)
        ) u_csa (
            .x     (extended[3*i + 0]),
            .y     (extended[3*i + 1]),
            .z     (extended[3*i + 2]),
            .sum   (reduced [2*i + 0]),
            .carry (reduced [2*i + 1])
        );
    end

    for (genvar i = 0; i < REMAINDER; i++) begin : gen_passthrough
        assign reduced[NUM_CSA * 2 + i] = extended[NUM_CSA * 3 + i];
    end

    // -- Base case or recurse ------------------------------------
    generate
        if (NEXT_INPUTS <= 2) begin : gen_base
            // Final level: zero-extend from NEXT_WIDTH to OUTPUT_WIDTH.
            assign result[0] = OUTPUT_WIDTH'(reduced[0]);
            if (NEXT_INPUTS == 2)
                assign result[1] = OUTPUT_WIDTH'(reduced[1]);
            else
                assign result[1] = '0;

        end else begin : gen_recurse
            // Recurse with NEXT_WIDTH as the new INPUT_WIDTH.
            // No trimming needed - reduced is already at NEXT_WIDTH.
            csa_tree #(
                .INPUT_WIDTH  (NEXT_WIDTH),
                .NUM_INPUTS   (NEXT_INPUTS),
                .OUTPUT_WIDTH (OUTPUT_WIDTH)
            ) u_subtree (
                .operands (reduced),
                .result   (result)
            );
        end
    endgenerate

endmodule