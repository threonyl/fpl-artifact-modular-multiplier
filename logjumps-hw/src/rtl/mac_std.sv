// =====================================================================
//  mac_std - Parameterised Multiply-Accumulate
//
//  Computes   C = A * B            (MODE_E == E_DISABLED)
//             C = A * B + E        (MODE_E == E_ADD)
//             C = A * B - E        (MODE_E == E_SUB)
//
//  Pipeline stages (all independently enabled, USE_CSA required for
//  stages marked *):
//    FF_IN      register inputs
//    FF_MUL     register partial products (DSP output)
//    FF_DIAG  * register diagonal accumulation bins
//    FF_CSA_MID * register mid-CSA: split tree into two phases
//    FF_CSA   * register final CSA output
//    FF_ADD   * register carry-chain midpoint of final addition
//    FF_OUT     register final result
//
//  When FF_CSA_MID is enabled, the N_DIAG diagonal inputs are split
//  into 3 groups.  Each group is independently compressed by a small
//  csa_tree.  The 6 intermediate outputs are registered, then merged
//  by a final csa_tree in the next stage.  This cuts the deepest CSA
//  path roughly in half (4 levels per phase instead of 6 total).
//
// Authors: Tolun Tosun, Sabanci University (2025) [https://github.com/cisec-su/modmul-hdl/blob/7b9e7077b55dc4920d77febcf4b3c2c4ed33c691/src/intmul/mac_std.sv]
//          Selim Kirbiyik, TU Graz (Modified, 23.2.2026)
// =====================================================================

module mac_std
    import mac_std_pkg::*,
           csa_tree_pkg::*,
           dsp_pkg::*;
