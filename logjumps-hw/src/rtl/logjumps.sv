// --------------------------------------------------------------
// Module  : logjumps
// Purpose : Rho-fused parallel-tree LogJumps Montgomery reduction.
//
//   Computes  D = C * 2^{-LOGR} mod q
//
//   where C in [0, (q-1)*(R-1)],  R = 2^{LOGR}. (NOTE! The default setup ONLY supports (and is tested for) C in [0, (q-1)*(q-1)])
//                                               (To remove this limitation just set LOGQ to be LOGR, costing more area.)
//
//   LOGR is the Montgomery constant width: the smallest multiple
//   of LOGW that is >= LOGQ.  Default: LOGW * ceil(LOGQ / LOGW).
//   LOGQ is the actual modulus bit-width (may be < LOGR).
//
// Algorithm (matches parallel_tree_ro_reduce in the Python model):
//
//   1. Split C into  n-1 low limbs  c_lo[0..n-2]  (each LOGW bits)
//      and a high part  c_hi  (2*LOGQ - LOGR + LOGW bits),  where n = LOGR/LOGW.
//
//   2. Compute the parallel dot-product (Path B, wide, slow):
//        raw_sum = sum_{i=0}^{n-2} c_lo[i] * rho[n-1-i]  +  c_hi
//      Reduce raw_sum modulo q*W via the modacc tree -> T_acc.
//
//   3. In parallel, compute the Montgomery quotient from the raw
//      input limbs (Path A, narrow, fast):
//        m_val = ( sum_{i=0}^{n-2} c_lo[i] * rho_mu[i]
//                  + c_hi[LOGW-1:0] * mu )  mod 2^{LOGW}
//      where rho_mu[i] = rho[n-1-i] * mu  mod 2^{LOGW}.
//
//      When FIXED_Q = 0: rho_mu[i] values are computed internally
//      via small intmul_wrapper instances.
//
//      When FIXED_Q = 1: rho_mu[i] values are supplied directly
//      as the compile-time parameter RHO_MU_VALUES, eliminating
//      the N_MUL rho*mu multiplier instances entirely.  Rho, q,
//      mu, and q*W are also hardcoded as constants.
//
//      Then compute the wide product  m_q = m_val * q.
//
//   4. Join: T' = (T_acc + m_q) >> LOGW
//
//   5. Final conditional subtraction:  if T' >= q then T' -= q.
//
// Key insight:
//   Because the modacc tree reduces modulo q*W (a multiple of W),
//   the low LOGW bits of raw_sum are invariant under the tree.
//   Therefore m_val depends only on the *raw input limbs* - not on
//   the tree output.  Each c_lo[i] * rho_mu[i] is a LOGW x LOGW
//   truncated multiply available after the rho*mu multiply latency,
//   letting the expensive m*q multiply (LOGW x LOGQ) overlap with
//   the dot + modacc path.
//
// Pipeline (two parallel paths):
//
//   FIXED_Q = 0 (variable modulus):
//
//   c_lo --+-- dot_mul [DOT_LAT] -- modacc_tree [ACC_LAT] ---------------------[align]--------------+
//          |                                                                                        +-- add+shift -- cond-sub
//          +-- rho*mu_mul [RM_MUL_LAT] -- c*rm_mul --[FF_RM]-- addtree [MVAL_LAT] -- m*q [MR_LAT]---+
//
//   FIXED_Q = 1 (constant modulus, rho*mu multipliers eliminated):
//
//   c_lo --+-- dot_mul [DOT_LAT] -- modacc_tree [ACC_LAT] ---------------------[align]--------------+
//          |                                                                                        +-- add+shift -- cond-sub
//          +-- c*rm_mul --[FF_RM]-- addtree [MVAL_LAT] -- m*q [MR_LAT]---------[align]--------------+
//
//   LAT = max(DOT_LAT + ACC_LAT, RM_MUL_LAT + FF_RM + MVAL_LAT + MR_LAT) + FF_MR_POST + FF_OUT
//
// modacc modes (ACC_USE_ADDTREE):
//   0 - Legacy fused modadd binary tree (default).
//   1 - addtree plain summation (CSA-capable) followed by a
//       binary-search conditional subtraction chain with
//       clog2(ACC_MAX_COND_SUB + 1) stages.
//
// Constraints:
//   - LOGR must be an exact multiple of LOGW (guaranteed by default).
//   - LOGR must be >= LOGQ.
//
// Author : Selim Kirbiyik, TU Graz (27.2.2026)
// --------------------------------------------------------------

module logjumps
    import dsp_pkg::*;
    import intmul_wrapper_pkg::*;
    import modadd_pkg::*;
    import modacc_pkg::*;
    import logjumps_pkg::*;
    import addtree_pkg::*;
