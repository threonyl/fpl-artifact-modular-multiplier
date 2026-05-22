// --------------------------------------------------------------
// Package : modmul_pkg
// Purpose : Compile-time helpers for the modmul module.
//
//   Combines the latency of the full-width integer multiplier
//   (intmul_wrapper, LOGQ x LOGQ) with the LogJumps Montgomery
//   reduction (logjumps) to give the total modular-multiplication
//   pipeline depth.
//
//   D = A * B * R^{-1} mod q       (Montgomery multiplication)
//
//   where R = 2^{LOGR},  LOGR = LOGW * ceil(LOGQ / LOGW).
//
//   Pipeline:
//     +----------------+       +-------------+
//     | intmul_wrapper |--[R]->|  logjumps   |----> D
//     | (LOGQ x LOGQ)  |       | (reduction) |
//     +----------------+       +-------------+
//          MUL_LAT                LJ_LAT
//
//   [R] = optional MUL_FF_CPA register (default ON).
//         Breaks the Karatsuba CPA -> logjumps critical path.
//         MUL_LAT includes this when enabled.
//
//   When FIXED_Q = 1, the logjumps block uses compile-time
//   constants for q, rho, mu and rho_mu.  RM_MUL_LAT drops
//   to zero and all q delay chains are eliminated.
//
// Author : Selim Kirbiyik, TU Graz (18.3.2026)
// --------------------------------------------------------------