#(
    parameter int       LOGA    = 384,
    parameter int       LOGB    = 384,
    parameter mode_e_t  MODE_E  = E_DISABLED,
    parameter int       LOGE    = 32,
    parameter bit       FF_IN_A = 1,
    parameter bit       FF_IN_B = 1,
    parameter bit       FF_IN_E = 0,
    parameter bit       FF_MUL  = 1,
    parameter bit       FF_OUT  = 1,
    parameter bit       USE_CSA = 0,
    parameter bit       FF_CSA  = 0,
    parameter bit       FF_DIAG = 0,
    parameter bit       FF_CSA_MID = 0,
    parameter bit       FF_ADD  = 0,
    parameter int       PIPE_DSP = 0,   // 0: use FF_IN/FF_MUL  >0: use dsp_mul
    parameter int       LOGC    = logc('{
        loga:    LOGA,     logb:    LOGB,
        mode_e:  int'(MODE_E), loge: LOGE,
        ff_in_a: int'(FF_IN_A), ff_in_b: int'(FF_IN_B),
        ff_in_e: int'(FF_IN_E), ff_mul:  int'(FF_MUL),
        ff_out:  int'(FF_OUT),  ff_csa:  int'(FF_CSA),
        use_csa: int'(USE_CSA), ff_add:  int'(FF_ADD),
        ff_diag: int'(FF_DIAG), ff_csa_mid: int'(FF_CSA_MID),
        pipe_dsp: PIPE_DSP
    })
)(
    input  logic              clk,
    input  logic [LOGA-1:0]   A,
    input  logic [LOGB-1:0]   B,
    input  logic [LOGE-1:0]   E,
    output logic [LOGC-1:0]   C
);

    // =================================================================
    //  Derived constants
    // =================================================================
    localparam mac_std_params_t PARAMS = '{
        loga:    LOGA,     logb:    LOGB,
        mode_e:  int'(MODE_E), loge:    LOGE,
        ff_in_a: int'(FF_IN_A), ff_in_b: int'(FF_IN_B),
        ff_in_e: int'(FF_IN_E), ff_mul:  int'(FF_MUL),
        ff_out:  int'(FF_OUT),  ff_csa:  int'(FF_CSA),
        use_csa: int'(USE_CSA), ff_add:  int'(FF_ADD),
        ff_diag: int'(FF_DIAG), ff_csa_mid: int'(FF_CSA_MID),
        pipe_dsp: PIPE_DSP
    };

    localparam int LOGD = logd(PARAMS);
    localparam int LAT  = latency(PARAMS);

    localparam int TILE_A_W = dsp_a_width(PARAMS);
    localparam int TILE_B_W = dsp_b_width(PARAMS);
    localparam int N_A      = n_tiles_a(PARAMS);
    localparam int N_B      = n_tiles_b(PARAMS);
    localparam int N_DIAG   = n_diagonals(PARAMS);

    // --- CSA sizing (flat tree) --------------------------------------
    localparam int  CSA_DEPTH   = (MODE_E == E_DISABLED) ? N_DIAG : N_DIAG + 1;
    localparam int  LOGCI       = (MODE_E == E_DISABLED) ? LOGD :
                                  (MODE_E == E_ADD)      ? LOGC - 1 : LOGC;
    localparam int  LOGCO_FLAT  = csa_tree_output_width(LOGCI, CSA_DEPTH);
    localparam bit  CSA_NEG     = (MODE_E == E_SUB) && USE_CSA;

    // --- CSA sizing (split tree: 3 groups) ---------------------------
    //  Group sizes:  base, base, last  where last = N_DIAG - 2*base.
    //  For N_DIAG=36:  12, 12, 12.
    localparam int  N_CSA_GRP   = 3;
    localparam int  GRP_SZ_BASE = N_DIAG / N_CSA_GRP;
    localparam int  GRP_SZ_LAST = N_DIAG - (N_CSA_GRP - 1) * GRP_SZ_BASE;
    localparam int  LOGCO_GRP_B = csa_tree_output_width(LOGCI, (GRP_SZ_BASE > 1) ? GRP_SZ_BASE : 2);
    localparam int  LOGCO_GRP_L = csa_tree_output_width(LOGCI, (GRP_SZ_LAST > 1) ? GRP_SZ_LAST : 2);
    localparam int  LOGCO_GRP   = (LOGCO_GRP_B > LOGCO_GRP_L) ? LOGCO_GRP_B : LOGCO_GRP_L;
    localparam int  N_MERGE_IN  = N_CSA_GRP * 2 + ((MODE_E != E_DISABLED) ? 1 : 0);
    localparam int  LOGCO_SPLIT = csa_tree_output_width(LOGCO_GRP, N_MERGE_IN);

    // --- Active output width -----------------------------------------
    localparam int  LOGCO = (USE_CSA && FF_CSA_MID) ? LOGCO_SPLIT : LOGCO_FLAT;

    // --- Pipelined-adder split (CARRY8 aligned) ----------------------
    localparam int  ADD_SPLIT   = ((LOGCO / 2) + 7) / 8 * 8;
    localparam int  ADD_UPPER_W = LOGCO - ADD_SPLIT;


    // =================================================================
    //  Signal declarations
    // =================================================================

    // --- Input tiles -------------------------------------------------
    logic [TILE_A_W-1:0] a_tile     [N_A];
    logic [TILE_A_W-1:0] a_tile_q   [N_A];
    logic [TILE_A_W-1:0] a_tile_mux [N_A];

    logic [TILE_B_W-1:0] b_tile     [N_B];
    logic [TILE_B_W-1:0] b_tile_q   [N_B];
    logic [TILE_B_W-1:0] b_tile_mux [N_B];

