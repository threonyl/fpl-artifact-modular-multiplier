// --------------------------------------------------------------
// Package : logjumps_pkg
// Purpose : Compile-time helpers for the logjumps module.
//
//   - Latency calculation for the full pipeline
//   - Sub-block latency accessors
//
// The logjumps rho-fused parallel-tree reduction pipeline is:
//
//   Path B (wide, slow - dot product + modular accumulation):
//
//   +-----------+   +----------+
//   | n-1 intmul|-->|  modacc  |--[align]---------------------+
//   | (dot prod)|   |  tree    |                              |
//   +-----------+   +----------+                              v
//     DOT_LAT          ACC_LAT                           +----------+
//                                                        | add+shift|--> cond-sub
//   Path A (narrow, fast - rho-fused m_val):             +----------+     + FF_OUT
//                                                             ^
//   +--------+  +--------+         +--------+  +--------+     |
//   | n LOGW |--| n LOGW |-[FF_RM]-| addtree|--| m x q  |-[align]+
//   | x LOGW |  | x LOGW |         | (LOGW) |  | MR mul |
//   |rho*mu  |  |c*rho_mu|         +--------+  +--------+
//   +--------+  +--------+          MT_LAT       MR_LAT
//   RM_MUL_LAT
//
//   When FIXED_Q = 1, the rho*mu multipliers are eliminated
//   (pre-computed constants supplied as parameters), so
//   RM_MUL_LAT = 0 and the pipeline diagram simplifies to:
//
//   +--------+         +--------+  +--------+
//   | n LOGW |-[FF_RM]-| addtree|--| m x q  |-[align]+
//   | x LOGW |         | (LOGW) |  | MR mul |
//   |c*rho_mu|         +--------+  +--------+
//   +--------+          MT_LAT       MR_LAT
//
//   Additionally, all q delay chains are eliminated (q is a
//   compile-time constant), and the modacc tree receives a
//   fixed q*W constant for its subtractors.
//
//   Total latency:
//     max(DOT_LAT + ACC_LAT, RM_MUL_LAT + FF_RM + MT_LAT + MR_LAT)
//       + FF_MR_POST + FF_OUT
//
// modacc modes (selected by ACC_USE_ADDTREE):
//
//   ACC_USE_ADDTREE = 0 (default):
//     Legacy binary reduction tree of fused modadd cells.
//     Configured by the fixed ACC_REG_IN/OUT/ADD/CONC_ADDSUB
//     package constants.
//
//   ACC_USE_ADDTREE = 1:
//     Phase 1 - Plain addtree summation (CSA-capable).
//     Phase 2 - Binary-search conditional subtraction chain
//               (K = clog2(MAX_COND_SUB + 1) stages).
//     Configured by ACC_AT_* and ACC_CS_* parameters passed
//     from the logjumps module.
//
// Author : Selim Kirbiyik, TU Graz (27.2.2026)
// --------------------------------------------------------------

