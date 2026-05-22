//
// addtree - Binary reduction addition tree with configurable pipelining
//           and optional carry-save compression front-end
//
// Computes o_c = i_a[0] + i_a[1] + ... + i_a[N-1]
// where N = NUM_INPUTS operands are packed into the wide bus i_a.
//
// Architecture
// ------------
// Two reduction strategies are available, selected by USE_CSA:
//
//   USE_CSA = 0 (default)
//     Binary reduction tree.  At each stage, inputs are paired and
//     summed with a carry-propagate adder; an odd leftover element
//     is forwarded unchanged.
//
//   USE_CSA = 1
//     Carry-save compression tree followed by a single binary add.
//     At each stage, inputs are grouped in triples and compressed
//     with a 3-to-2 carry-save compressor (csa_2); leftover
//     elements (0, 1, or 2) pass through.  Once only two operands
//     remain they are added with one carry-propagate adder.
//
// Pipeline registers
// ------------------
// Controlled by REG_PERIOD (measured in *stage* levels):
//
//   REG_PERIOD = 0  ->  Purely combinational, no intermediate regs.
//   REG_PERIOD = 1  ->  Register after every stage.
//   REG_PERIOD = N  ->  Register after every N-th stage.
//
// In CSA mode, stage numbering spans the compression stages *and*
// the final binary addition stage (which is the last stage).
//
// A register is placed after stage s when (s+1) mod REG_PERIOD == 0.
//
// Optional REG_IN / REG_OUT add input/output pipeline stages.
// REG_OUT is merged with the last intermediate register when the
// total stage count is an exact multiple of REG_PERIOD, preventing
// a redundant clock cycle.
//
// Example: REG_PERIOD=3, NUM_INPUTS giving tree depth 5:
//   In -> REG_IN -> Add -> Add -> Add -> Reg -> Add -> Add -> REG_OUT -> Out
//
// Example: REG_PERIOD=2, tree depth 4, REG_OUT=1:
//   In -> REG_IN -> Add -> Add -> Reg -> Add -> Add -> Reg(merged) -> Out
//   (no separate REG_OUT since the last intermediate reg covers it)
//
// Passthrough handling
// --------------------
// Binary mode:  when a stage has an odd input count, the unpaired
//               element is wired directly onto the output bus.
//
// CSA mode:     when a stage's input count is not a multiple of 3,
//               the 1 or 2 leftover elements are wired through.
//
// In both cases the stage-level pipeline register (when present)
// covers the entire bus, so passthroughs are automatically
// time-aligned with the compressor/adder outputs.
//
// Pipeline latency
// ----------------
//   Binary:
//     LATENCY = REG_IN
//             + floor(num_stages / REG_PERIOD)
//             + REG_OUT  (if not merged)
//
//   CSA:
//     LATENCY = REG_IN
//             + floor((csa_stages + 1) / REG_PERIOD)
//             + REG_OUT  (if not merged)
//
// Dependencies
// ------------
//   addtree_pkg                    (always)
//   csa_2                          (only when USE_CSA = 1)
//
// Parameter validation
// --------------------
// A $fatal is emitted at simulation start if REG_PERIOD exceeds
// the tree depth (and REG_PERIOD > 0), as this is almost certainly
// an error.

