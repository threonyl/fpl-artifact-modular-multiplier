// --------------------------------------------------------------
// Module  : modmul
// Purpose : Full modular multiplication in the Montgomery domain.
//
//   Computes  D = A * B * R^{-1} mod q
//
//   where  A, B  are LOGQ-bit Montgomery-domain operands,
//          q     is the modulus,
//          R     = 2^{LOGR},
//          LOGR  = LOGW * ceil(LOGQ / LOGW).
//
// Architecture:
//
//   +------------------+       +------------------+
//   |  intmul_wrapper  |  C    |     logjumps     |
//   |  (LOGQ x LOGQ)   |--[R]->|   (Montgomery    |----> D
//   | integer multiply |       |    reduction)    |
//   +------------------+       +------------------+
//         MUL_LAT                     LJ_LAT
//
//   [R] = optional MUL_FF_CPA register (default ON).
//         Breaks the Karatsuba CPA -> logjumps critical path.
//         Costs +1 cycle.  MUL_LAT includes this when enabled.
//
//   When FIXED_Q = 0 (default):
//     Side-band inputs (q, rho, mu) are delay-matched through the
//     integer multiplier's latency via SRL-friendly shift registers
//     before being fed to the logjumps reduction block.
//
//   When FIXED_Q = 1:
//     The modulus and all derived constants are compile-time
//     parameters.  The q, rho, mu delay chains are eliminated
//     entirely - logjumps receives constants directly.  The
//     run-time ports q, rho, mu are ignored by the hardware.
//
// Proven configurations for LOGQ = 391, LOGW = 17:
//   Karatsuba big multiply:  MUL_USE_KARATSUBA = 1
//     455 MHz / 11 cyc (mul):  MUL_K_PIPE_DSP=3, MUL_K_PIPE_MID=1
//     225 MHz /  6 cyc (mul):  MUL_K_PIPE_DSP=1, MUL_K_PIPE_MID=0
//
// Pipeline latency:
//   LAT = MUL_LAT + LJ_LAT
//   (see modmul_pkg::modmul_latency)
//
// Author : Selim Kirbiyik, TU Graz (18.3.2026)
// --------------------------------------------------------------

module modmul
    import intmul_wrapper_pkg::*;
    import logjumps_pkg::*;
    import modmul_pkg::*;