package logjumps_pkg;

    import intmul_wrapper_pkg::*;
    import modacc_pkg::*;
    import modadd_pkg::*;
    import addtree_pkg::*;

    // -- Modacc tree configuration (fixed for legacy mode) ----
    localparam bit ACC_REG_IN      = 1;
    localparam bit ACC_REG_OUT     = 1;
    localparam bit ACC_REG_ADD     = 1;
    localparam bit ACC_CONC_ADDSUB = 0;

    // -- Helper: compile-time max ----------------------------
    function automatic int unsigned max_int(int a, int b);
        return (a > b) ? a : b;
    endfunction

    // -- Dot-product multiplier latency ----------------------
    function automatic int unsigned dot_mul_latency(
        int LOGW, int LOGQ,
        int FF_IN, int FF_MUL,
        int USE_CSA, int FF_CSA,
        int MORE_DSP, int NON_STD,
        int FF_ADD, int FF_DIAG, int FF_CSA_MID
    );
        return intmul_wrapper_pkg::latency(
            LOGW, LOGQ,
            FF_IN, FF_MUL, /*FF_OUT=*/1,
            USE_CSA, FF_CSA, MORE_DSP, NON_STD,
            FF_ADD, FF_DIAG, FF_CSA_MID,
            /*use_karatsuba=*/0,
            /*k_pipe_dsp=*/0, /*k_pipe_pre=*/0,
            /*k_pipe_post=*/0, /*k_pipe_mid=*/0
        );
    endfunction

    // -- Modular accumulation tree latency -------------------
    //    Supports both legacy (modadd tree) and addtree +
    //    conditional-subtraction modes.  The addtree-mode
    //    parameters are ignored when ACC_USE_ADDTREE = 0.
    function automatic int unsigned acc_tree_latency(
        int LOGW, int LOGQ,
        // -- addtree-mode parameters (ignored when 0) --------
        int ACC_USE_ADDTREE   = 0,
        int ACC_MAX_COND_SUB  = 0,
        int ACC_AT_REG_PERIOD = 1,
        int ACC_AT_REG_IN     = 1,
        int ACC_AT_REG_OUT    = 1,
        int ACC_AT_USE_CSA    = 1,
        int ACC_CS_REG_PERIOD = 1,
        int ACC_CS_REG_OUT    = 1,
        int ACC_AT_FF_ADD     = 0
    );
        int n_limbs = LOGQ / LOGW;
        return modacc_pkg::modacc_latency(
            n_limbs,
            ACC_REG_IN, ACC_REG_OUT, ACC_REG_ADD, ACC_CONC_ADDSUB,
            /*USE_ADDTREE=*/   bit'(ACC_USE_ADDTREE),
            /*MAX_COND_SUB=*/  ACC_MAX_COND_SUB,
            /*AT_REG_PERIOD=*/ ACC_AT_REG_PERIOD,
            /*AT_REG_IN=*/     bit'(ACC_AT_REG_IN),
            /*AT_REG_OUT=*/    bit'(ACC_AT_REG_OUT),
            /*AT_USE_CSA=*/    bit'(ACC_AT_USE_CSA),
            /*CS_REG_PERIOD=*/ ACC_CS_REG_PERIOD,
            /*CS_REG_OUT=*/    bit'(ACC_CS_REG_OUT),
            /*AT_FF_ADD=*/     bit'(ACC_AT_FF_ADD)
        );
    endfunction

    // -- Rho-mu small multiplier latency ---------------------
    //    rho_lo[k] x mu : LOGW x LOGW -> 2*LOGW (truncated to LOGW)
    //    Uses DSP_SMALL for the input register; all other pipeline
    //    knobs are zero since a single DSP slice suffices.
    //
    //    When FIXED_Q = 1, rho_mu products are pre-computed
    //    constants supplied as parameters.  No multiplier is
    //    instantiated and the latency is zero.
    function automatic int unsigned rm_mul_latency(
        int LOGW, int DSP_SMALL,
        int FIXED_Q = 0
    );
        if (FIXED_Q != 0)
            return 0;
        return intmul_wrapper_pkg::latency(
            LOGW, LOGW,
            /*FF_IN=*/DSP_SMALL, /*FF_MUL=*/0, /*FF_OUT=*/0,
            /*USE_CSA=*/0, /*FF_CSA=*/0, /*MORE_DSP=*/0, /*NON_STD=*/0,
            /*FF_ADD=*/0, /*FF_DIAG=*/0, /*FF_CSA_MID=*/0,
            /*use_karatsuba=*/0,
            /*k_pipe_dsp=*/0, /*k_pipe_pre=*/0,
            /*k_pipe_post=*/0, /*k_pipe_mid=*/0
        );
    endfunction

    // -- Montgomery-reduction multiplier latency -------------
    //    m_val x q : LOGW x LOGQ -> LOGW+LOGQ
    //    FF_OUT of the intmul is tied to FF_MR_POST.
    function automatic int unsigned mr_mul_latency(
        int LOGW, int LOGQ,
        int FF_IN, int FF_MUL,
        int USE_CSA, int FF_CSA,
        int MORE_DSP, int NON_STD,
        int FF_ADD, int FF_DIAG, int FF_CSA_MID,
        int FF_MR_POST
    );
        return intmul_wrapper_pkg::latency(
            LOGW, LOGQ,
            FF_IN, FF_MUL, /*FF_OUT=*/FF_MR_POST,
            USE_CSA, FF_CSA, MORE_DSP, NON_STD,
            FF_ADD, FF_DIAG, FF_CSA_MID,
            /*use_karatsuba=*/0,
            /*k_pipe_dsp=*/0, /*k_pipe_pre=*/0,
            /*k_pipe_post=*/0, /*k_pipe_mid=*/0
        );
    endfunction

    // -- m_val addition tree latency -------------------------
    //    N_LIMBS = LOGQ/LOGW inputs, each LOGW bits wide.
    //    Configured by MT_REG_PERIOD, MT_REG_IN, MT_REG_OUT.
    function automatic int unsigned mval_tree_latency(
        int LOGW, int LOGQ,
        int MT_REG_PERIOD, int MT_REG_IN, int MT_REG_OUT,
        int MT_USE_CSA = 0,
        int MT_FF_ADD  = 0
    );
        int n_limbs = LOGQ / LOGW;
        return addtree_pkg::addtree_latency(
            n_limbs, MT_REG_PERIOD,
            bit'(MT_REG_IN), bit'(MT_REG_OUT),
            bit'(MT_USE_CSA),
            bit'(MT_FF_ADD)
        );
    endfunction

    // -- Path A latency (rho-fused m_val -> m*q) -------------
    //    RM_MUL_LAT (rho*mu small multiply) + FF_RM (register)
    //    + m_val addtree latency + MR multiplier latency.
    //
    //    When FIXED_Q = 1, RM_MUL_LAT = 0 (rho_mu products are
    //    pre-computed constants, no multiplier instantiated).
    function automatic int unsigned path_a_latency(
        int LOGW, int LOGQ, int LOGR,
        int FF_IN, int FF_MUL,
        int USE_CSA, int FF_CSA,
        int MORE_DSP, int NON_STD,
        int FF_ADD, int FF_DIAG, int FF_CSA_MID,
        int FF_MR_POST, int FF_RM,
        int MT_REG_PERIOD, int MT_REG_IN, int MT_REG_OUT,
        int MT_USE_CSA = 0,
        int DSP_SMALL = 1,
        int FIXED_Q = 0,
        int MT_FF_ADD = 0
    );
        return rm_mul_latency(LOGW, DSP_SMALL, FIXED_Q)
             + FF_RM
             + mval_tree_latency(LOGW, LOGR,
                                 MT_REG_PERIOD, MT_REG_IN, MT_REG_OUT,
                                 MT_USE_CSA,
                                 MT_FF_ADD)
             + mr_mul_latency(LOGW, LOGQ, FF_IN, FF_MUL,
                              USE_CSA, FF_CSA, MORE_DSP, NON_STD,
                              FF_ADD, FF_DIAG, FF_CSA_MID,
                              FF_MR_POST);
    endfunction

    // -- Path B latency (dot product + modacc tree) ----------
    //    Accepts the addtree-mode parameters and forwards them
    //    to acc_tree_latency.  They are ignored when
    //    ACC_USE_ADDTREE = 0.
    function automatic int unsigned path_b_latency(
        int LOGW, int LOGQ, int LOGR,
        int FF_IN, int FF_MUL,
        int USE_CSA, int FF_CSA,
        int MORE_DSP, int NON_STD,
        int FF_ADD, int FF_DIAG, int FF_CSA_MID,
        // -- addtree-mode parameters -------------------------
        int ACC_USE_ADDTREE   = 0,
        int ACC_MAX_COND_SUB  = 0,
        int ACC_AT_REG_PERIOD = 1,
        int ACC_AT_REG_IN     = 1,
        int ACC_AT_REG_OUT    = 1,
        int ACC_AT_USE_CSA    = 1,
        int ACC_CS_REG_PERIOD = 1,
        int ACC_CS_REG_OUT    = 1,
        int ACC_AT_FF_ADD     = 0
    );
        return dot_mul_latency(LOGW, LOGQ, FF_IN, FF_MUL,
                               USE_CSA, FF_CSA, MORE_DSP, NON_STD,
                               FF_ADD, FF_DIAG, FF_CSA_MID)
             + acc_tree_latency(LOGW, LOGR,
                                ACC_USE_ADDTREE, ACC_MAX_COND_SUB,
                                ACC_AT_REG_PERIOD, ACC_AT_REG_IN,
                                ACC_AT_REG_OUT, ACC_AT_USE_CSA,
                                ACC_CS_REG_PERIOD, ACC_CS_REG_OUT,
                                ACC_AT_FF_ADD);
    endfunction

    // -- Total pipeline latency (rho-fused) ------------------
    //    max(Path A, Path B) + FF_JOIN_ADD + FF_MR_POST + FF_OUT
    //
    //    When FIXED_Q = 1, Path A is shorter because RM_MUL_LAT
    //    drops to zero (rho_mu products are pre-computed).
    function automatic int unsigned logjumps_latency(
        int LOGW, int LOGQ, int LOGR,
        int FF_IN, int FF_MUL, int FF_OUT,
        int USE_CSA, int FF_CSA,
        int MORE_DSP, int NON_STD,
        int FF_ADD, int FF_DIAG, int FF_CSA_MID,
        int FF_MR_POST, int FF_RM,
        int MT_REG_PERIOD, int MT_REG_IN, int MT_REG_OUT,
        int MT_USE_CSA = 0,
        int DSP_SMALL = 1,
        // -- addtree-mode parameters for modacc --------------
        int ACC_USE_ADDTREE   = 0,
        int ACC_MAX_COND_SUB  = 0,
        int ACC_AT_REG_PERIOD = 1,
        int ACC_AT_REG_IN     = 1,
        int ACC_AT_REG_OUT    = 1,
        int ACC_AT_USE_CSA    = 1,
        int ACC_CS_REG_PERIOD = 1,
        int ACC_CS_REG_OUT    = 1,
        // -- fixed-q mode ------------------------------------
        int FIXED_Q           = 0,
        // -- addtree final-adder split -----------------------
        int ACC_AT_FF_ADD     = 0,
        // -- join-adder split --------------------------------
        int FF_JOIN_ADD       = 0,
        // -- m_val addtree final-adder split -----------------
        int MT_FF_ADD         = 0
    );
        int pa = path_a_latency(LOGW, LOGQ, LOGR, FF_IN, FF_MUL,
                                USE_CSA, FF_CSA, MORE_DSP, NON_STD,
                                FF_ADD, FF_DIAG, FF_CSA_MID,
                                FF_MR_POST, FF_RM,
                                MT_REG_PERIOD, MT_REG_IN, MT_REG_OUT,
                                MT_USE_CSA, DSP_SMALL,
                                FIXED_Q,
                                MT_FF_ADD);
        int pb = path_b_latency(LOGW, LOGQ, LOGR, FF_IN, FF_MUL,
                                USE_CSA, FF_CSA, MORE_DSP, NON_STD,
                                FF_ADD, FF_DIAG, FF_CSA_MID,
                                ACC_USE_ADDTREE, ACC_MAX_COND_SUB,
                                ACC_AT_REG_PERIOD, ACC_AT_REG_IN,
                                ACC_AT_REG_OUT, ACC_AT_USE_CSA,
                                ACC_CS_REG_PERIOD, ACC_CS_REG_OUT,
                                ACC_AT_FF_ADD);
        return max_int(pa, pb) + FF_JOIN_ADD + FF_MR_POST + FF_OUT;
    endfunction

endpackage