module addtree #(
    parameter int unsigned WIDTH      = 32,
    parameter int unsigned NUM_INPUTS = 16,
    parameter int unsigned REG_PERIOD = 1,
    parameter bit          REG_IN     = 1,
    parameter bit          REG_OUT    = 1,
    parameter bit          USE_CSA    = 1,
    // Split the final binary adder at the CARRY8-aligned midpoint.
    // Inserts one pipeline register between the lower-half and
    // upper-half of the carry-propagate addition that resolves the
    // last CSA sum/carry pair.  Only effective when USE_CSA = 1 and
    // NUM_INPUTS > 2.  Costs +1 clock cycle of latency.
    parameter bit          FF_ADD     = 1
) (
    input                                     clk,
    input      [(NUM_INPUTS * WIDTH) - 1 : 0] i_a,   // N operands, each WIDTH bits, packed
    output     [              WIDTH  - 1 : 0] o_c    // result: sum of all operands
);

    localparam int unsigned NUM_STAGES = addtree_pkg::total_stages(NUM_INPUTS, USE_CSA);
    // Total pipeline depth exposed for testbench use.
    localparam int unsigned LATENCY    = addtree_pkg::addtree_latency(
                                             NUM_INPUTS, REG_PERIOD, REG_IN, REG_OUT, USE_CSA,
                                             FF_ADD);

    // ---------------------------------------------------------------
    // Parameter validation
    // ---------------------------------------------------------------
    initial begin
        addtree_pkg::check_params(NUM_INPUTS, REG_PERIOD, USE_CSA);
    end

    // ---------------------------------------------------------------
    // Trivial case: 0 or 1 input - nothing to add
    // ---------------------------------------------------------------
    generate
    if (NUM_INPUTS <= 1) begin : gen_passthrough
        assign o_c = i_a[WIDTH-1:0];

    // ---------------------------------------------------------------
    // CSA compression tree + final binary adder
    // ---------------------------------------------------------------
    end else if (USE_CSA && NUM_INPUTS > 2) begin : gen_csa

        // -----------------------------------------------------------
        // Internal CSA bit-width
        // -----------------------------------------------------------
        // The csa_2 compressor requires its MSB input bit to be 0
        // (headroom for the left-shifted carry).  We zero-extend
        // each WIDTH-bit operand to CSA_W = WIDTH + 1 bits so that
        // bit [WIDTH] is always 0 on entry.  Intermediate carry
        // values may set bit [WIDTH], but that only affects the
        // overflow bit we discard at the final binary add.
        // -----------------------------------------------------------
        localparam int unsigned CSA_W = WIDTH + 1;

        // -----------------------------------------------------------
        // Optional input register
        // -----------------------------------------------------------
        wire [(NUM_INPUTS * WIDTH) - 1 : 0] in_data;

        if (REG_IN) begin : gen_reg_in
            reg [(NUM_INPUTS * WIDTH) - 1 : 0] in_reg;
            always @(posedge clk)
                in_reg <= i_a;
            assign in_data = in_reg;
        end else begin : gen_no_reg_in
            assign in_data = i_a;
        end

        // -----------------------------------------------------------
        // Zero-extend each WIDTH-bit operand to CSA_W bits
        // -----------------------------------------------------------
        wire [(NUM_INPUTS * CSA_W) - 1 : 0] in_ext;

        for (genvar k = 0; k < NUM_INPUTS; k = k + 1) begin : gen_zext
            assign in_ext[((k + 1) * CSA_W) - 1 -: CSA_W] =
                {{1'b0}, in_data[((k + 1) * WIDTH) - 1 -: WIDTH]};
        end

        // -----------------------------------------------------------
        // CSA compression stages
        // -----------------------------------------------------------
        // Each stage s groups operands in triples, compresses each
        // triple with a csa_2 instance, and passes through any
        // remainder (0, 1, or 2 elements).
        //
        // The output bus layout per stage:
        //   [0 .. 2*N_TRIPLES-1]  - csa_2 sum/carry pairs
        //   [2*N_TRIPLES .. OUT_W-1]  - passthrough elements
        //
        // All operands are CSA_W bits wide throughout the tree.
        //
        // If the stage is a pipeline boundary (HAS_REG), the entire
        // output bus is registered.
        // -----------------------------------------------------------
        localparam int unsigned CSA_STAGES = addtree_pkg::csa_num_stages(NUM_INPUTS);

        for (genvar s = 0; s < CSA_STAGES; s = s + 1) begin : gen_csa_stage
            localparam int unsigned IN_W      = addtree_pkg::csa_stage_width(NUM_INPUTS, s);
            localparam int unsigned OUT_W     = addtree_pkg::csa_stage_width(NUM_INPUTS, s + 1);
            localparam int unsigned N_TRIPLES = IN_W / 3;
            localparam int unsigned REMAINDER = IN_W % 3;

            // Pipeline register at this stage?
            localparam bit HAS_REG = (REG_PERIOD == 0) ? 1'b0
                                   : (((s + 1) % REG_PERIOD) == 0);

            // Combinational results for this stage.
            wire [(OUT_W * CSA_W) - 1 : 0] comb;

            // ----- Stage output: registered or combinational --------
            wire [(OUT_W * CSA_W) - 1 : 0] data;

            // ----- 3-to-2 compressors for each triple ---------------
            for (genvar j = 0; j < N_TRIPLES; j = j + 1) begin : gen_compress
                wire [CSA_W-1:0] op_x, op_y, op_z;

                if (s == 0) begin : gen_first
                    assign op_x = in_ext[((3*j + 1) * CSA_W) - 1 -: CSA_W];
                    assign op_y = in_ext[((3*j + 2) * CSA_W) - 1 -: CSA_W];
                    assign op_z = in_ext[((3*j + 3) * CSA_W) - 1 -: CSA_W];
                end else begin : gen_rest
                    assign op_x = gen_csa_stage[s-1].data[((3*j + 1) * CSA_W) - 1 -: CSA_W];
                    assign op_y = gen_csa_stage[s-1].data[((3*j + 2) * CSA_W) - 1 -: CSA_W];
                    assign op_z = gen_csa_stage[s-1].data[((3*j + 3) * CSA_W) - 1 -: CSA_W];
                end

                csa_2 #(
                    .WIDTH        (CSA_W),
                    .NUM_OPERANDS (3)
                ) u_csa (
                    .x     (op_x),
                    .y     (op_y),
                    .z     (op_z),
                    .sum   (comb[((2*j + 1) * CSA_W) - 1 -: CSA_W]),
                    .carry (comb[((2*j + 2) * CSA_W) - 1 -: CSA_W])
                );
            end

            // ----- Passthrough for leftover elements ----------------
            for (genvar j = 0; j < REMAINDER; j = j + 1) begin : gen_passthrough
                if (s == 0) begin : gen_first
                    assign comb[((N_TRIPLES * 2 + j + 1) * CSA_W) - 1 -: CSA_W] =
                        in_ext[((N_TRIPLES * 3 + j + 1) * CSA_W) - 1 -: CSA_W];
                end else begin : gen_rest
                    assign comb[((N_TRIPLES * 2 + j + 1) * CSA_W) - 1 -: CSA_W] =
                        gen_csa_stage[s-1].data[((N_TRIPLES * 3 + j + 1) * CSA_W) - 1 -: CSA_W];
                end
            end


            if (HAS_REG) begin : gen_pipe_reg
                reg [(OUT_W * CSA_W) - 1 : 0] stage_reg;
                always @(posedge clk)
                    stage_reg <= comb;
                assign data = stage_reg;
            end else begin : gen_no_pipe_reg
                assign data = comb;
            end
        end

        // -----------------------------------------------------------
        // Final binary addition: 2 carry-save operands -> 1 result
        // -----------------------------------------------------------
        // This is the last stage in the pipeline schedule (index
        // CSA_STAGES).  Register placement follows the same
        // REG_PERIOD rule as the compression stages above.
        //
        // When FF_ADD = 1, the addition is split at a CARRY8-aligned
        // midpoint into two pipeline stages (lower-half + carry,
        // then upper-half), exactly like mac_std's FF_ADD mechanism.
        //
        // The two CSA_W-bit operands are added and the result is
        // truncated to WIDTH bits (modulo 2^WIDTH arithmetic).
        // -----------------------------------------------------------
        localparam bit FINAL_HAS_REG = (REG_PERIOD == 0) ? 1'b0
                                      : (((CSA_STAGES + 1) % REG_PERIOD) == 0);

        // CARRY8-aligned split point for the pipelined adder
        localparam int unsigned ADD_SPLIT   = ((CSA_W / 2) + 7) / 8 * 8;
        localparam int unsigned ADD_UPPER_W = CSA_W - ADD_SPLIT;

        wire [WIDTH-1:0] final_comb;

        if (FF_ADD) begin : gen_split_final_add
            // ---- Split-adder: lower half (stage N) ----
            wire [CSA_W-1:0] add_op_a = gen_csa_stage[CSA_STAGES-1].data[CSA_W-1:0];
            wire [CSA_W-1:0] add_op_b = gen_csa_stage[CSA_STAGES-1].data[(2*CSA_W)-1 : CSA_W];

            wire [ADD_SPLIT:0] add_lo_full = {1'b0, add_op_a[ADD_SPLIT-1:0]}
                                           + {1'b0, add_op_b[ADD_SPLIT-1:0]};

            reg [ADD_SPLIT-1:0]     add_lo_q;
            reg                     add_carry_q;
            reg [ADD_UPPER_W-1:0]   add_upper_a_q;
            reg [ADD_UPPER_W-1:0]   add_upper_b_q;

            always @(posedge clk) begin
                add_lo_q      <= add_lo_full[ADD_SPLIT-1:0];
                add_carry_q   <= add_lo_full[ADD_SPLIT];
                add_upper_a_q <= add_op_a[CSA_W-1:ADD_SPLIT];
                add_upper_b_q <= add_op_b[CSA_W-1:ADD_SPLIT];
            end

            // ---- Split-adder: upper half (stage N+1) ----
            wire [ADD_UPPER_W:0] add_hi_full = {1'b0, add_upper_a_q}
                                             + {1'b0, add_upper_b_q}
                                             + {{ADD_UPPER_W{1'b0}}, add_carry_q};

            wire [CSA_W-1:0] final_sum_split = {add_hi_full[ADD_UPPER_W-1:0], add_lo_q};
            assign final_comb = final_sum_split[WIDTH-1:0];

        end else begin : gen_full_final_add
            wire [CSA_W-1:0] final_sum;
            assign final_sum  = gen_csa_stage[CSA_STAGES-1].data[CSA_W-1:0]
                              + gen_csa_stage[CSA_STAGES-1].data[(2*CSA_W)-1 : CSA_W];
            assign final_comb = final_sum[WIDTH-1:0];
        end

        wire [WIDTH-1:0] final_data;

        if (FINAL_HAS_REG) begin : gen_final_reg
            reg [WIDTH-1:0] final_reg;
            always @(posedge clk)
                final_reg <= final_comb;
            assign final_data = final_reg;
        end else begin : gen_no_final_reg
            assign final_data = final_comb;
        end

        // -----------------------------------------------------------
        // Output register (with merge logic)
        // -----------------------------------------------------------
        localparam bit LAST_HAS_REG = FINAL_HAS_REG;
        localparam bit NEED_OUT_REG = REG_OUT & ~LAST_HAS_REG;

        if (NEED_OUT_REG) begin : gen_reg_out
            reg [WIDTH-1:0] out_reg;
            always @(posedge clk)
                out_reg <= final_data;
            assign o_c = out_reg;
        end else begin : gen_no_reg_out
            assign o_c = final_data;
        end

    // ---------------------------------------------------------------
    // Binary reduction tree (original path)
    // ---------------------------------------------------------------
    end else begin : gen_tree

        // -----------------------------------------------------------
        // Optional input register
        // -----------------------------------------------------------
        wire [(NUM_INPUTS * WIDTH) - 1 : 0] in_data;

        if (REG_IN) begin : gen_reg_in
            reg [(NUM_INPUTS * WIDTH) - 1 : 0] in_reg;
            always @(posedge clk)
                in_reg <= i_a;
            assign in_data = in_reg;
        end else begin : gen_no_reg_in
            assign in_data = i_a;
        end

        // -----------------------------------------------------------
        // Binary reduction tree stages
        // -----------------------------------------------------------
        // Each stage s takes stage_width(NUM_INPUTS, s) inputs and
        // produces stage_width(NUM_INPUTS, s+1) outputs.
        //
        // The output bus layout per stage:
        //   [0 .. N_PAIRS-1]  - adder results
        //   [N_PAIRS]         - passthrough (only when input count odd)
        //
        // If the stage is a pipeline boundary (HAS_REG), the entire
        // output bus is registered.
        // -----------------------------------------------------------
        for (genvar s = 0; s < NUM_STAGES; s = s + 1) begin : gen_stage
            localparam int unsigned IN_W    = addtree_pkg::stage_width(NUM_INPUTS, s);
            localparam int unsigned OUT_W   = addtree_pkg::stage_width(NUM_INPUTS, s + 1);
            localparam int unsigned N_PAIRS = IN_W / 2;
            localparam bit          HAS_ODD = (IN_W % 2) != 0;

            // Pipeline register at this stage?
            // Placed when (s+1) is a multiple of REG_PERIOD.
            // Ternary avoids modulo-by-zero when REG_PERIOD == 0.
            localparam bit HAS_REG = (REG_PERIOD == 0) ? 1'b0
                                   : (((s + 1) % REG_PERIOD) == 0);

            // Combinational addition results for this stage.
            wire [(OUT_W * WIDTH) - 1 : 0] comb;

            // ----- Adders for each pair of elements ----------------
            for (genvar j = 0; j < N_PAIRS; j = j + 1) begin : gen_add
                if (s == 0) begin : gen_first
                    // Stage 0: read operand pairs from the input bus.
                    assign comb[((j + 1) * WIDTH) - 1 -: WIDTH] =
                        in_data[((2*j + 2) * WIDTH) - 1 -: WIDTH] +
                        in_data[((2*j + 1) * WIDTH) - 1 -: WIDTH];
                end else begin : gen_rest
                    // Stages 1+: read from the previous stage's output.
                    assign comb[((j + 1) * WIDTH) - 1 -: WIDTH] =
                        gen_stage[s-1].data[((2*j + 2) * WIDTH) - 1 -: WIDTH] +
                        gen_stage[s-1].data[((2*j + 1) * WIDTH) - 1 -: WIDTH];
                end
            end

            // ----- Passthrough for the unpaired (odd) element ------
            // Placed at the top of the output bus (index OUT_W-1).
            // The bus-level register (if present) keeps it aligned
            // with the adder outputs - no separate delay needed.
            if (HAS_ODD) begin : gen_odd
                if (s == 0) begin : gen_odd_first
                    assign comb[(OUT_W * WIDTH) - 1 -: WIDTH] =
                        in_data[(IN_W * WIDTH) - 1 -: WIDTH];
                end else begin : gen_odd_rest
                    assign comb[(OUT_W * WIDTH) - 1 -: WIDTH] =
                        gen_stage[s-1].data[(IN_W * WIDTH) - 1 -: WIDTH];
                end
            end

            // ----- Stage output: registered or combinational -------
            wire [(OUT_W * WIDTH) - 1 : 0] data;

            if (HAS_REG) begin : gen_pipe_reg
                reg [(OUT_W * WIDTH) - 1 : 0] stage_reg;
                always @(posedge clk)
                    stage_reg <= comb;
                assign data = stage_reg;
            end else begin : gen_no_pipe_reg
                assign data = comb;
            end
        end

        // -----------------------------------------------------------
        // Output register (with merge logic)
        // -----------------------------------------------------------
        // When the tree depth is an exact multiple of REG_PERIOD the
        // last addition stage already has a pipeline register.  In
        // that case REG_OUT is merged (no extra register) to avoid
        // adding a redundant clock cycle.
        // -----------------------------------------------------------
        localparam bit LAST_HAS_REG = (REG_PERIOD == 0) ? 1'b0
                                    : ((NUM_STAGES % REG_PERIOD) == 0);

        localparam bit NEED_OUT_REG = REG_OUT & ~LAST_HAS_REG;

        if (NEED_OUT_REG) begin : gen_reg_out
            reg [WIDTH-1:0] out_reg;
            always @(posedge clk)
                out_reg <= gen_stage[NUM_STAGES-1].data[WIDTH-1:0];
            assign o_c = out_reg;
        end else begin : gen_no_reg_out
            assign o_c = gen_stage[NUM_STAGES-1].data[WIDTH-1:0];
        end

    end // gen_tree
    endgenerate

endmodule