package modmul_pkg;

    import intmul_wrapper_pkg::*;
    import logjumps_pkg::*;

    // -- Big multiplier latency (LOGQ x LOGQ) -----------------
    //    MUL_FF_CPA: optional pipeline register on the intmul
    //    output C, between the Karatsuba CPA and the logjumps
    //    input.  Breaks the ~762-bit carry-propagate + high-fanout
    //    routing path that otherwise spans the module boundary.
    //    Costs +1 clock cycle.
    function automatic int unsigned mul_latency(
        int LOGQ,
        int MUL_FF_IN, int MUL_FF_MUL, int MUL_FF_OUT,
        int MUL_USE_CSA, int MUL_FF_CSA,
        int MUL_MORE_DSP, int MUL_NON_STD,
        int MUL_FF_ADD, int MUL_FF_DIAG, int MUL_FF_CSA_MID,
        int MUL_USE_KARATSUBA,
        int MUL_K_PIPE_DSP, int MUL_K_PIPE_PRE,
        int MUL_K_PIPE_POST, int MUL_K_PIPE_MID,
        int MUL_FF_CPA = 0
    );
        return intmul_wrapper_pkg::latency(
            LOGQ, LOGQ,
            MUL_FF_IN, MUL_FF_MUL, MUL_FF_OUT,
            MUL_USE_CSA, MUL_FF_CSA,
            MUL_MORE_DSP, MUL_NON_STD,
            MUL_FF_ADD, MUL_FF_DIAG, MUL_FF_CSA_MID,
            MUL_USE_KARATSUBA,
            MUL_K_PIPE_DSP, MUL_K_PIPE_PRE,
            MUL_K_PIPE_POST, MUL_K_PIPE_MID
        ) + MUL_FF_CPA;
    endfunction

    // -- LogJumps reduction latency ---------------------------
    //    When FIXED_Q = 1, RM_MUL_LAT = 0 (rho*mu multipliers
    //    eliminated), so Path A is shorter.
    //
    //    LOGR is the Montgomery constant width: the smallest
    //    multiple of LOGW that is >= LOGQ.
    function automatic int unsigned lj_latency(
        int LOGW, int LOGQ,
        int LOGR,
        int LJ_FF_IN, int LJ_FF_MUL, int LJ_FF_OUT,
        int LJ_USE_CSA, int LJ_FF_CSA,
        int LJ_MORE_DSP, int LJ_NON_STD,
        int LJ_FF_ADD, int LJ_FF_DIAG, int LJ_FF_CSA_MID,
        int LJ_FF_MR_POST, int LJ_FF_RM,
        int LJ_MT_REG_PERIOD, int LJ_MT_REG_IN, int LJ_MT_REG_OUT,
        int LJ_MT_USE_CSA = 0,
        int LJ_DSP_SMALL = 1,
        // -- modacc mode parameters --
        int ACC_USE_ADDTREE   = 1,
        int ACC_MAX_COND_SUB  = LOGR / LOGW - 1,
        int ACC_AT_REG_PERIOD = 3,
        int ACC_AT_REG_IN     = 1,
        int ACC_AT_REG_OUT    = 1,
        int ACC_AT_USE_CSA    = 1,
        int ACC_CS_REG_PERIOD = 1,
        int ACC_CS_REG_OUT    = 1,
        int FIXED_Q = 0,
        int ACC_AT_FF_ADD = 0,
        int LJ_FF_JOIN_ADD = 0
    );
        return logjumps_pkg::logjumps_latency(
            LOGW, LOGQ, LOGR,
            LJ_FF_IN, LJ_FF_MUL, LJ_FF_OUT,
            LJ_USE_CSA, LJ_FF_CSA,
            LJ_MORE_DSP, LJ_NON_STD,
            LJ_FF_ADD, LJ_FF_DIAG, LJ_FF_CSA_MID,
            LJ_FF_MR_POST, LJ_FF_RM,
            LJ_MT_REG_PERIOD, LJ_MT_REG_IN, LJ_MT_REG_OUT,
            LJ_MT_USE_CSA, LJ_DSP_SMALL,
            ACC_USE_ADDTREE,
            ACC_MAX_COND_SUB,
            ACC_AT_REG_PERIOD,
            ACC_AT_REG_IN,
            ACC_AT_REG_OUT,
            ACC_AT_USE_CSA,
            ACC_CS_REG_PERIOD,
            ACC_CS_REG_OUT,
            FIXED_Q,
            ACC_AT_FF_ADD,
            LJ_FF_JOIN_ADD
        );
    endfunction

    // -- Total modmul pipeline latency ------------------------
    //    When FIXED_Q = 1, LJ_LAT may be shorter because the
    //    rho*mu multiplier latency drops to zero.
    //
    //    LOGR is the Montgomery constant width: the smallest
    //    multiple of LOGW that is >= LOGQ.
    function automatic int unsigned modmul_latency(
        int LOGW, int LOGQ,
        int LOGR,
        // Big multiplier
        int MUL_FF_IN, int MUL_FF_MUL, int MUL_FF_OUT,
        int MUL_USE_CSA, int MUL_FF_CSA,
        int MUL_MORE_DSP, int MUL_NON_STD,
        int MUL_FF_ADD, int MUL_FF_DIAG, int MUL_FF_CSA_MID,
        int MUL_USE_KARATSUBA,
        int MUL_K_PIPE_DSP, int MUL_K_PIPE_PRE,
        int MUL_K_PIPE_POST, int MUL_K_PIPE_MID,
        // LogJumps reduction
        int LJ_FF_IN, int LJ_FF_MUL, int LJ_FF_OUT,
        int LJ_USE_CSA, int LJ_FF_CSA,
        int LJ_MORE_DSP, int LJ_NON_STD,
        int LJ_FF_ADD, int LJ_FF_DIAG, int LJ_FF_CSA_MID,
        int LJ_FF_MR_POST, int LJ_FF_RM,
        int LJ_MT_REG_PERIOD, int LJ_MT_REG_IN, int LJ_MT_REG_OUT,
        int LJ_MT_USE_CSA = 0,
        int LJ_DSP_SMALL = 1,
        // modacc mode parameters
        int ACC_USE_ADDTREE   = 1,
        int ACC_MAX_COND_SUB  = LOGR / LOGW - 1,
        int ACC_AT_REG_PERIOD = 3,
        int ACC_AT_REG_IN     = 1,
        int ACC_AT_REG_OUT    = 1,
        int ACC_AT_USE_CSA    = 1,
        int ACC_CS_REG_PERIOD = 1,
        int ACC_CS_REG_OUT    = 1,
        // Fixed-modulus mode
        int FIXED_Q = 0,
        int ACC_AT_FF_ADD = 0,
        int LJ_FF_JOIN_ADD = 0,
        // Post-CPA pipeline register
        int MUL_FF_CPA = 0
    );
        return mul_latency(
                   LOGQ,
                   MUL_FF_IN, MUL_FF_MUL, MUL_FF_OUT,
                   MUL_USE_CSA, MUL_FF_CSA,
                   MUL_MORE_DSP, MUL_NON_STD,
                   MUL_FF_ADD, MUL_FF_DIAG, MUL_FF_CSA_MID,
                   MUL_USE_KARATSUBA,
                   MUL_K_PIPE_DSP, MUL_K_PIPE_PRE,
                   MUL_K_PIPE_POST, MUL_K_PIPE_MID,
                   MUL_FF_CPA
               )
             + lj_latency(
                   LOGW, LOGQ, LOGR,
                   LJ_FF_IN, LJ_FF_MUL, LJ_FF_OUT,
                   LJ_USE_CSA, LJ_FF_CSA,
                   LJ_MORE_DSP, LJ_NON_STD,
                   LJ_FF_ADD, LJ_FF_DIAG, LJ_FF_CSA_MID,
                   LJ_FF_MR_POST, LJ_FF_RM,
                   LJ_MT_REG_PERIOD, LJ_MT_REG_IN, LJ_MT_REG_OUT,
                   LJ_MT_USE_CSA, LJ_DSP_SMALL,
                   ACC_USE_ADDTREE, ACC_MAX_COND_SUB,
                   ACC_AT_REG_PERIOD, ACC_AT_REG_IN,
                   ACC_AT_REG_OUT, ACC_AT_USE_CSA,
                   ACC_CS_REG_PERIOD, ACC_CS_REG_OUT,
                   FIXED_Q,
                   ACC_AT_FF_ADD,
                   LJ_FF_JOIN_ADD
               );
    endfunction

endpackage