#(
    parameter int LOGQ       = 381,
    parameter int LOGW       = 17,
    parameter int LOGR       = LOGW * ((LOGQ + LOGW - 1) / LOGW),

    // -- Big multiplier (LOGQ x LOGQ) controls ----------------
    parameter bit MUL_FF_IN          = 1,
    parameter bit MUL_FF_MUL         = 1,
    parameter bit MUL_FF_OUT         = 1,
    parameter bit MUL_USE_CSA        = 1,
    parameter bit MUL_FF_CSA         = 1,
    parameter bit MUL_FF_DIAG        = 1,
    parameter bit MUL_FF_CSA_MID     = 1,
    parameter bit MUL_FF_ADD         = 1,
    parameter bit MUL_MORE_DSP       = 0,
    parameter bit MUL_NON_STD        = 0,
    parameter bit MUL_USE_KARATSUBA  = 1,
    parameter int MUL_K_PIPE_DSP     = 3,
    parameter int MUL_K_PIPE_PRE     = 1,
    parameter int MUL_K_PIPE_POST    = 1,
    parameter int MUL_K_PIPE_MID     = 1,
    // Pipeline register on the intmul_wrapper output C, between
    // the Karatsuba CPA and the logjumps input.  The Karatsuba
    // PIPE_POST register captures the CSA recomposition in
    // redundant form; the CPA that converts to non-redundant
    // binary is purely combinational (~762-bit carry chain) and
    // fans out into N_LIMBS limb extractions for logjumps.
    // This register breaks that path.  Vivado's max_fanout
    // attribute causes automatic register replication for the
    // high-fanout c_lo/c_hi extraction.
    //
    // Cost: +1 clock cycle of latency.
    //       No additional DSP or significant LUT cost.
    parameter bit MUL_FF_CPA         = 1,

    // -- LogJumps reduction controls --------------------------
    parameter bit LJ_FF_IN      = 1,
    parameter bit LJ_FF_MUL     = 1,
    parameter bit LJ_FF_OUT     = 1,
    parameter bit LJ_USE_CSA    = 1,
    parameter bit LJ_FF_CSA     = 1,
    parameter bit LJ_FF_DIAG    = 0,
    parameter bit LJ_FF_CSA_MID = 1,
    parameter bit LJ_FF_ADD     = 1,
    parameter bit LJ_MORE_DSP   = 1,
    parameter bit LJ_NON_STD    = 0,
    parameter bit LJ_FF_MR_POST = 1,
    // Split the wide join addition (T_acc + m_q) at the CARRY8-
    // aligned midpoint.  Independent of FF_MR_POST.  +1 cycle.
    parameter bit LJ_FF_JOIN_ADD = 1,
    parameter bit LJ_DSP_SMALL  = 1,
    parameter bit LJ_FF_RM      = 0,
    // -- m_val addition tree (addtree) pipeline parameters ---
    parameter int LJ_MT_REG_PERIOD = 2,
    parameter bit LJ_MT_REG_IN     = 1,
    parameter bit LJ_MT_REG_OUT    = 1,
    parameter bit LJ_MT_USE_CSA    = 1,

    // ==========================================================
    // modacc mode selection and configuration
    // ==========================================================
    //
    //   ACC_USE_ADDTREE = 0:
    //     Legacy binary reduction tree of fused modadd cells.
    //
    //   ACC_USE_ADDTREE = 1 (default):
    //     Phase 1 - Plain addtree summation (CSA-capable).
    //     Phase 2 - Binary-search conditional subtraction chain.
    //
    // -- Mode switch ---
    parameter bit ACC_USE_ADDTREE = 1,
    // -- Max conditional subtraction quotient ----------------
    parameter int ACC_MAX_COND_SUB = 12, // LOGR / LOGW - 1,
    // -- Addtree (Phase 1) configuration --------------------
    parameter int ACC_AT_REG_PERIOD = 3,
    parameter bit ACC_AT_REG_IN     = 1,
    parameter bit ACC_AT_REG_OUT    = 1,
    parameter bit ACC_AT_USE_CSA    = 1,
    // -- Cond-sub chain (Phase 2) configuration -------------
    parameter int ACC_CS_REG_PERIOD = 1,
    parameter bit ACC_CS_REG_OUT    = 1,
    // -- Split addtree final binary adder --------------------
    parameter bit ACC_AT_FF_ADD     = 1,

    // ==========================================================
    // Fixed-modulus mode (FIXED_Q)
    // ==========================================================
    //
    //   FIXED_Q = 0 (default):
    //     q, rho, and mu are run-time inputs.  Delay chains align
    //     them with the intmul_wrapper output (MUL_LAT cycles).
    //
    //   FIXED_Q = 1:
    //     The modulus and all derived constants are compile-time
    //     parameters.  Effects:
    //       - q, rho, mu delay chains eliminated (constants are
    //         passed directly to logjumps).
    //       - logjumps eliminates all internal rho*mu multipliers
    //         (RM_MUL_LAT = 0), q delay chains, and gets constant
    //         folding in all subtractors.
    //       - The run-time ports q, rho, mu are ignored.
    //
    // -- Mode switch ---
    parameter bit                              FIXED_Q        = 1,
    // -- Compile-time modulus (LOGQ bits) ---
    parameter bit [LOGQ-1:0]                   Q_VALUE        = 381'h1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab,
    // -- Compile-time Montgomery constant mu = -q^{-1} mod 2^{LOGW} ---
    parameter bit [LOGW-1:0]                   MU_VALUE       = 'h0fffd,
    // -- Compile-time rho values, packed LE ---
    //    RHO_VALUES[k*LOGQ +: LOGQ] = rho[k+1]  for k = 0 .. N_MUL-1
    //    (same packing as the rho input port)
    parameter bit [(LOGR/LOGW-1)*LOGQ-1:0]     RHO_VALUES     = 'h275073cccb0b33be44aaf5b83644fac86b854cd1cdb24e7c0e3c91ecbd79e2e91aa3af3475c7e16a5a86c9c05c67a8845af26cd0e23d04dce5270d77a2167e9d1ed756886fc1f4289fcd384a948cf24b5d66fc05acac45c7cc85c68298629a88ed96a04e5af6859e57d03dbe5b2134ae03b06d79e079a3948a803cb2e762ae2124a3f202f88c15925d29863c4eed5939537402c7dda19600f9b4d586bb49df94862f2e3fd4ca14d93fe650e14277acf6c75dfb89baa65fc6abc4f0aa50d5ea82c98ac1592ce76f5d653d16f11a124d3cb619fe708b81cdd7dda6fcc90c6c9e2de6b80a18060fe0948aa5192049938b7fcba7ef337d67655301d07ae9bcec78eb4c55952b3c515438f21359360b9fd02ea689cc52756eefd092051d0c7c2ba87e83e5aa272d48b2af62faa4249d23bc48eac080308cb6f2f839fd307df4e7f9a60505c5f0ec53b391d0ca1e6da4415114215b1d87485f20a6b9a06f71a10f22ccb4e0d7d4118a138ba0ed6096fe90c0e3e71e5557928cb8a1e6fcd2881c082c2a0720194dd521f8d3ee1927ea1e4db5759b9fea6485224ac26e0e5fc4dcf1eaf477e5b10440d1d5cd28c6e1badebf1cfff47d06c9626fd2589c5d0acb6a7f3db92765cd350be7c5058afc21ff74e884ede6a30e7d5d59cc6e1d5af3a8492e33562a8090f45a21606886bb1a68c5eccd67d803beccd5e14b6238701847aac103ea43f3f5c4637855af61b60378da2917eed2bae905785bade219e65697de322c92a8bfa73bb6e3c08e40a2f5afc14ba1a959a7c2f130fe1b621988c8aa63bc6431013bfb6d99551efb4624ae3f802c116e34d8c3320271f93452861dbb4e5e201cfba23b496f81989f08382ceb880c216f0e26ff5cce7e58db7818504b921db2f8aeadd31b2493f41b3681bd46d3bbc97ee4fde4e9edf08400442d343aa3407b60280311e657237990e95e69127675bf2a757c7b7053761bfcef973d118134d709708f8e3098044530b04d3d6d5fa005c567c7b078dd5aafaec632c76b5a059abf558e49f2a88ad10381f57ddd9fc15e68ece71c58530b10da1ea40f519b3c674a2467086cd5cc1b8d647553e7415625fe0070fc1316f1ca27d87dd84a44203242af48af8d0da30732e30cde0bf1eee5d104231465b74e64a09b683177a52125fbf97723dfc15a5de9d40cdb8f768c5b0d8c9f8710733155078666f05f57674fff8b042ee85609e3bbf0b41b896dcdfb1e8af4dd50d76294bcfe8a95784c159e1dcd09d21550a5f027cb3401fcd2b11eb513cb30ae9bc0750882652898225bccb03cd3b38111fa8823841e26eebbc371c8016a025f03e9013e58d0061f35adf022df566894a356af5e8ca070bcc71c82ad0aa31b268249dcd172c1660c72aa9f603d301e901e9015556d0061f381e09d0d4ba66331a614717a2ef88f0f887b1c1817794e873f6709089e1fd1fd58abf601dcffe9017fffd556,
    // -- Pre-computed rho_mu constants, packed LE ---
    //    RHO_MU_VALUES[k*LOGW +: LOGW] = (rho[n-1-k] * mu) mod 2^{LOGW}
    //    for k = 0 .. N_MUL-1.  Only used when FIXED_Q = 1.
    parameter bit [(LOGR/LOGW-1)*LOGW-1:0]     RHO_MU_VALUES  = 'h0fffcffff889f444f92d9dab6e482838c2ef0c9bbcbb4c13acb4a0e867b3cf58389a316ff1a2cafc91bfab0610833a
)(
    input  logic                             clk,
    input  logic [LOGQ-1:0]                  A,      // operand A (Montgomery domain)
    input  logic [LOGQ-1:0]                  B,      // operand B (Montgomery domain)
    input  logic [LOGQ-1:0]                  q,      // modulus (ignored when FIXED_Q = 1)
    input  logic [(LOGR/LOGW-1)*LOGQ-1:0]    rho,    // { rho[n-1], ..., rho[1] } packed LE (ignored when FIXED_Q = 1)
    input  logic [LOGW-1:0]                  mu,     // -q^{-1} mod 2^{LOGW} (ignored when FIXED_Q = 1)
    output logic [LOGQ-1:0]                  D       // A * B * R^{-1} mod q
);

    // -- Derived constants ------------------------------------
    localparam int N_LIMBS  = LOGR / LOGW;
    localparam int RHO_BITS = (N_LIMBS - 1) * LOGQ;

    // -- Sub-block latencies ----------------------------------
    localparam int MUL_LAT = modmul_pkg::mul_latency(
        LOGQ,
        int'(MUL_FF_IN), int'(MUL_FF_MUL), int'(MUL_FF_OUT),
        int'(MUL_USE_CSA), int'(MUL_FF_CSA),
        int'(MUL_MORE_DSP), int'(MUL_NON_STD),
        int'(MUL_FF_ADD), int'(MUL_FF_DIAG), int'(MUL_FF_CSA_MID),
        int'(MUL_USE_KARATSUBA),
        MUL_K_PIPE_DSP, MUL_K_PIPE_PRE,
        MUL_K_PIPE_POST, MUL_K_PIPE_MID,
        int'(MUL_FF_CPA)
    );

    localparam int LJ_LAT = modmul_pkg::lj_latency(
        LOGW, LOGQ, LOGR,
        int'(LJ_FF_IN), int'(LJ_FF_MUL), int'(LJ_FF_OUT),
        int'(LJ_USE_CSA), int'(LJ_FF_CSA),
        int'(LJ_MORE_DSP), int'(LJ_NON_STD),
        int'(LJ_FF_ADD), int'(LJ_FF_DIAG), int'(LJ_FF_CSA_MID),
        int'(LJ_FF_MR_POST), int'(LJ_FF_RM),
        int'(LJ_MT_REG_PERIOD), int'(LJ_MT_REG_IN), int'(LJ_MT_REG_OUT),
        int'(LJ_MT_USE_CSA), int'(LJ_DSP_SMALL),
        int'(ACC_USE_ADDTREE), ACC_MAX_COND_SUB,
        ACC_AT_REG_PERIOD, int'(ACC_AT_REG_IN),
        int'(ACC_AT_REG_OUT), int'(ACC_AT_USE_CSA),
        ACC_CS_REG_PERIOD, int'(ACC_CS_REG_OUT),
        int'(FIXED_Q),
        int'(ACC_AT_FF_ADD),
        int'(LJ_FF_JOIN_ADD)
    );

    localparam int LAT = MUL_LAT + LJ_LAT;

    // ---------------------------------------------------------
    // Stage 1 - Full-width integer multiplication (LOGQ x LOGQ)
    // ---------------------------------------------------------
    wire [2*LOGQ-1:0] C_raw;

    intmul_wrapper #(
        .LOGA           (LOGQ              ),
        .LOGB           (LOGQ              ),
        .FF_IN          (MUL_FF_IN         ),
        .FF_MUL         (MUL_FF_MUL        ),
        .FF_OUT         (MUL_FF_OUT        ),
        .USE_CSA        (MUL_USE_CSA       ),
        .FF_CSA         (MUL_FF_CSA        ),
        .FF_DIAG        (MUL_FF_DIAG       ),
        .FF_CSA_MID     (MUL_FF_CSA_MID    ),
        .FF_ADD         (MUL_FF_ADD        ),
        .MORE_DSP       (MUL_MORE_DSP      ),
        .NON_STD        (MUL_NON_STD       ),
        .USE_KARATSUBA  (MUL_USE_KARATSUBA ),
        .K_PIPE_DSP     (MUL_K_PIPE_DSP    ),
        .K_PIPE_PRE     (MUL_K_PIPE_PRE    ),
        .K_PIPE_POST    (MUL_K_PIPE_POST   ),
        .K_PIPE_MID     (MUL_K_PIPE_MID    )
    ) u_intmul (
        .clk (clk),
        .A   (A),
        .B   (B),
        .C   (C_raw)
    );

    // ---------------------------------------------------------
    // Optional post-CPA pipeline register (MUL_FF_CPA)
    // ---------------------------------------------------------
    // When enabled, registers the intmul_wrapper output before
    // it enters the logjumps block.  This breaks the critical
    // path from the Karatsuba recomposition CPA carry chain
    // through the high-fanout limb extraction into the modacc
    // addtree.  The max_fanout attribute causes Vivado to
    // replicate the register, eliminating the 153/306-fanout
    // bottleneck that dominates routing delay.
    // ---------------------------------------------------------
    wire [2*LOGQ-1:0] C;

    if (MUL_FF_CPA) begin : gen_ff_cpa
        (* max_fanout = 32 *)
        logic [2*LOGQ-1:0] C_r;
        always_ff @(posedge clk) C_r <= C_raw;
        assign C = C_r;
    end else begin : gen_no_ff_cpa
        assign C = C_raw;
    end

    // ---------------------------------------------------------
    // Delay lines - align q, rho, mu with intmul_wrapper output
    // ---------------------------------------------------------
    // When FIXED_Q = 0:
    //   All three side-band signals must be delayed by MUL_LAT
    //   cycles so they arrive at the logjumps inputs in the same
    //   cycle as the product C.
    //
    //   Pure-delay shift registers use SRL inference for area.
    //   Each signal has an independent chain so intermediate taps
    //   don't block SRL extraction.
    //
    // When FIXED_Q = 1:
    //   q, rho, mu are compile-time constants inside logjumps.
    //   No delay chains are needed, the aligned signals are
    //   tied to the constant values to avoid X-propagation.
    // ---------------------------------------------------------

    // -- q delay (MUL_LAT cycles) -----------------------------
    wire [LOGQ-1:0] q_aligned;

    if (FIXED_Q) begin : gen_q_fixed
        assign q_aligned = Q_VALUE;
    end else if (MUL_LAT == 0) begin : gen_q_nodel
        assign q_aligned = q;
    end else begin : gen_q_del
        (* shreg_extract = "yes", srl_style = "srl_reg" *)
        reg [LOGQ-1:0] q_sr [0:MUL_LAT-1];
        always_ff @(posedge clk) q_sr[0] <= q;
        for (genvar d = 1; d < MUL_LAT; d++) begin : gen_q_sr
            always_ff @(posedge clk) q_sr[d] <= q_sr[d-1];
        end
        assign q_aligned = q_sr[MUL_LAT-1];
    end

    // -- rho delay (MUL_LAT cycles) ---------------------------
    wire [RHO_BITS-1:0] rho_aligned;

    if (FIXED_Q) begin : gen_rho_fixed
        assign rho_aligned = RHO_VALUES;
    end else if (MUL_LAT == 0) begin : gen_rho_nodel
        assign rho_aligned = rho;
    end else begin : gen_rho_del
        (* shreg_extract = "yes", srl_style = "srl_reg" *)
        reg [RHO_BITS-1:0] rho_sr [0:MUL_LAT-1];
        always_ff @(posedge clk) rho_sr[0] <= rho;
        for (genvar d = 1; d < MUL_LAT; d++) begin : gen_rho_sr
            always_ff @(posedge clk) rho_sr[d] <= rho_sr[d-1];
        end
        assign rho_aligned = rho_sr[MUL_LAT-1];
    end

    // -- mu delay (MUL_LAT cycles) ----------------------------
    wire [LOGW-1:0] mu_aligned;

    if (FIXED_Q) begin : gen_mu_fixed
        assign mu_aligned = MU_VALUE;
    end else if (MUL_LAT == 0) begin : gen_mu_nodel
        assign mu_aligned = mu;
    end else begin : gen_mu_del
        (* shreg_extract = "yes", srl_style = "srl_reg" *)
        reg [LOGW-1:0] mu_sr [0:MUL_LAT-1];
        always_ff @(posedge clk) mu_sr[0] <= mu;
        for (genvar d = 1; d < MUL_LAT; d++) begin : gen_mu_sr
            always_ff @(posedge clk) mu_sr[d] <= mu_sr[d-1];
        end
        assign mu_aligned = mu_sr[MUL_LAT-1];
    end

    // ---------------------------------------------------------
    // Stage 2 - LogJumps Montgomery reduction
    // ---------------------------------------------------------
    //   D = C * 2^{-LOGR} mod q
    //
    //   When FIXED_Q = 0:
    //     rho_mu constants are computed internally by logjumps.
    //
    //   When FIXED_Q = 1:
    //     All constants (q, rho, mu, rho_mu) are compile-time
    //     parameters.  logjumps eliminates its rho*mu multipliers
    //     and all q delay chains.
    // ---------------------------------------------------------

    logjumps #(
        .LOGW           (LOGW              ),
        .LOGQ           (LOGQ              ),
        .LOGR           (LOGR              ),
        .FF_IN          (LJ_FF_IN          ),
        .FF_MUL         (LJ_FF_MUL         ),
        .FF_OUT         (LJ_FF_OUT         ),
        .USE_CSA        (LJ_USE_CSA        ),
        .FF_CSA         (LJ_FF_CSA         ),
        .FF_DIAG        (LJ_FF_DIAG        ),
        .FF_CSA_MID     (LJ_FF_CSA_MID     ),
        .FF_ADD         (LJ_FF_ADD         ),
        .MORE_DSP       (LJ_MORE_DSP       ),
        .NON_STD        (LJ_NON_STD        ),
        .FF_MR_POST     (LJ_FF_MR_POST     ),
        .FF_JOIN_ADD    (LJ_FF_JOIN_ADD    ),
        .DSP_SMALL      (LJ_DSP_SMALL      ),
        .FF_RM          (LJ_FF_RM          ),
        .MT_REG_PERIOD  (LJ_MT_REG_PERIOD  ),
        .MT_REG_IN      (LJ_MT_REG_IN      ),
        .MT_REG_OUT     (LJ_MT_REG_OUT     ),
        .MT_USE_CSA     (LJ_MT_USE_CSA     ),
        // -- modacc mode --
        .ACC_USE_ADDTREE   (ACC_USE_ADDTREE   ),
        .ACC_MAX_COND_SUB  (ACC_MAX_COND_SUB  ),
        .ACC_AT_REG_PERIOD (ACC_AT_REG_PERIOD ),
        .ACC_AT_REG_IN     (ACC_AT_REG_IN     ),
        .ACC_AT_REG_OUT    (ACC_AT_REG_OUT    ),
        .ACC_AT_USE_CSA    (ACC_AT_USE_CSA    ),
        .ACC_CS_REG_PERIOD (ACC_CS_REG_PERIOD ),
        .ACC_CS_REG_OUT    (ACC_CS_REG_OUT    ),
        .ACC_AT_FF_ADD     (ACC_AT_FF_ADD     ),
        // -- Fixed-modulus mode --
        .FIXED_Q        (FIXED_Q           ),
        .Q_VALUE        (Q_VALUE           ),
        .MU_VALUE       (MU_VALUE          ),
        .RHO_VALUES     (RHO_VALUES        ),
        .RHO_MU_VALUES  (RHO_MU_VALUES     )
    ) u_logjumps (
        .clk (clk),
        .C   (C),
        .q   (q_aligned),
        .rho (rho_aligned),
        .mu  (mu_aligned),
        .D   (D)
    );

endmodule