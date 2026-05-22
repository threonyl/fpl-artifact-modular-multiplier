// --------------------------------------------------------------
// Module  : modacc
// Purpose : Modular accumulator - computes the sum of N operands
//           modulo q.
//
//     o_c = (i_a[0] + i_a[1] + ... + i_a[N-1]) mod q
//
// Two modulus modes:
//
//   FIXED_Q = 0 (default):
//     q is the run-time input i_q.  A delay chain propagates q
//     alongside the data through every pipeline stage.
//
//   FIXED_Q = 1:
//     q is the compile-time constant Q_VALUE.  The i_q port is
//     ignored and all q delay chains are eliminated.  Every
//     subtractor sees a constant operand, allowing the synthesiser
//     to heavily optimise the carry chains.
//
// Two operating modes, selected by USE_ADDTREE:
//
//   USE_ADDTREE = 0 (default, legacy):
//     Binary reduction tree of modadd cells.  Each tree level
//     fuses a pair-wise addition with modular reduction.
//     Pipeline depth = num_stages(N) x modadd_latency.
//
//   USE_ADDTREE = 1:
//     Phase 1 - Unreduced summation via addtree (supports CSA
//               compression and parametric pipeline registers).
//               Operands are zero-extended to SUM_W bits to
//               preserve the full sum without overflow.
//
//     Phase 2 - Binary-search conditional subtraction chain.
//               Iteratively subtracts 2^k * q for k = K-1 ... 0,
//               where K = clog2(MAX_COND_SUB + 1), to bring the
//               sum into [0, q-1].
//
//               When FIXED_Q = 1 each 2^k * Q_VALUE is a compile-
//               time constant, so the subtractors and comparators
//               are significantly simplified by synthesis.
//
//               Example (MAX_COND_SUB = 12, K = 4):
//                 if val >= 8q then val -= 8q
//                 if val >= 4q then val -= 4q
//                 if val >= 2q then val -= 2q
//                 if val >= 1q then val -= 1q
//
//               Pipeline registers in the chain are controlled by
//               CS_REG_PERIOD (same convention as addtree).
//
// Pipeline (USE_ADDTREE = 1):
//
//   i_a --[zero-ext]--> addtree ---> cond-sub chain --> o_c
//                       AT_LAT          CS_LAT
//
//   FIXED_Q=0:  i_q --[delay: AT_LAT]---> q propagates through chain
//   FIXED_Q=1:  (no q datapath, constant used directly)
//
// Author : Selim Kirbiyik, TU Graz
// --------------------------------------------------------------

module modacc
    import modacc_pkg::*;
    import addtree_pkg::*;
    import modadd_pkg::*;