// --- E-input pipeline (up to 4 shadow stages) --------------------
    //
    //  The E operand must arrive at the summation/CSA input at the
    //  same cycle as the diagonal data it combines with.  Every
    //  pipeline register inserted on the data path (FF_MUL, FF_DIAG,
    //  FF_CSA_MID) therefore needs a matching "shadow" register on
    //  the E path to keep the two aligned.
    //
    //  Two parallel tracks exist because E_SUB with USE_CSA negates
    //  E early (at the IN stage) and propagates the wide negated
    //  value through the CSA tree, while E_ADD just delays the
    //  narrow E until the summation point.
    //
    //  Narrow E track (E_ADD / E_SUB without CSA):
    //
    //    E --[FF_IN_E]--> e_stg0 --[FF_MUL]--> e_stg1
    //                                             |
    //                                       [FF_DIAG]
    //                                             |
    //                                           e_stg2 --[FF_CSA_MID]--> e_stg3
    //                                                                       |
    //                                                                   to CSA / adder
    //
    //  Wide negated track (E_SUB with USE_CSA, i.e. CSA_NEG = 1):
    //
    //    E --> -E = e_neg_comb --[FF_MUL]--> e_neg_mux
    //                                           |
    //                                      [FF_DIAG]
    //                                           |
    //                                      e_neg_diag_mux --[FF_CSA_MID]--> e_neg_merge_mux
    //                                                                            |
    //                                                                        to CSA input
    //
    //  Signal naming convention:
    //    *_q   : registered (flip-flop) output
    //    *_mux : selected value after the FF_* bypass mux
    //           (equals *_q when the stage is enabled, else
    //            the combinational input from the prior stage)
    //

    // Narrow E shadow registers (LOGE-wide, one per pipeline stage)
    logic [LOGE-1:0]  e_stg0, e_stg0_q;          // after FF_IN_E
    logic [LOGE-1:0]  e_stg1, e_stg1_q;          // after FF_MUL
    logic [LOGE-1:0]  e_stg2, e_stg2_q;          // after FF_DIAG
    logic [LOGE-1:0]  e_stg3, e_stg3_q;          // after FF_CSA_MID

    // Wide negated-E shadow registers (LOGCI-wide, CSA_NEG path only)
    logic [LOGCI-1:0] e_neg_comb;                 // -E, computed at IN stage
    logic [LOGCI-1:0] e_neg_q,       e_neg_mux;       // after FF_MUL
    logic [LOGCI-1:0] e_neg_diag_q,  e_neg_diag_mux;  // after FF_DIAG
    logic [LOGCI-1:0] e_neg_merge_q, e_neg_merge_mux; // after FF_CSA_MID

    // --- Partial products --------------------------------------------
    (* use_dsp = "yes" *)
    logic [DSP_M_U-1:0] pp_comb [N_A][N_B];
    logic [DSP_M_U-1:0] pp_q    [N_A][N_B];
    logic [DSP_M_U-1:0] pp_mux  [N_A][N_B];

    // --- Diagonal bins -----------------------------------------------
    logic [LOGD-1:0] diag     [N_DIAG];
    logic [LOGD-1:0] diag_q   [N_DIAG];
    logic [LOGD-1:0] diag_mux [N_DIAG];

    // --- CSA tree outputs (width = LOGCO, active path dependent) -----
    logic [LOGCO-1:0] csa_out     [2];
    logic [LOGCO-1:0] csa_out_q   [2];
    logic [LOGCO-1:0] csa_out_mux [2];

    // --- Split-CSA mid-pipeline (phase 1 outputs) --------------------
    logic [LOGCO_GRP-1:0] csa_mid     [N_CSA_GRP * 2];
    logic [LOGCO_GRP-1:0] csa_mid_q   [N_CSA_GRP * 2];
    logic [LOGCO_GRP-1:0] csa_mid_mux [N_CSA_GRP * 2];

    // --- Final sum ---------------------------------------------------
    (* use_dsp = "no" *)
    logic [LOGC-1:0] sum_comb;
    logic [LOGC-1:0] sum_q;

    // --- Pipelined adder intermediates -------------------------------
    logic [ADD_SPLIT:0]       add_lo_full;
    logic [ADD_SPLIT-1:0]     add_lo_q;
    logic                     add_carry_q;
    (* max_fanout = 16 *)
    logic [ADD_UPPER_W-1:0]   add_upper_0_q;
    (* max_fanout = 16 *)
    logic [ADD_UPPER_W-1:0]   add_upper_1_q;

    // --- Simple (non-CSA) accumulator --------------------------------
    logic [LOGC-1:0] diag_sum;


    // =================================================================
    //  1. Partition operands into DSP-sized tiles
    // =================================================================
    for (genvar gi = 0; gi < N_A; gi++) begin : gen_a_tile
        if (gi == N_A - 1) begin : gen_last
            assign a_tile[gi] = TILE_A_W'(A >> (TILE_A_W*gi));
        end else begin : gen_mid
            assign a_tile[gi] = A[TILE_A_W*gi +: TILE_A_W];
        end
    end

    for (genvar gi = 0; gi < N_B; gi++) begin : gen_b_tile
        if (gi == N_B - 1) begin : gen_last
            assign b_tile[gi] = TILE_B_W'(B >> (TILE_B_W*gi));
        end else begin : gen_mid
            assign b_tile[gi] = B[TILE_B_W*gi +: TILE_B_W];
        end
    end


    // =================================================================
    //  2. Pipeline muxes  (FF_* ? registered : combinational)
    // =================================================================

    // --- A / B input registers ---------------------------------------
    for (genvar gi = 0; gi < N_A; gi++) begin : gen_a_mux
        assign a_tile_mux[gi] = FF_IN_A ? a_tile_q[gi] : a_tile[gi];
    end
    for (genvar gi = 0; gi < N_B; gi++) begin : gen_b_mux
        assign b_tile_mux[gi] = FF_IN_B ? b_tile_q[gi] : b_tile[gi];
    end

    // --- E input register --------------------------------------------
    if (MODE_E != E_DISABLED) begin : gen_e_stg0_mux
        assign e_stg0 = FF_IN_E ? e_stg0_q : E;
    end

    // --- Partial-product registers -----------------------------------
    //     When PIPE_DSP > 0, dsp_mul output is already pipelined;
    //     bypass the FF_MUL fabric register.
    for (genvar gi = 0; gi < N_A; gi++) begin : gen_pp_mux_a
        for (genvar gj = 0; gj < N_B; gj++) begin : gen_pp_mux_b
            if (PIPE_DSP > 0) begin : gen_pp_bypass
                assign pp_mux[gi][gj] = pp_comb[gi][gj];
            end else begin : gen_pp_fabric
                assign pp_mux[gi][gj] = FF_MUL ? pp_q[gi][gj] : pp_comb[gi][gj];
            end
        end
    end

    // --- E multiply-stage register -----------------------------------
    if (MODE_E != E_DISABLED) begin : gen_e_stg1_mux
        if (CSA_NEG) begin : gen_neg
            assign e_neg_mux = FF_MUL ? e_neg_q : e_neg_comb;
        end else begin : gen_pass
            assign e_stg1 = FF_MUL ? e_stg1_q : e_stg0;
        end
    end

    if (MODE_E != E_DISABLED) begin : gen_e_diag_mux
        if (CSA_NEG) begin : gen_neg
            assign e_neg_diag_mux = FF_DIAG ? e_neg_diag_q : e_neg_mux;
        end else begin : gen_pass
            assign e_stg2 = FF_DIAG ? e_stg2_q : e_stg1;
        end
    end

    if (MODE_E != E_DISABLED) begin : gen_e_merge_mux
        if (CSA_NEG) begin : gen_neg
            assign e_neg_merge_mux = FF_CSA_MID ? e_neg_merge_q : e_neg_diag_mux;
        end else begin : gen_pass
            assign e_stg3 = FF_CSA_MID ? e_stg3_q : e_stg2;
        end
    end

    for (genvar gi = 0; gi < N_DIAG; gi++) begin : gen_diag_mux
        assign diag_mux[gi] = FF_DIAG ? diag_q[gi] : diag[gi];
    end

    for (genvar gi = 0; gi < N_CSA_GRP * 2; gi++) begin : gen_csa_mid_mux
        assign csa_mid_mux[gi] = FF_CSA_MID ? csa_mid_q[gi] : csa_mid[gi];
    end

    // --- CSA output registers ----------------------------------------
    if (USE_CSA) begin : gen_csa_out_mux
        for (genvar gi = 0; gi < 2; gi++) begin : gen_csa_mux_i
            assign csa_out_mux[gi] = FF_CSA ? csa_out_q[gi] : csa_out[gi];
        end
    end

    // --- Output register ---------------------------------------------
    assign C = FF_OUT ? sum_q : sum_comb;


    // =================================================================
    //  3. DSP multiplication
    //
    //  PIPE_DSP == 0 (default):
    //    Combinational multiply; pipelining via fabric FF_IN/FF_MUL.
    //
    //  PIPE_DSP > 0:
    //    Each tile uses dsp_mul with explicit DSP48E2 register
    //    control (AREG/BREG/MREG/PREG).  The dsp_mul output is
    //    already fully pipelined, so it feeds pp_mux directly
    //    (FF_IN_A/FF_IN_B/FF_MUL are bypassed).
    // =================================================================
    for (genvar gi = 0; gi < N_A; gi++) begin : gen_mul_a
        for (genvar gj = 0; gj < N_B; gj++) begin : gen_mul_b
            if (PIPE_DSP > 0) begin : gen_dsp_tile
                // Actual chunk width for the last tile (may be narrower)
                localparam int WA_TILE = (gi == N_A - 1)
                    ? LOGA - TILE_A_W * (N_A - 1) : TILE_A_W;
                localparam int WB_TILE = (gj == N_B - 1)
                    ? LOGB - TILE_B_W * (N_B - 1) : TILE_B_W;

                logic [WA_TILE+WB_TILE-1:0] dsp_out;

                dsp_mul #(
                    .WA       (WA_TILE),
                    .WB       (WB_TILE),
                    .PIPE_DSP (PIPE_DSP)
                ) u_dsp (
                    .clk (clk),
                    .a   (a_tile[gi][WA_TILE-1:0]),
                    .b   (b_tile[gj][WB_TILE-1:0]),
                    .p   (dsp_out)
                );

                // dsp_mul output is already pipelined - write
                // directly to pp_comb (bypasses FF_IN/FF_MUL).
                assign pp_comb[gi][gj] = DSP_M_U'(dsp_out);
            end else begin : gen_fabric_mul
                assign pp_comb[gi][gj] = a_tile_mux[gi] * b_tile_mux[gj];
            end
        end
    end


    // =================================================================
    //  4. Optional E negation (for E_SUB through CSA path)
    // =================================================================
    if (CSA_NEG) begin : gen_e_neg
        assign e_neg_comb = -$signed(e_stg0);
    end


    // =================================================================
    //  5. Diagonal accumulation
    //
    //  Each partial product P[i][j] is placed into the diagonal bin
    //  indexed by (i+j) mod N_DIAG, shifted left by the combined
    //  tile offset (i*TILE_A_W + j*TILE_B_W).
    // =================================================================
    for (genvar gi = 0; gi < N_DIAG; gi++) begin : gen_diag_init
        initial diag[gi] = '0;
    end

    always_comb begin
        for (int i = 0; i < N_DIAG; i++)
            diag[i] = '0;

        for (int i = 0; i < N_A; i++) begin
            for (int j = 0; j < N_B; j++) begin
                automatic int shift = i * TILE_A_W + j * TILE_B_W;
                automatic int idx   = (i - j + N_DIAG) % N_DIAG;

                diag[idx] = diag[idx] | (LOGD'(pp_mux[i][j]) << shift);
            end
        end
    end


    // =================================================================
    //  6. Summation - CSA tree path or simple adder tree
    // =================================================================

    if (USE_CSA) begin : gen_csa_path

        // Feed diagonals into CSA inputs
        // =============================================================
        //  6a. Split CSA tree (two registered phases)
        // =============================================================
        if (FF_CSA_MID) begin : gen_split_csa

            // -- Phase 1: three independent group CSA trees ------
            for (genvar g = 0; g < N_CSA_GRP; g++) begin : gen_grp
                localparam int GRP_SZ    = (g < N_CSA_GRP - 1) ? GRP_SZ_BASE : GRP_SZ_LAST;
                localparam int GRP_START = g * GRP_SZ_BASE;
                localparam int GRP_LOGCO = csa_tree_output_width(LOGCI, GRP_SZ);

                logic [LOGCI-1:0]     grp_in  [GRP_SZ];
                logic [GRP_LOGCO-1:0] grp_out [2];

                for (genvar i = 0; i < GRP_SZ; i++) begin : gen_in
                    assign grp_in[i] = diag_mux[GRP_START + i];
                end

                csa_tree #(
                    .INPUT_WIDTH  (LOGCI),
                    .NUM_INPUTS   (GRP_SZ),
                    .OUTPUT_WIDTH (GRP_LOGCO)
                ) u_csa_grp (
                    .operands (grp_in),
                    .result   (grp_out)
                );

                // Zero-extend to common mid-pipeline width
                assign csa_mid[2*g]     = LOGCO_GRP'(grp_out[0]);
                assign csa_mid[2*g + 1] = LOGCO_GRP'(grp_out[1]);
            end

            // -- Phase 2: merge CSA tree -------------------------
            logic [LOGCO_GRP-1:0]  merge_in  [N_MERGE_IN];
            localparam int LOGCO_M = csa_tree_output_width(LOGCO_GRP, N_MERGE_IN);
            logic [LOGCO_M-1:0]    merge_out [2];

            for (genvar i = 0; i < N_CSA_GRP * 2; i++) begin : gen_merge_in
                assign merge_in[i] = csa_mid_mux[i];
            end

            if (MODE_E == E_ADD) begin : gen_merge_e_add
                assign merge_in[N_CSA_GRP * 2] = LOGCO_GRP'(e_stg3);
            end else if (MODE_E == E_SUB) begin : gen_merge_e_sub
                assign merge_in[N_CSA_GRP * 2] = LOGCO_GRP'(e_neg_merge_mux);
            end

            csa_tree #(
                .INPUT_WIDTH  (LOGCO_GRP),
                .NUM_INPUTS   (N_MERGE_IN),
                .OUTPUT_WIDTH (LOGCO_M)
            ) u_csa_merge (
                .operands (merge_in),
                .result   (merge_out)
            );

            // Drive module-scope csa_out (zero-extend to LOGCO)
            assign csa_out[0] = LOGCO'(merge_out[0]);
            assign csa_out[1] = LOGCO'(merge_out[1]);

        // =============================================================
        //  6b. Flat CSA tree (original, single phase)
        // =============================================================
        end else begin : gen_flat_csa

            logic [LOGCI-1:0]       flat_in  [CSA_DEPTH];
            localparam int LOGCO_F = csa_tree_output_width(LOGCI, CSA_DEPTH);
            logic [LOGCO_F-1:0]     flat_out [2];

            for (genvar gi = 0; gi < N_DIAG; gi++) begin : gen_flat_in
                assign flat_in[gi] = diag_mux[gi];
            end

            if (MODE_E == E_ADD) begin : gen_flat_e_add
                assign flat_in[N_DIAG] = LOGCI'(FF_DIAG ? e_stg2 : e_stg1);
            end else if (MODE_E == E_SUB) begin : gen_flat_e_sub
                assign flat_in[N_DIAG] = FF_DIAG ? e_neg_diag_mux : e_neg_mux;
            end

            csa_tree #(
                .INPUT_WIDTH  (LOGCI),
                .NUM_INPUTS   (CSA_DEPTH),
                .OUTPUT_WIDTH (LOGCO_F)
            ) u_csa_tree (
                .operands (flat_in),
                .result   (flat_out)
            );

            assign csa_out[0] = LOGCO'(flat_out[0]);
            assign csa_out[1] = LOGCO'(flat_out[1]);

        end

        // =============================================================
        //  6c. Final addition (shared by split and flat paths)
        // =============================================================
        if (FF_ADD) begin : gen_split_add

            assign add_lo_full = {1'b0, csa_out_mux[0][ADD_SPLIT-1:0]}
                               + {1'b0, csa_out_mux[1][ADD_SPLIT-1:0]};

            logic [ADD_UPPER_W:0] add_hi_full;
            assign add_hi_full = {1'b0, add_upper_0_q}
                               + {1'b0, add_upper_1_q}
                               + {{ADD_UPPER_W{1'b0}}, add_carry_q};

            always_comb
                sum_comb = LOGC'({add_hi_full[ADD_UPPER_W-1:0], add_lo_q});

        end else begin : gen_full_add
            always_comb
                sum_comb = LOGC'(csa_out_mux[0] + csa_out_mux[1]);
        end

    end else begin : gen_simple_path

        // Sum all diagonals
        always_comb begin
            diag_sum = '0;
            for (int i = 0; i < N_DIAG; i++)
                diag_sum = diag_sum + diag_mux[i];
        end

        // Combine with E
        if (MODE_E == E_DISABLED) begin : gen_sum_no_e
            always_comb sum_comb = diag_sum;
        end else if (MODE_E == E_ADD) begin : gen_sum_add_e
            always_comb sum_comb = diag_sum + (FF_DIAG ? e_stg2 : e_stg1);
        end else if (MODE_E == E_SUB) begin : gen_sum_sub_e
            always_comb sum_comb = $signed({1'b0, diag_sum})
                                 - $signed(FF_DIAG ? e_stg2 : e_stg1);
        end
    end


    // =================================================================
    //  7. Sequential logic - pipeline registers
    // =================================================================

    // --- Input stage -------------------------------------------------
    if (FF_IN_A) begin : gen_ff_a
        for (genvar gi = 0; gi < N_A; gi++) begin : gen_ff_a_i
            always_ff @(posedge clk) a_tile_q[gi] <= a_tile[gi];
        end
    end
    if (FF_IN_B) begin : gen_ff_b
        for (genvar gi = 0; gi < N_B; gi++) begin : gen_ff_b_i
            always_ff @(posedge clk) b_tile_q[gi] <= b_tile[gi];
        end
    end
    if (FF_IN_E && MODE_E != E_DISABLED) begin : gen_ff_e_in
        always_ff @(posedge clk) e_stg0_q <= E;
    end

    // --- Multiply stage ----------------------------------------------
    if (FF_MUL) begin : gen_ff_mul
        for (genvar gi = 0; gi < N_A; gi++) begin : gen_ff_mul_a
            for (genvar gj = 0; gj < N_B; gj++) begin : gen_ff_mul_b
                always_ff @(posedge clk) pp_q[gi][gj] <= pp_comb[gi][gj];
            end
        end
        if (CSA_NEG) begin : gen_ff_e_neg
            always_ff @(posedge clk) e_neg_q <= e_neg_comb;
        end else if (MODE_E != E_DISABLED) begin : gen_ff_e_mul
            always_ff @(posedge clk) e_stg1_q <= e_stg0;
        end
    end

    // --- Diagonal stage ----------------------------------------------
    if (FF_DIAG) begin : gen_ff_diag
        for (genvar gi = 0; gi < N_DIAG; gi++) begin : gen_ff_diag_i
            always_ff @(posedge clk) diag_q[gi] <= diag[gi];
        end
        if (CSA_NEG) begin : gen_ff_e_neg_diag
            always_ff @(posedge clk) e_neg_diag_q <= e_neg_mux;
        end else if (MODE_E != E_DISABLED) begin : gen_ff_e_diag
            always_ff @(posedge clk) e_stg2_q <= e_stg1;
        end
    end

    // --- CSA-mid stage (split tree register) -------------------------
    if (FF_CSA_MID) begin : gen_ff_csa_mid
        for (genvar gi = 0; gi < N_CSA_GRP * 2; gi++) begin : gen_ff_mid_i
            always_ff @(posedge clk) csa_mid_q[gi] <= csa_mid[gi];
        end
        if (CSA_NEG) begin : gen_ff_e_neg_merge
            always_ff @(posedge clk) e_neg_merge_q <= e_neg_diag_mux;
        end else if (MODE_E != E_DISABLED) begin : gen_ff_e_merge
            always_ff @(posedge clk) e_stg3_q <= e_stg2;
        end
    end

    // --- CSA output stage --------------------------------------------
    // max_fanout on CSA output registers: these drive the wide
    // sum_comb = csa_out_mux[0] + csa_out_mux[1] addition.  At
    // LOGCO ~ 400+ bits the carry chain has high internal fanout;
    // replicating the source registers reduces net delay into the
    // carry chain inputs.
    if (USE_CSA && FF_CSA) begin : gen_ff_csa
        for (genvar gi = 0; gi < 2; gi++) begin : gen_ff_csa_i
            (* max_fanout = 16 *)
            always_ff @(posedge clk) csa_out_q[gi] <= csa_out[gi];
        end
    end

    // --- Adder-split stage -------------------------------------------
    if (USE_CSA && FF_ADD) begin : gen_ff_add
        always_ff @(posedge clk) begin
            add_lo_q      <= add_lo_full[ADD_SPLIT-1:0];
            add_carry_q   <= add_lo_full[ADD_SPLIT];
            add_upper_0_q <= csa_out_mux[0][LOGCO-1:ADD_SPLIT];
            add_upper_1_q <= csa_out_mux[1][LOGCO-1:ADD_SPLIT];
        end
    end

    // --- Output stage ------------------------------------------------
    if (FF_OUT) begin : gen_ff_out
        always_ff @(posedge clk) sum_q <= sum_comb;
    end

endmodule