#(
    parameter int LOGW       = 17,
    parameter int LOGQ       = 381,
    parameter int LOGR       = LOGW * ((LOGQ + LOGW - 1) / LOGW),
    parameter bit FF_IN      = 1,
    parameter bit FF_MUL     = 1,
    parameter bit FF_OUT     = 1,
    parameter bit USE_CSA    = 1,
    parameter bit FF_CSA     = 1,
    parameter bit FF_DIAG    = 0,
    parameter bit FF_CSA_MID = 1,
    parameter bit FF_ADD     = 1,
    parameter bit MORE_DSP   = 1,
    parameter bit NON_STD    = 0,
    // Pipeline register between the MR multiplier output and the
    // final conditional subtraction.  When enabled (1), the wide
    // add+shift is registered before the subtract+mux, breaking
    // the critical path at the cost of one extra cycle of latency.
    parameter bit FF_MR_POST = 1,
    // Split the wide T_acc + m_q join addition at the CARRY8-
    // aligned midpoint.  Registers the lower-half result, carry-
    // out, and the two upper operand halves.  The upper-half
    // addition completes combinationally in the next cycle.
    // Independent of FF_MR_POST; costs +1 cycle of latency.
    //
    //   FF_JOIN_ADD=0, FF_MR_POST=1: original (full add -> reg -> sub)
    //   FF_JOIN_ADD=1, FF_MR_POST=1: split add -> upper+shift -> reg -> sub
    //   FF_JOIN_ADD=1, FF_MR_POST=0: split add -> upper+shift+sub -> FF_OUT
    parameter bit FF_JOIN_ADD = 1,
    // Map the small LOGW x LOGW Montgomery constant multiply
    // (m_val = T_lo * mu) to a DSP primitive instead of LUTs.
    // Also controls the rho_mu product DSP mapping and the
    // internal rho*mu computation DSP mapping (when FIXED_Q = 0).
    parameter bit DSP_SMALL  = 1,
    // Register the LOGW x LOGW rho_mu product outputs before
    // they enter the addition tree.  Breaks the multiply -> adder
    // path at the cost of one extra cycle on Path A.
    parameter bit FF_RM      = 0,
    // -- m_val addition tree (addtree) pipeline parameters ---
    // Controls pipelining of the LOGW-wide binary reduction tree
    // that sums the N_LIMBS truncated rho_mu products into m_val.
    //   MT_REG_PERIOD = 0  -> purely combinational tree
    //   MT_REG_PERIOD = 1  -> register after every addition level
    //   MT_REG_PERIOD = N  -> register after every N-th level
    // MT_REG_IN / MT_REG_OUT add input / output pipeline stages.
    // See addtree for full semantics (including REG_OUT merge).
    parameter int MT_REG_PERIOD = 2,
    parameter bit MT_REG_IN     = 1,
    parameter bit MT_REG_OUT    = 1,
    // Carry-save compression mode for the m_val addition tree.
    //   MT_USE_CSA = 0  -> binary reduction (default, matches original)
    //   MT_USE_CSA = 1  -> carry-save 3-to-2 compression + final adder
    // See addtree for full semantics.
    parameter bit MT_USE_CSA    = 1,
    // Split the m_val addtree's final binary adder at the CARRY8-
    // aligned midpoint.  Only effective when MT_USE_CSA = 1 and
    // N_LIMBS > 2.  Costs +1 clock cycle on Path A (MVAL_LAT
    // increases by 1).  See addtree for full semantics.
    parameter bit MT_FF_ADD     = 1,

    // =============================================================
    // modacc mode selection and configuration
    // =============================================================
    //
    //   ACC_USE_ADDTREE = 0 (default):
    //     Legacy binary reduction tree of fused modadd cells.
    //     ACC_AT_* and ACC_CS_* parameters are ignored; the tree
    //     uses the fixed constants in logjumps_pkg (ACC_REG_IN,
    //     ACC_REG_OUT, ACC_REG_ADD, ACC_CONC_ADDSUB).
    //
    //   ACC_USE_ADDTREE = 1:
    //     Phase 1 - Plain addtree summation (CSA-capable).
    //     Phase 2 - Binary-search conditional subtraction chain
    //               that subtracts 2^k * q for k = K-1 down to 0,
    //               where K = clog2(ACC_MAX_COND_SUB + 1).
    //
    //     Example (ACC_MAX_COND_SUB = 12, K = 4):
    //       Stage 0: if val >= 8q then val -= 8q
    //       Stage 1: if val >= 4q then val -= 4q
    //       Stage 2: if val >= 2q then val -= 2q
    //       Stage 3: if val >= 1q then val -= 1q
    //
    // -- Mode switch ---
    parameter bit ACC_USE_ADDTREE = 1,
    // -- Max conditional subtraction quotient ----------------
    // Determines the number of cond-sub stages:
    //   K = clog2(ACC_MAX_COND_SUB + 1).
    // Must be >= the maximum possible
    //   floor(raw_sum / (q * W))
    // for correctness.  Default N_LIMBS - 1 covers the case
    // where each modacc input is in [0, q*W - 1].
    parameter int ACC_MAX_COND_SUB = LOGR / LOGW - 1,
    // -- Addtree (Phase 1) configuration --------------------
    //   ACC_AT_REG_PERIOD = 0  -> purely combinational
    //   ACC_AT_REG_PERIOD = 1  -> register after every level
    //   ACC_AT_REG_PERIOD = N  -> register after every N-th level
    parameter int ACC_AT_REG_PERIOD = 3,
    parameter bit ACC_AT_REG_IN     = 1,
    parameter bit ACC_AT_REG_OUT    = 1,
    parameter bit ACC_AT_USE_CSA    = 1,
    // -- Cond-sub chain (Phase 2) configuration -------------
    //   ACC_CS_REG_PERIOD = 0  -> purely combinational chain
    //   ACC_CS_REG_PERIOD = 1  -> register after every stage
    //   ACC_CS_REG_PERIOD = N  -> register after every N-th stage
    parameter int ACC_CS_REG_PERIOD = 1,
    parameter bit ACC_CS_REG_OUT    = 1,
    // -- Split the addtree's final binary adder -----------------
    //    When ACC_AT_FF_ADD = 1 the modacc addtree's final carry-
    //    propagate addition is split at the CARRY8-aligned midpoint.
    //    Costs +1 cycle on Path B (ACC_LAT increases by 1).
    parameter bit ACC_AT_FF_ADD     = 1,

    // =============================================================
    // Fixed-modulus mode (FIXED_Q)
    // =============================================================
    //
    //   FIXED_Q = 0 (default):
    //     q, rho, and mu are run-time inputs.  The rho*mu products
    //     are computed internally by N_MUL small intmul_wrapper
    //     multipliers (RM_MUL_LAT cycles on Path A).  All q delay
    //     chains are active.
    //
    //   FIXED_Q = 1:
    //     The modulus and all derived constants are compile-time
    //     parameters.  The run-time ports q, rho, mu are ignored.
    //
    //     Effects:
    //       - q is hardcoded as Q_VALUE everywhere (q delay chains
    //         eliminated, constant folding in subtractors).
    //       - rho values are hardcoded as RHO_VALUES (constant
    //         operand B in the dot-product multipliers).
    //       - mu is hardcoded as MU_VALUE (constant operand in the
    //         c_hi_lo * mu product).
    //       - The N_MUL rho*mu multipliers are eliminated entirely;
    //         pre-computed rho_mu constants are supplied via the
    //         RHO_MU_VALUES parameter, making RM_MUL_LAT = 0.
    //       - The modacc tree receives FIXED_Q = 1 with the
    //         compile-time constant q * W, enabling constant
    //         folding in all its subtractors.
    //
    // -- Mode switch ---
    parameter bit                              FIXED_Q        = 0,
    // -- Compile-time modulus (LOGQ bits) ---
    parameter bit [LOGQ-1:0]                   Q_VALUE        = 0,
    // -- Compile-time Montgomery constant mu = -q^{-1} mod 2^{LOGW} ---
    parameter bit [LOGW-1:0]                   MU_VALUE       = 0,
    // -- Compile-time rho values, packed LE ---
    //    RHO_VALUES[k*LOGQ +: LOGQ] = rho[k+1]  for k = 0 .. N_MUL-1
    //    (same packing as the rho input port)
    parameter bit [(LOGR/LOGW-1)*LOGQ-1:0]     RHO_VALUES     = 0,
    // -- Pre-computed rho_mu constants, packed LE ---
    //    RHO_MU_VALUES[k*LOGW +: LOGW] = (rho[n-1-k] * mu) mod 2^{LOGW}
    //    for k = 0 .. N_MUL-1.  Only used when FIXED_Q = 1.
    parameter bit [(LOGR/LOGW-1)*LOGW-1:0]     RHO_MU_VALUES  = '0
) (
    input  logic                            clk,
    input  logic [2*LOGQ-1:0]               C,      // value to reduce
    input  logic [LOGQ-1:0]                 q,      // modulus (ignored when FIXED_Q = 1)
    input  logic [(LOGR/LOGW-1)*LOGQ-1:0]   rho,    // { rho[n-1], ..., rho[1] } packed LE (ignored when FIXED_Q = 1)
    input  logic [LOGW-1:0]                 mu,     // -q^{-1} mod 2^{LOGW} (ignored when FIXED_Q = 1)
    output logic [LOGQ-1:0]                 D       // C * R^{-1} mod q
);

    // -- Derived constants -----------------------------------
    localparam int N_LIMBS = LOGR / LOGW;           // n
    localparam int N_MUL   = N_LIMBS - 1;           // dot-product multiplier count
    localparam int ACCW    = LOGQ + LOGW;           // width for modacc (mod q*W)

    // -- Effective constant signals --------------------------
    //    When FIXED_Q = 1 these are compile-time constants;
    //    when FIXED_Q = 0 they resolve to the run-time ports.
    wire [LOGQ-1:0]                q_eff;
    wire [LOGW-1:0]                mu_eff;
    wire [(N_MUL)*LOGQ-1:0]       rho_eff;

    if (FIXED_Q) begin : gen_fixed_q_wires
        assign q_eff   = Q_VALUE;
        assign mu_eff  = MU_VALUE;
        assign rho_eff = RHO_VALUES;
    end else begin : gen_var_q_wires
        assign q_eff   = q;
        assign mu_eff  = mu;
        assign rho_eff = rho;
    end

    // -- Compile-time q * W for the modacc tree (ACCW bits) --
    //    Only meaningful when FIXED_Q = 1.
    localparam bit [ACCW-1:0] QW_VALUE = {Q_VALUE, {LOGW{1'b0}}};

    // -- Sub-block latencies ---------------------------------
    localparam int DOT_LAT = logjumps_pkg::dot_mul_latency(
        LOGW, LOGQ, int'(FF_IN), int'(FF_MUL),
        int'(USE_CSA), int'(FF_CSA), int'(MORE_DSP), int'(NON_STD),
        int'(FF_ADD), int'(FF_DIAG), int'(FF_CSA_MID)
    );
    localparam int ACC_LAT = logjumps_pkg::acc_tree_latency(
        LOGW, LOGR,
        int'(ACC_USE_ADDTREE), ACC_MAX_COND_SUB,
        ACC_AT_REG_PERIOD, int'(ACC_AT_REG_IN),
        int'(ACC_AT_REG_OUT), int'(ACC_AT_USE_CSA),
        ACC_CS_REG_PERIOD, int'(ACC_CS_REG_OUT),
        int'(ACC_AT_FF_ADD)
    );
    localparam int MR_LAT  = logjumps_pkg::mr_mul_latency(
        LOGW, LOGQ, int'(FF_IN), int'(FF_MUL),
        int'(USE_CSA), int'(FF_CSA), int'(MORE_DSP), int'(NON_STD),
        int'(FF_ADD), int'(FF_DIAG), int'(FF_CSA_MID),
        int'(FF_MR_POST)
    );
    localparam int MVAL_LAT = logjumps_pkg::mval_tree_latency(
        LOGW, LOGR,
        int'(MT_REG_PERIOD), int'(MT_REG_IN), int'(MT_REG_OUT),
        int'(MT_USE_CSA),
        int'(MT_FF_ADD)
    );
    // When FIXED_Q = 1, RM_MUL_LAT = 0 (rho*mu multipliers eliminated).
    localparam int RM_MUL_LAT = logjumps_pkg::rm_mul_latency(
        LOGW, int'(DSP_SMALL), int'(FIXED_Q)
    );

    // Path latencies for alignment
    localparam int PATH_A = RM_MUL_LAT + int'(FF_RM) + MVAL_LAT + MR_LAT;
    localparam int PATH_B = DOT_LAT + ACC_LAT;                 // dot + modacc path
    localparam int JOIN_CYC = logjumps_pkg::max_int(PATH_A, PATH_B);

    // Extra delay to align paths at the join point
    localparam int MQ_DELAY   = JOIN_CYC - PATH_A;   // >= 0: delay m_q
    localparam int TACC_DELAY = JOIN_CYC - PATH_B;   // >= 0: delay T_acc

    localparam int LAT = logjumps_pkg::logjumps_latency(
        LOGW, LOGQ, LOGR,
        int'(FF_IN), int'(FF_MUL), int'(FF_OUT),
        int'(USE_CSA), int'(FF_CSA), int'(MORE_DSP), int'(NON_STD),
        int'(FF_ADD), int'(FF_DIAG), int'(FF_CSA_MID),
        int'(FF_MR_POST), int'(FF_RM),
        int'(MT_REG_PERIOD), int'(MT_REG_IN), int'(MT_REG_OUT),
        int'(MT_USE_CSA), int'(DSP_SMALL),
        int'(ACC_USE_ADDTREE), ACC_MAX_COND_SUB,
        ACC_AT_REG_PERIOD, int'(ACC_AT_REG_IN),
        int'(ACC_AT_REG_OUT), int'(ACC_AT_USE_CSA),
        ACC_CS_REG_PERIOD, int'(ACC_CS_REG_OUT),
        int'(FIXED_Q),
        int'(ACC_AT_FF_ADD),
        int'(FF_JOIN_ADD),
        int'(MT_FF_ADD)
    );

    // =============================================================
    // Phase 1 - Limb extraction (combinational)
    // =============================================================
    // c_lo[i] = C[ i*LOGW +: LOGW ]   for i = 0 ... n-2
    // c_hi    = C[ 2*LOGQ-1 : (n-1)*LOGW ]   (CHI_RAW bits, zero-extended to ACCW)
    //
    // rho packed LE:  rho_w[k] = rho_eff[ k*LOGQ +: LOGQ ]
    //   rho_w[0] = rho[1],  rho_w[N_MUL-1] = rho[n-1]
    //
    // When FIXED_Q = 1, rho_w[k] resolves to a compile-time
    // constant from RHO_VALUES, giving the synthesiser a
    // constant operand B in every dot-product multiplier.
    // =============================================================
    wire [LOGW-1:0] c_lo     [0:N_MUL-1];
    wire [LOGQ-1:0] rho_w    [0:N_MUL-1];

    for (genvar i = 0; i < N_MUL; i++) begin : gen_c_lo
        assign c_lo[i] = C[i*LOGW +: LOGW];
    end

    localparam int CHI_RAW = 2*LOGQ - N_MUL*LOGW;  // = 2*LOGQ - LOGR + LOGW
    wire [CHI_RAW-1:0] c_hi_raw;
    wire [ACCW-1:0]    c_hi;

    assign c_hi_raw = C[2*LOGQ-1 -: CHI_RAW];
    // Zero-extend to ACCW bits (no-op when LOGR == LOGQ).
    assign c_hi = {{(ACCW - CHI_RAW){1'b0}}, c_hi_raw};

    for (genvar k = 0; k < N_MUL; k++) begin : gen_rho
        assign rho_w[k] = rho_eff[k*LOGQ +: LOGQ];
    end

    // Low LOGW bits of c_hi - available at cycle 0 for Path A.
    wire [LOGW-1:0] c_hi_lo = C[N_MUL*LOGW +: LOGW];

    // =============================================================
    // Phase 2 - Parallel dot-product multiplications  (Path B)
    // =============================================================
    // prod[i] = c_lo[i] x rho_w[N_MUL-1-i]   (LOGW x LOGQ -> ACCW)
    //
    // When FIXED_Q = 1, rho_w[*] are compile-time constants so
    // operand B of each intmul_wrapper is constant, enabling
    // the synthesiser to simplify the multiplier fabric.
    // =============================================================
    wire [ACCW-1:0] prod [0:N_MUL-1];

    for (genvar i = 0; i < N_MUL; i++) begin : gen_dot_mul
        intmul_wrapper #(
            .LOGA           (LOGW      ),
            .LOGB           (LOGQ      ),
            .FF_IN          (FF_IN     ),
            .FF_MUL         (FF_MUL    ),
            .FF_OUT         (1'b1      ),
            .USE_CSA        (USE_CSA   ),
            .FF_CSA         (FF_CSA    ),
            .FF_DIAG        (FF_DIAG   ),
            .FF_CSA_MID     (FF_CSA_MID),
            .FF_ADD         (FF_ADD    ),
            .MORE_DSP       (MORE_DSP  ),
            .NON_STD        (NON_STD   ),
            .USE_KARATSUBA  (0         ),
            .K_PIPE_DSP     (0         ),
            .K_PIPE_PRE     (0         ),
            .K_PIPE_POST    (0         ),
            .K_PIPE_MID     (0         )
        ) u_dot_mul (
            .clk (clk),
            .A   (c_lo[i]),
            .B   (rho_w[N_MUL - 1 - i]),
            .C   (prod[i])
        );
    end

    // =============================================================
    // Phase 3 - Rho-fused Montgomery quotient  (Path A)
    // =============================================================
    // Computes m_val from raw input limbs, in parallel with Phase 2.
    //
    //   m_val = ( sum_{i} c_lo[i] * rho_mu_w[i]
    //             + c_hi_lo * mu )  mod 2^{LOGW}
    //
    // When FIXED_Q = 0:
    //   The rho_mu constants are computed internally:
    //     rho_mu_w[k] = ( rho[n-1-k] * mu ) mod 2^{LOGW}
    //                = ( rho_w[N_MUL-1-k][LOGW-1:0] * mu ) mod 2^{LOGW}
    //   Each rho*mu product uses a small LOGW x LOGW intmul_wrapper,
    //   adding RM_MUL_LAT cycles to Path A.  The c_lo limbs and the
    //   c_hi_lo * mu product are delayed to match.
    //
    // When FIXED_Q = 1:
    //   rho_mu_w[k] are compile-time constants from RHO_MU_VALUES.
    //   No intmul_wrapper instances are generated.  RM_MUL_LAT = 0,
    //   so no c_lo or chi_mu delay is needed for alignment.
    // =============================================================

    wire [LOGW-1:0] rho_mu_w [0:N_MUL-1];

    // -- Step 3a: Obtain rho_mu values -----------------------
    //   FIXED_Q = 0: Compute via intmul_wrapper (rho_lo[k] * mu)
    //   FIXED_Q = 1: Constant from RHO_MU_VALUES parameter

    if (FIXED_Q) begin : gen_rho_mu_fixed
        // Pre-computed rho_mu constants, no multipliers needed.
        for (genvar k = 0; k < N_MUL; k++) begin : gen_rho_mu_const
            assign rho_mu_w[k] = RHO_MU_VALUES[k*LOGW +: LOGW];
        end
    end else begin : gen_rho_mu_compute
        // Compute rho_mu internally via intmul_wrapper.
        //   N_MUL small multipliers: rho_lo[k] * mu -> low LOGW bits.
        //   rho_lo[k] = rho_w[N_MUL-1-k][LOGW-1:0]  (only low LOGW bits
        //   are relevant since the result is taken mod 2^{LOGW}).

        wire [LOGW-1:0] rho_lo [0:N_MUL-1];

        for (genvar k = 0; k < N_MUL; k++) begin : gen_rho_mu_mul
            assign rho_lo[k] = rho_w[N_MUL - 1 - k][LOGW-1:0];

            wire [2*LOGW-1:0] rm_full;

            intmul_wrapper #(
                .LOGA           (LOGW      ),
                .LOGB           (LOGW      ),
                .FF_IN          (DSP_SMALL ),
                .FF_MUL         (1'b0      ),
                .FF_OUT         (1'b0      ),
                .USE_CSA        (1'b0      ),
                .FF_CSA         (1'b0      ),
                .FF_DIAG        (1'b0      ),
                .FF_CSA_MID     (1'b0      ),
                .FF_ADD         (1'b0      ),
                .MORE_DSP       (1'b0      ),
                .NON_STD        (1'b0      ),
                .USE_KARATSUBA  (0         ),
                .K_PIPE_DSP     (0         ),
                .K_PIPE_PRE     (0         ),
                .K_PIPE_POST    (0         ),
                .K_PIPE_MID     (0         )
            ) u_rho_mu_mul (
                .clk (clk),
                .A   (rho_lo[k]),
                .B   (mu_eff),
                .C   (rm_full)
            );

            // Only the low LOGW bits matter (mod 2^{LOGW}).
            assign rho_mu_w[k] = rm_full[LOGW-1:0];
        end
    end

    // -- Step 3a': Delay c_lo and chi_mu by RM_MUL_LAT cycles --
    //   The rho_mu_w values arrive at cycle RM_MUL_LAT.  Delay
    //   c_lo[i] to align with rho_mu_w[i] for the truncated
    //   product, and delay c_hi_lo * mu to match.
    //
    //   When FIXED_Q = 1: RM_MUL_LAT = 0, so these are
    //   pass-throughs (no delay).

    wire [LOGW-1:0] c_lo_d [0:N_MUL-1];

    for (genvar i = 0; i < N_MUL; i++) begin : gen_clo_delay
        if (RM_MUL_LAT == 0) begin : gen_clo_nodel
            assign c_lo_d[i] = c_lo[i];
        end else begin : gen_clo_del
            (* shreg_extract = "yes", srl_style = "srl_reg" *)
            reg [LOGW-1:0] clo_sr [0:RM_MUL_LAT-1];
            always_ff @(posedge clk) clo_sr[0] <= c_lo[i];
            for (genvar d = 1; d < RM_MUL_LAT; d++) begin : gen_clo_sr
                always_ff @(posedge clk) clo_sr[d] <= clo_sr[d-1];
            end
            assign c_lo_d[i] = clo_sr[RM_MUL_LAT-1];
        end
    end

    // -- Step 3b: LOGW x LOGW truncated multiplies -----------
    //   N_MUL products:  c_lo_d[i] * rho_mu_w[i]
    //   1 product:       c_hi_lo * mu  (delayed by RM_MUL_LAT)
    //   Only the low LOGW bits are needed (mod 2^{LOGW}), so we
    //   assign directly to LOGW-wide signals - the synthesiser
    //   will infer truncated multiplies.
    //
    //   When FIXED_Q = 1, rho_mu_w[i] and mu_eff are compile-
    //   time constants, so one operand of every truncated
    //   multiply is constant, enabling synthesis optimisation.
    wire [LOGW-1:0] rm_prod_comb [0:N_MUL-1];
    wire [LOGW-1:0] chi_mu_raw;

    for (genvar i = 0; i < N_MUL; i++) begin : gen_rm_mul
        if (DSP_SMALL) begin : gen_dsp
            (* use_dsp = "yes" *)
            assign rm_prod_comb[i] = c_lo_d[i] * rho_mu_w[i];
        end else begin : gen_lut
            (* use_dsp = "no" *)
            assign rm_prod_comb[i] = c_lo_d[i] * rho_mu_w[i];
        end
    end

    // c_hi_lo * mu: compute at cycle 0, then delay to align.
    if (DSP_SMALL) begin : gen_chi_mu_dsp
        (* use_dsp = "yes" *)
        assign chi_mu_raw = c_hi_lo * mu_eff;
    end else begin : gen_chi_mu_lut
        (* use_dsp = "no" *)
        assign chi_mu_raw = c_hi_lo * mu_eff;
    end

    wire [LOGW-1:0] chi_mu_comb;

    if (RM_MUL_LAT == 0) begin : gen_chimu_nodel
        assign chi_mu_comb = chi_mu_raw;
    end else begin : gen_chimu_del
        (* shreg_extract = "yes", srl_style = "srl_reg" *)
        reg [LOGW-1:0] chimu_sr [0:RM_MUL_LAT-1];
        always_ff @(posedge clk) chimu_sr[0] <= chi_mu_raw;
        for (genvar d = 1; d < RM_MUL_LAT; d++) begin : gen_chimu_sr
            always_ff @(posedge clk) chimu_sr[d] <= chimu_sr[d-1];
        end
        assign chi_mu_comb = chimu_sr[RM_MUL_LAT-1];
    end

    // -- Step 3b': Optional register on small-multiply outputs -
    wire [LOGW-1:0] rm_prod [0:N_MUL-1];
    wire [LOGW-1:0] chi_mu_prod;

    if (FF_RM) begin : gen_ff_rm
        reg [LOGW-1:0] rm_prod_r [0:N_MUL-1];
        reg [LOGW-1:0] chi_mu_r;
        always_ff @(posedge clk) begin
            for (int i = 0; i < N_MUL; i++)
                rm_prod_r[i] <= rm_prod_comb[i];
            chi_mu_r <= chi_mu_comb;
        end
        for (genvar i = 0; i < N_MUL; i++) begin : gen_rm_assign
            assign rm_prod[i] = rm_prod_r[i];
        end
        assign chi_mu_prod = chi_mu_r;
    end else begin : gen_no_ff_rm
        for (genvar i = 0; i < N_MUL; i++) begin : gen_rm_assign
            assign rm_prod[i] = rm_prod_comb[i];
        end
        assign chi_mu_prod = chi_mu_comb;
    end

    // -- Step 3c: Binary addition tree (mod 2^{LOGW}) --------
    //   Sums N_LIMBS = N_MUL + 1 LOGW-bit values using the
    //   addtree module.  Pipeline depth is controlled by
    //   MT_REG_PERIOD, MT_REG_IN, MT_REG_OUT and accounted
    //   for in MVAL_LAT / PATH_A.

    // Pack inputs into a flat bus: rm_prod[0..N_MUL-1], chi_mu_prod
    wire [(N_LIMBS * LOGW) - 1 : 0] mt_packed;

    for (genvar i = 0; i < N_MUL; i++) begin : gen_mt_pack
        assign mt_packed[i*LOGW +: LOGW] = rm_prod[i];
    end
    assign mt_packed[N_MUL*LOGW +: LOGW] = chi_mu_prod;

    wire [LOGW-1:0] m_val;

    addtree #(
        .WIDTH      (LOGW),
        .NUM_INPUTS (N_LIMBS),
        .REG_PERIOD (MT_REG_PERIOD),
        .REG_IN     (MT_REG_IN),
        .REG_OUT    (MT_REG_OUT),
        .USE_CSA    (MT_USE_CSA),
        .FF_ADD     (MT_FF_ADD)
    ) u_mval_tree (
        .clk (clk),
        .i_a (mt_packed),
        .o_c (m_val)
    );

    // -- Step 3d: Large multiply  m_val x q  (LOGW x LOGQ) ---
    wire [ACCW-1:0] m_q;

    // q must be aligned to the mr_mul input (available at
    // RM_MUL_LAT + FF_RM + MVAL_LAT cycles after the raw inputs).
    //
    // When FIXED_Q = 1, q is a compile-time constant and needs
    // no delay chain, the synthesiser sees Q_VALUE directly.
    localparam int Q_MR_DEL = RM_MUL_LAT + int'(FF_RM) + MVAL_LAT;
    wire [LOGQ-1:0] q_mr;

    if (FIXED_Q) begin : gen_qmr_fixed
        assign q_mr = Q_VALUE;
    end else if (Q_MR_DEL == 0) begin : gen_qmr_nodel
        assign q_mr = q_eff;
    end else begin : gen_qmr_del
        (* shreg_extract = "yes", srl_style = "srl_reg" *)
        reg [LOGQ-1:0] qmr_sr [0:Q_MR_DEL-1];
        always_ff @(posedge clk) qmr_sr[0] <= q_eff;
        for (genvar d = 1; d < Q_MR_DEL; d++) begin : gen_qmr_sr
            always_ff @(posedge clk) qmr_sr[d] <= qmr_sr[d-1];
        end
        assign q_mr = qmr_sr[Q_MR_DEL-1];
    end

    intmul_wrapper #(
        .LOGA           (LOGW      ),
        .LOGB           (LOGQ      ),
        .FF_IN          (FF_IN     ),
        .FF_MUL         (FF_MUL    ),
        .FF_OUT         (FF_MR_POST),
        .USE_CSA        (USE_CSA   ),
        .FF_CSA         (FF_CSA    ),
        .FF_DIAG        (FF_DIAG   ),
        .FF_CSA_MID     (FF_CSA_MID),
        .FF_ADD         (FF_ADD    ),
        .MORE_DSP       (MORE_DSP  ),
        .NON_STD        (NON_STD   ),
        .USE_KARATSUBA  (0         ),
        .K_PIPE_DSP     (0         ),
        .K_PIPE_PRE     (0         ),
        .K_PIPE_POST    (0         ),
        .K_PIPE_MID     (0         )
    ) u_mr_mul (
        .clk (clk),
        .A   (m_val),
        .B   (q_mr),
        .C   (m_q)
    );

    // =============================================================
    // Delay lines - align the two paths at the join point
    // =============================================================
    //
    // Path A delivers m_q   at cycle PATH_A = RM_MUL_LAT + FF_RM + MVAL_LAT + MR_LAT.
    // Path B delivers T_acc at cycle PATH_B = DOT_LAT + ACC_LAT.
    //
    // Whichever arrives first must be delayed to match the other.
    //   MQ_DELAY   = JOIN_CYC - PATH_A   (extra delay on m_q)
    //   TACC_DELAY = JOIN_CYC - PATH_B   (extra delay on T_acc)
    //
    // q_dot : q aligned to modacc input  (delay = DOT_LAT)
    //         When FIXED_Q = 1, q_dot = Q_VALUE (constant, no delay).
    // q_fin : q aligned to final sub     (delay = JOIN_CYC + FF_MR_POST)
    //         When FIXED_Q = 1, q_fin = Q_VALUE (constant, no delay).
    //
    // c_hi  : aligned to modacc input    (delay = DOT_LAT)
    // =============================================================

    // -- c_hi delay (DOT_LAT cycles) - for modacc input ------
    wire [ACCW-1:0] c_hi_aligned;

    if (DOT_LAT == 0) begin : gen_chi_nodel
        assign c_hi_aligned = c_hi;
    end else begin : gen_chi_del
        (* shreg_extract = "yes", srl_style = "srl_reg" *)
        reg [ACCW-1:0] chi_sr [0:DOT_LAT-1];
        always_ff @(posedge clk) chi_sr[0] <= c_hi;
        for (genvar d = 1; d < DOT_LAT; d++) begin : gen_chi_sr
            always_ff @(posedge clk) chi_sr[d] <= chi_sr[d-1];
        end
        assign c_hi_aligned = chi_sr[DOT_LAT-1];
    end

    // -- q delay: q_dot (for modacc, delay = DOT_LAT) --------
    //    When FIXED_Q = 1, the modacc tree receives q*W as a
    //    compile-time constant (via its own FIXED_Q / Q_VALUE
    //    parameters).  No q_dot delay chain is needed.
    localparam int Q_DOT_DEL = DOT_LAT;
    wire [LOGQ-1:0] q_dot;

    if (FIXED_Q) begin : gen_qdot_fixed
        assign q_dot = Q_VALUE;
    end else if (Q_DOT_DEL == 0) begin : gen_qdot_nodel
        assign q_dot = q_eff;
    end else begin : gen_qdot_del
        (* shreg_extract = "yes", srl_style = "srl_reg" *)
        reg [LOGQ-1:0] qdot_sr [0:Q_DOT_DEL-1];
        always_ff @(posedge clk) qdot_sr[0] <= q_eff;
        for (genvar d = 1; d < Q_DOT_DEL; d++) begin : gen_qdot_sr
            always_ff @(posedge clk) qdot_sr[d] <= qdot_sr[d-1];
        end
        assign q_dot = qdot_sr[Q_DOT_DEL-1];
    end

    // -- q delay: q_fin (for final cond-sub) ------------------
    //   Total delay from input = JOIN_CYC + FF_MR_POST.
    //   We chain from q_dot (already delayed DOT_LAT) to save
    //   shift-register resources.
    //
    //   When FIXED_Q = 1, q_fin = Q_VALUE (constant, no delay).
    localparam int Q_FIN_EXTRA = JOIN_CYC + int'(FF_JOIN_ADD) + int'(FF_MR_POST) - Q_DOT_DEL;
    wire [LOGQ-1:0] q_fin;

    if (FIXED_Q) begin : gen_qfin_fixed
        assign q_fin = Q_VALUE;
    end else if (Q_FIN_EXTRA == 0) begin : gen_qfin_nodel
        assign q_fin = q_dot;
    end else if (Q_FIN_EXTRA == 1) begin : gen_qfin_one
        (* max_fanout = 16 *)
        reg [LOGQ-1:0] qfin_r;
        always_ff @(posedge clk) qfin_r <= q_dot;
        assign q_fin = qfin_r;
    end else begin : gen_qfin_del
        (* shreg_extract = "yes", srl_style = "srl" *)
        reg [LOGQ-1:0] qfin_sr [0:Q_FIN_EXTRA-2];

        (* max_fanout = 16 *)
        reg [LOGQ-1:0] qfin_out;

        always_ff @(posedge clk) qfin_sr[0] <= q_dot;
        for (genvar d = 1; d < Q_FIN_EXTRA - 1; d++) begin : gen_qfin_sr
            always_ff @(posedge clk) qfin_sr[d] <= qfin_sr[d-1];
        end
        always_ff @(posedge clk) qfin_out <= qfin_sr[Q_FIN_EXTRA-2];
        assign q_fin = qfin_out;
    end

    // =============================================================
    // Phase 4 - Modular accumulation tree  (Path B, continued)
    // =============================================================
    // Sums  prod[0..n-2] + c_hi  modulo  q * 2^{LOGW}.
    //
    // When ACC_USE_ADDTREE = 0 (legacy):
    //   modacc uses a binary tree of modadd cells.
    //
    // When ACC_USE_ADDTREE = 1:
    //   modacc uses addtree for plain summation, followed by
    //   a binary-search conditional subtraction chain.
    //
    // When FIXED_Q = 1:
    //   modacc receives FIXED_Q = 1 and Q_VALUE = Q_VALUE << LOGW
    //   (= q * W).  All subtractors in the modacc tree see a
    //   compile-time constant q*W, enabling heavy constant
    //   folding and carry-chain optimisation by synthesis.
    // =============================================================
    wire [(N_LIMBS * ACCW) - 1 : 0] acc_in;
    wire [ACCW-1:0]                  acc_q;
    wire [ACCW-1:0]                  T_acc;

    for (genvar i = 0; i < N_MUL; i++) begin : gen_pack_prod
        assign acc_in[(i+1)*ACCW-1 -: ACCW] = prod[i];
    end
    assign acc_in[(N_MUL+1)*ACCW-1 -: ACCW] = c_hi_aligned;

    // When FIXED_Q = 1 the modacc tree uses Q_VALUE * W as a
    // compile-time constant; acc_q is unused in that case.
    assign acc_q = {q_dot, {LOGW{1'b0}}};

    modacc #(
        .LOGQ            (ACCW),
        .NUM_INPUTS      (N_LIMBS),
        // -- Legacy-mode parameters --
        .REG_IN          (logjumps_pkg::ACC_REG_IN),
        .REG_OUT         (logjumps_pkg::ACC_REG_OUT),
        .REG_ADD         (logjumps_pkg::ACC_REG_ADD),
        .CONC_ADDSUB     (logjumps_pkg::ACC_CONC_ADDSUB),
        // -- Mode selection --
        .USE_ADDTREE     (ACC_USE_ADDTREE),
        // -- Addtree-mode parameters --
        .MAX_COND_SUB    (ACC_MAX_COND_SUB),
        .AT_REG_PERIOD   (ACC_AT_REG_PERIOD),
        .AT_REG_IN       (ACC_AT_REG_IN),
        .AT_REG_OUT      (ACC_AT_REG_OUT),
        .AT_USE_CSA      (ACC_AT_USE_CSA),
        .CS_REG_PERIOD   (ACC_CS_REG_PERIOD),
        .CS_REG_OUT      (ACC_CS_REG_OUT),
        // -- Split addtree final adder --
        .AT_FF_ADD       (ACC_AT_FF_ADD),
        // -- Fixed-modulus mode (q * W) --
        .FIXED_Q         (FIXED_Q),
        .Q_VALUE         (QW_VALUE)
    ) u_modacc (
        .clk (clk),
        .i_a (acc_in),
        .i_q (acc_q),
        .o_c (T_acc)
    );

    // =============================================================
    // Phase 5 - Join: align T_acc and m_q, then add+shift
    // =============================================================

    // -- Delay T_acc by TACC_DELAY cycles (0 when Path B >= Path A)
    wire [ACCW-1:0] T_acc_aligned;

    if (TACC_DELAY == 0) begin : gen_tacc_nodel
        assign T_acc_aligned = T_acc;
    end else begin : gen_tacc_del
        (* shreg_extract = "yes", srl_style = "srl_reg" *)
        reg [ACCW-1:0] tacc_sr [0:TACC_DELAY-1];
        always_ff @(posedge clk) tacc_sr[0] <= T_acc;
        for (genvar d = 1; d < TACC_DELAY; d++) begin : gen_tacc_sr
            always_ff @(posedge clk) tacc_sr[d] <= tacc_sr[d-1];
        end
        assign T_acc_aligned = tacc_sr[TACC_DELAY-1];
    end

    // -- Delay m_q by MQ_DELAY cycles (0 when Path A >= Path B)
    wire [ACCW-1:0] m_q_aligned;

    if (MQ_DELAY == 0) begin : gen_mq_nodel
        assign m_q_aligned = m_q;
    end else begin : gen_mq_del
        (* shreg_extract = "yes", srl_style = "srl_reg" *)
        reg [ACCW-1:0] mq_sr [0:MQ_DELAY-1];
        always_ff @(posedge clk) mq_sr[0] <= m_q;
        for (genvar d = 1; d < MQ_DELAY; d++) begin : gen_mq_sr
            always_ff @(posedge clk) mq_sr[d] <= mq_sr[d-1];
        end
        assign m_q_aligned = mq_sr[MQ_DELAY-1];
    end

    // -- Add, shift, conditional-subtract ---------------------
    //
    // Phase 5 computes T_plus = T_acc_aligned + m_q_aligned
    // (ACCW+1 bits), then extracts T_shift_in = T_plus >> LOGW.
    //
    // Two independent pipeline controls:
    //
    //   FF_JOIN_ADD (new):
    //     Splits the wide T_acc + m_q addition at the CARRY8-
    //     aligned midpoint.  Registers the lower-half result,
    //     carry-out, and the two upper operand halves.  The
    //     upper-half addition completes combinationally in the
    //     following cycle.  Costs +1 clock cycle of latency.
    //
    //   FF_MR_POST (original, unchanged):
    //     Registers the full T_shift result (= T_plus >> LOGW)
    //     before the final conditional subtraction.  Costs +1
    //     clock cycle of latency.
    //
    // Typical configurations:
    //   FF_JOIN_ADD=0, FF_MR_POST=1: original pipeline (full add -> reg -> sub)
    //   FF_JOIN_ADD=1, FF_MR_POST=1: split add -> upper add+shift -> reg -> sub  (+1 cyc)
    //   FF_JOIN_ADD=1, FF_MR_POST=0: split add -> upper add+shift+sub -> FF_OUT (+1 cyc)
    //   FF_JOIN_ADD=0, FF_MR_POST=0: fully combinational add+shift+sub

    // --- CARRY8-aligned split point (midpoint, same formula as mac_std) ---
    localparam int JOIN_SPLIT   = ((ACCW / 2) + 7) / 8 * 8;
    localparam int JOIN_UPPER_W = ACCW - JOIN_SPLIT;

    // --- Stage 1 of join: addition (split or full) --------
    wire [ACCW:0] T_plus;

    if (FF_JOIN_ADD) begin : gen_ff_join_add

        // Lower half addition (cycle N)
        wire [JOIN_SPLIT:0] join_lo_full =
            {1'b0, T_acc_aligned[JOIN_SPLIT-1:0]}
          + {1'b0, m_q_aligned [JOIN_SPLIT-1:0]};

        // Split register: lower result, carry, upper operand halves
        reg [JOIN_SPLIT-1:0]    join_lo_q;
        reg                     join_carry_q;
        (* max_fanout = 16 *)
        reg [JOIN_UPPER_W-1:0]  join_upper_a_q;
        (* max_fanout = 16 *)
        reg [JOIN_UPPER_W-1:0]  join_upper_b_q;

        always_ff @(posedge clk) begin
            join_lo_q      <= join_lo_full[JOIN_SPLIT-1:0];
            join_carry_q   <= join_lo_full[JOIN_SPLIT];
            join_upper_a_q <= T_acc_aligned[ACCW-1:JOIN_SPLIT];
            join_upper_b_q <= m_q_aligned  [ACCW-1:JOIN_SPLIT];
        end

        // Upper half addition (cycle N+1, combinational)
        wire [JOIN_UPPER_W:0] join_hi_full =
            {1'b0, join_upper_a_q}
          + {1'b0, join_upper_b_q}
          + {{JOIN_UPPER_W{1'b0}}, join_carry_q};

        assign T_plus = {join_hi_full, join_lo_q};

    end else begin : gen_no_ff_join_add

        assign T_plus = {1'b0, T_acc_aligned} + {1'b0, m_q_aligned};

    end

    // --- Shift: T_shift_in = T_plus >> LOGW ---------------
    wire [LOGQ:0] T_shift_in = T_plus[ACCW : LOGW];

    // --- FF_MR_POST: register T_shift before final sub ----
    logic [LOGQ:0] T_shift;

    if (FF_MR_POST) begin : gen_ff_mr_post
        (* max_fanout = 16 *)
        reg [LOGQ:0] T_shift_r;
        always_ff @(posedge clk)
            T_shift_r <= T_shift_in;
        assign T_shift = T_shift_r;
    end else begin : gen_no_ff_mr_post
        assign T_shift = T_shift_in;
    end

    // -- Final conditional subtraction (combinational) --------
    //    When FIXED_Q = 1, q_fin = Q_VALUE (compile-time constant),
    //    so the subtractor sees a constant operand and the synth
    //    tool can optimise the carry chain.
    wire [LOGQ:0]   T_sub  = T_shift - {1'b0, q_fin};
    wire [LOGQ-1:0] D_comb = T_sub[LOGQ] ? T_shift[LOGQ-1:0]
                                          : T_sub[LOGQ-1:0];

    // =============================================================
    // Phase 6 - Output registration
    // =============================================================

    if (FF_OUT) begin : gen_ff_out
        always_ff @(posedge clk) D <= D_comb;
    end else begin : gen_no_ff_out
        assign D = D_comb;
    end

endmodule