#(
    parameter int unsigned LOGQ        = 398,
    parameter int unsigned NUM_INPUTS  = 23,
    // -- Legacy-mode parameters (modadd tree) -------------------
    parameter bit          REG_IN      = 1,
    parameter bit          REG_OUT     = 1,
    parameter bit          REG_ADD     = 1,
    parameter bit          CONC_ADDSUB = 0,
    // -- Mode selection -----------------------------------------
    parameter bit          USE_ADDTREE = 1, // Use this otherwise clock cycle latency will be double!
    // -- Addtree-mode parameters --------------------------------
    //    MAX_COND_SUB: maximum quotient floor(sum / q) that can
    //    occur.  Typically NUM_INPUTS - 1.  The conditional-
    //    subtraction chain has clog2(MAX_COND_SUB + 1) stages.
    parameter int unsigned MAX_COND_SUB   = NUM_INPUTS - 1,
    // -- Addtree configuration ----------------------------------
    parameter int unsigned AT_REG_PERIOD  = 1,
    parameter bit          AT_REG_IN      = 1,
    parameter bit          AT_REG_OUT     = 1,
    parameter bit          AT_USE_CSA     = 1,
    // -- Conditional-subtraction chain configuration ------------
    //    CS_REG_PERIOD = 0  -> purely combinational chain
    //    CS_REG_PERIOD = 1  -> register after every stage
    //    CS_REG_PERIOD = N  -> register after every N-th stage
    //    CS_REG_OUT merges with the last intermediate register
    //    when NUM_CS is an exact multiple of CS_REG_PERIOD.
    parameter int unsigned CS_REG_PERIOD  = 1,
    parameter bit          CS_REG_OUT     = 1,
    // -- Split final binary adder in the addtree --
    //    When AT_FF_ADD = 1 the addtree's final carry-propagate
    //    addition is split at the CARRY8-aligned midpoint, inserting
    //    one pipeline register.  Costs +1 clock cycle on the
    //    addtree latency but breaks the wide carry chain.
    parameter bit          AT_FF_ADD      = 1,
    // -- Fixed-modulus mode -------------------------------------
    //    When FIXED_Q = 1 the modulus is the compile-time constant
    //    Q_VALUE.  The i_q port is ignored and all q delay chains
    //    are eliminated, saving area and improving timing.
    parameter bit              FIXED_Q    = 0,
    parameter bit [LOGQ-1:0]   Q_VALUE    = '0
) (
    input                                     clk,
    input      [(NUM_INPUTS * LOGQ) - 1 : 0] i_a,  // N operands, each LOGQ bits, packed LE
    input      [               LOGQ - 1 : 0] i_q,  // modulus (ignored when FIXED_Q = 1)
    output     [               LOGQ - 1 : 0] o_c   // result: sum of all operands mod q
);

    // -- Effective modulus --------------------------------------
    wire [LOGQ-1:0] q_eff;
    generate
    if (FIXED_Q) begin : gen_q_fixed
        assign q_eff = Q_VALUE;
    end else begin : gen_q_variable
        assign q_eff = i_q;
    end
    endgenerate

    // -- Derived constants (addtree mode) -----------------------
    localparam int unsigned SUM_EXTRA = modacc_pkg::sum_extra_bits(NUM_INPUTS);
    localparam int unsigned SUM_W     = LOGQ + SUM_EXTRA;
    localparam int unsigned NUM_CS    = modacc_pkg::num_cond_sub_stages(MAX_COND_SUB);

    // -- Latency (exposed for testbench use) --------------------
    localparam int unsigned LATENCY = modacc_pkg::modacc_latency(
        NUM_INPUTS, REG_IN, REG_OUT, REG_ADD, CONC_ADDSUB,
        USE_ADDTREE, MAX_COND_SUB,
        AT_REG_PERIOD, AT_REG_IN, AT_REG_OUT, AT_USE_CSA,
        CS_REG_PERIOD, CS_REG_OUT,
        AT_FF_ADD
    );

    // =============================================================
    // Addtree + conditional-subtraction mode
    // =============================================================
    generate
    if (USE_ADDTREE) begin : gen_addtree_mode

        // Addtree latency for q delay calculation.
        localparam int unsigned AT_LAT = addtree_pkg::addtree_latency(
            NUM_INPUTS, AT_REG_PERIOD, AT_REG_IN, AT_REG_OUT, AT_USE_CSA,
            AT_FF_ADD
        );

        // ---------------------------------------------------------
        // Phase 1: Unreduced sum via addtree
        // ---------------------------------------------------------
        // Zero-extend each LOGQ-bit operand to SUM_W bits to
        // prevent overflow.  The addtree output width equals SUM_W.
        // ---------------------------------------------------------
        wire [(NUM_INPUTS * SUM_W) - 1 : 0] sum_in;

        for (genvar k = 0; k < NUM_INPUTS; k = k + 1) begin : gen_zext
            assign sum_in[((k + 1) * SUM_W) - 1 -: SUM_W] =
                {{SUM_EXTRA{1'b0}}, i_a[((k + 1) * LOGQ) - 1 -: LOGQ]};
        end

        wire [SUM_W-1:0] sum_raw;

        addtree #(
            .WIDTH      (SUM_W),
            .NUM_INPUTS (NUM_INPUTS),
            .REG_PERIOD (AT_REG_PERIOD),
            .REG_IN     (AT_REG_IN),
            .REG_OUT    (AT_REG_OUT),
            .USE_CSA    (AT_USE_CSA),
            .FF_ADD     (AT_FF_ADD)
        ) u_addtree (
            .clk (clk),
            .i_a (sum_in),
            .o_c (sum_raw)
        );

        // ---------------------------------------------------------
        // q delay: align q_eff with the addtree output (AT_LAT cycles)
        // ---------------------------------------------------------
        // When FIXED_Q = 1 the modulus is a constant and needs no
        // delay chain, the synthesiser sees a static value.
        // ---------------------------------------------------------
        wire [LOGQ-1:0] q_at;

        if (FIXED_Q) begin : gen_qat_fixed
            // Constant, no delay needed.
            assign q_at = Q_VALUE;

        end else if (AT_LAT == 0) begin : gen_qat_nodel
            assign q_at = q_eff;
        end else if (AT_LAT == 1) begin : gen_qat_one
            reg [LOGQ-1:0] qat_r;
            always_ff @(posedge clk) qat_r <= q_eff;
            assign q_at = qat_r;
        end else begin : gen_qat_del
            // SRL-friendly delay line (not on the critical path yet;
            // critical path starts at the cond-sub chain).
            (* shreg_extract = "yes", srl_style = "srl_reg" *)
            reg [LOGQ-1:0] qat_sr [0:AT_LAT-2];

            reg [LOGQ-1:0] qat_out;

            always_ff @(posedge clk) qat_sr[0] <= q_eff;
            for (genvar d = 1; d < AT_LAT - 1; d++) begin : gen_qat_sr
                always_ff @(posedge clk) qat_sr[d] <= qat_sr[d-1];
            end
            always_ff @(posedge clk) qat_out <= qat_sr[AT_LAT-2];
            assign q_at = qat_out;
        end

        // ---------------------------------------------------------
        // Phase 2: Binary-search conditional subtraction chain
        // ---------------------------------------------------------
        // Stage s subtracts  2^(NUM_CS - 1 - s) * q  if the current
        // value is large enough.  When FIXED_Q = 1 each shifted q
        // is a compile-time constant, so the subtractor carry chain
        // is simplified by synthesis (constant bits that are 0 need
        // no full-adder logic).
        //
        // When FIXED_Q = 0, q propagates alongside val through the
        // chain so that pipeline registers keep them aligned.
        // ---------------------------------------------------------

        if (NUM_CS == 0) begin : gen_no_cs
            // MAX_COND_SUB = 0 : no conditional subtraction needed.
            assign o_c = sum_raw[LOGQ-1:0];

        end else begin : gen_cs_chain

            for (genvar s = 0; s < NUM_CS; s++) begin : gen_cs_stage
                localparam int unsigned SHIFT = NUM_CS - 1 - s;

                // Pipeline register at this stage?
                localparam bit HAS_REG = (CS_REG_PERIOD == 0) ? 1'b0
                                       : (((s + 1) % CS_REG_PERIOD) == 0);

                // -- Stage outputs (registered or combinational) --
                wire [SUM_W-1:0] val_out;
                wire [LOGQ-1:0]  q_out;

                // -- Stage inputs --
                wire [SUM_W-1:0] val_in;
                wire [LOGQ-1:0]  q_in;

                if (s == 0) begin : gen_first_in
                    assign val_in = sum_raw;
                    assign q_in   = q_at;
                end else begin : gen_chain_in
                    assign val_in = gen_cs_stage[s-1].val_out;
                    assign q_in   = gen_cs_stage[s-1].q_out;
                end

                // -- Conditional subtraction logic --
                // q_ext is zero-extended to SUM_W+1 bits, then
                // statically shifted left by SHIFT bits.  The
                // subtraction produces a SUM_W+1-bit result whose
                // MSB serves as a borrow / sign indicator.
                //
                // When FIXED_Q = 1, q_shifted is a compile-time
                // constant (Q_VALUE << SHIFT), enabling the synth
                // tool to optimise away constant-0 bit positions
                // in the subtractor.
                wire [SUM_W:0] q_ext     = {{(SUM_W + 1 - LOGQ){1'b0}}, q_in};
                wire [SUM_W:0] q_shifted = q_ext << SHIFT;
                wire [SUM_W:0] diff      = {1'b0, val_in} - q_shifted;

                wire [SUM_W-1:0] val_comb = diff[SUM_W] ? val_in
                                                        : diff[SUM_W-1:0];


                if (HAS_REG) begin : gen_cs_reg
                    reg [SUM_W-1:0] val_r;
                    always_ff @(posedge clk) val_r <= val_comb;
                    assign val_out = val_r;

                    // q propagation: only needed when variable
                    if (FIXED_Q) begin : gen_cs_q_fixed
                        assign q_out = Q_VALUE;
                    end else begin : gen_cs_q_reg
                        (* shreg_extract = "no" *)
                        reg [LOGQ-1:0] q_r;
                        always_ff @(posedge clk) q_r <= q_in;
                        assign q_out = q_r;
                    end
                end else begin : gen_cs_noreg
                    assign val_out = val_comb;
                    assign q_out   = FIXED_Q ? Q_VALUE : q_in;
                end
            end // gen_cs_stage

            // ---------------------------------------------------------
            // Output register (with merge logic)
            // ---------------------------------------------------------
            // Merged with the last intermediate register when NUM_CS
            // is an exact multiple of CS_REG_PERIOD, avoiding a
            // redundant clock cycle.
            // ---------------------------------------------------------
            localparam bit LAST_HAS_REG = (CS_REG_PERIOD == 0) ? 1'b0
                                        : ((NUM_CS % CS_REG_PERIOD) == 0);

            localparam bit NEED_OUT_REG = CS_REG_OUT & ~LAST_HAS_REG;

            wire [SUM_W-1:0] cs_result = gen_cs_stage[NUM_CS-1].val_out;

            if (NEED_OUT_REG) begin : gen_cs_reg_out
                reg [LOGQ-1:0] out_reg;
                always_ff @(posedge clk)
                    out_reg <= cs_result[LOGQ-1:0];
                assign o_c = out_reg;
            end else begin : gen_cs_no_reg_out
                assign o_c = cs_result[LOGQ-1:0];
            end

        end // gen_cs_chain

    // =============================================================
    // Legacy mode: binary reduction tree of modadd cells
    // =============================================================
    end else begin : gen_legacy_mode

        localparam int unsigned NUM_STAGES = modacc_pkg::num_stages(NUM_INPUTS);
        localparam int unsigned MODADD_LAT = modadd_pkg::modadd_latency(
            REG_IN, REG_OUT, REG_ADD, CONC_ADDSUB
        );

        // -----------------------------------------------------------
        // Trivial case: 0 or 1 input - nothing to add
        // -----------------------------------------------------------
        if (NUM_INPUTS <= 1) begin : gen_passthrough
            assign o_c = i_a[LOGQ-1:0];

        end else begin : gen_tree

            // -------------------------------------------------------
            // Modulus delay chain
            // -------------------------------------------------------
            // When FIXED_Q = 1 the modulus is a compile-time constant.
            // No delay chain is needed; every stage receives Q_VALUE
            // directly, saving LOGQ x (NUM_STAGES - 1) x MODADD_LAT
            // flip-flops and eliminating their routing pressure.
            //
            // When FIXED_Q = 0, q_stage[s] provides i_q delayed by
            // exactly s x MODADD_LAT clock cycles so that each tree
            // stage sees the modulus that was presented alongside the
            // i_a operands it is reducing.
            //
            // CRITICAL: shreg_extract = "no" prevents Vivado from
            // auto-inferring SRLs.  SRL16E CLK->Q is ~0.37 ns vs
            // FDRE CLK->Q of ~0.08 ns.  Since q_stage feeds the
            // subtraction carry chain in modadd (the critical path),
            // the 0.29 ns SRL penalty is unacceptable.
            //
            // The output tap has max_fanout so the synthesiser can
            // replicate the FF when it fans out to multiple modadd cells.
            // -----------------------------------------------------------
            wire [LOGQ-1:0] q_stage [0:NUM_STAGES-1];

            if (FIXED_Q) begin : gen_q_fixed_tree
                // Constant modulus: every stage sees Q_VALUE directly.
                for (genvar s = 0; s < NUM_STAGES; s = s + 1) begin : gen_q_const
                    assign q_stage[s] = Q_VALUE;
                end
            end else begin : gen_q_var_tree
                assign q_stage[0] = q_eff;

                for (genvar s = 1; s < NUM_STAGES; s = s + 1) begin : gen_q_delay
                    if (MODADD_LAT == 0) begin : gen_zero_lat
                        // No delay needed.
                        // Assign directly from q_eff
                        assign q_stage[s] = q_eff;

                    end else if (MODADD_LAT == 1) begin : gen_single_lat
                        (* shreg_extract = "no", max_fanout = 16 *)
                        reg [LOGQ-1:0] sr_out;
                        always @(posedge clk)
                            sr_out <= q_stage[s-1];
                        assign q_stage[s] = sr_out;

                    end else begin : gen_shift_reg
                        // Shift register of depth MODADD_LAT.
                        // All stages forced to FFs (no SRLs).
                        (* shreg_extract = "no" *)
                        reg [LOGQ-1:0] sr [0:MODADD_LAT-2];

                        (* shreg_extract = "no", max_fanout = 16 *)
                        reg [LOGQ-1:0] sr_out;

                        always @(posedge clk)
                            sr[0] <= q_stage[s-1];

                        for (genvar d = 1; d < MODADD_LAT - 1; d = d + 1) begin : gen_sr_stage
                            always @(posedge clk)
                                sr[d] <= sr[d-1];
                        end

                        always @(posedge clk)
                            sr_out <= sr[MODADD_LAT-2];

                        assign q_stage[s] = sr_out;
                    end
                end
            end // gen_q_var_tree

            // -----------------------------------------------------------
            // Per-stage output buses
            // -----------------------------------------------------------
            // Each tree stage s has its own packed wire bus holding
            // stage_width(NUM_INPUTS, s+1) results of LOGQ bits each.
            //
            // Within each stage the layout is:
            //   [0 .. N_PAIRS-1]  - outputs of the modadd cells
            //   [N_PAIRS]         - passthrough (only when input count is odd)
            // -----------------------------------------------------------
            for (genvar s = 0; s < NUM_STAGES; s = s + 1) begin : gen_stage
                localparam int unsigned IN_W    = modacc_pkg::stage_width(NUM_INPUTS, s);
                localparam int unsigned OUT_W   = modacc_pkg::stage_width(NUM_INPUTS, s + 1);
                localparam int unsigned N_PAIRS = IN_W / 2;
                localparam bit          HAS_ODD = (IN_W % 2) != 0;

                wire [(OUT_W * LOGQ) - 1 : 0] data;

                // ----- Modular adders for each pair of elements ---------
                for (genvar j = 0; j < N_PAIRS; j = j + 1) begin : gen_cell
                    if (s == 0) begin : gen_first
                        // Stage 0: read operand pairs from the input bus i_a.
                        modadd #(
                            .LOGQ        (LOGQ),
                            .REG_IN      (REG_IN),
                            .REG_OUT     (REG_OUT),
                            .REG_ADD     (REG_ADD),
                            .CONC_ADDSUB (CONC_ADDSUB),
                            .FIXED_Q     (FIXED_Q),
                            .Q_VALUE     (Q_VALUE)
                        ) u_add (
                            .clk (clk),
                            .i_a (i_a [((2*j + 2) * LOGQ) - 1 -: LOGQ]),
                            .i_b (i_a [((2*j + 1) * LOGQ) - 1 -: LOGQ]),
                            .i_q (q_stage[0]),
                            .o_c (data [((j + 1)  * LOGQ) - 1 -: LOGQ])
                        );
                    end else begin : gen_rest
                        // Stages 1+: read from the previous stage's output bus.
                        modadd #(
                            .LOGQ        (LOGQ),
                            .REG_IN      (REG_IN),
                            .REG_OUT     (REG_OUT),
                            .REG_ADD     (REG_ADD),
                            .CONC_ADDSUB (CONC_ADDSUB),
                            .FIXED_Q     (FIXED_Q),
                            .Q_VALUE     (Q_VALUE)
                        ) u_add (
                            .clk (clk),
                            .i_a (gen_stage[s-1].data [((2*j + 2) * LOGQ) - 1 -: LOGQ]),
                            .i_b (gen_stage[s-1].data [((2*j + 1) * LOGQ) - 1 -: LOGQ]),
                            .i_q (q_stage[s]),
                            .o_c (data               [((j + 1)   * LOGQ) - 1 -: LOGQ])
                        );
                    end
                end

                // ----- Passthrough for the unpaired (odd) element -------
                // Pure delay, NOT on critical path.
                // SRL inference is safe and saves area.
                // Only instantiated when IN_W is odd.  A shift register
                // delays the element by MODADD_LAT cycles to match the
                // adder outputs.  Placed at the top of the output bus
                // (index OUT_W-1 = N_PAIRS).
                if (HAS_ODD) begin : gen_odd
                    wire [LOGQ-1:0] odd_in;

                    if (s == 0) begin : gen_odd_first
                        assign odd_in = i_a[(IN_W * LOGQ) - 1 -: LOGQ];
                    end else begin : gen_odd_rest
                        assign odd_in = gen_stage[s-1].data[(IN_W * LOGQ) - 1 -: LOGQ];
                    end

                    if (MODADD_LAT == 0) begin : gen_no_delay
                        assign data[(OUT_W * LOGQ) - 1 -: LOGQ] = odd_in;
                    end else begin : gen_delay
                        (* shreg_extract = "yes", srl_style = "srl_reg" *)
                        reg [LOGQ-1:0] sr [0:MODADD_LAT-1];

                        always @(posedge clk)
                            sr[0] <= odd_in;

                        for (genvar d = 1; d < MODADD_LAT; d = d + 1) begin : gen_sr
                            always @(posedge clk)
                                sr[d] <= sr[d-1];
                        end

                        assign data[(OUT_W * LOGQ) - 1 -: LOGQ] = sr[MODADD_LAT-1];
                    end
                end
            end

            // Final result is the sole element of the last stage.
            assign o_c = gen_stage[NUM_STAGES-1].data[LOGQ-1:0];

        end // gen_tree
    end // gen_legacy_mode
    endgenerate

endmodule