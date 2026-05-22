// --------------------------------------------------------------
// Package : intmul_nonstd_BBAxBBA_pkg
// Purpose : Parameters and latency calculation for the
//           BBAxBBA non-standard integer multiplier.
//
//   "BBA" refers to the operand partitioning scheme:
//     bits [B_U-1      : 0]       ->  B-port width  (low)
//     bits [2*B_U-1    : B_U]     ->  B-port width  (mid)
//     bits [A_U+2*B_U-1: 2*B_U]   ->  A-port width  (high)
//
//   Each operand is therefore up to (A_U + 2*B_U) bits wide.
// --------------------------------------------------------------

package intmul_nonstd_BBAxBBA_pkg;

    import dsp_pkg::*;

    typedef struct packed {
        int LOGA;
        int LOGB;
        int FF_IN;
        int FF_MUL;
        int FF_OUT;
        int FF_CSA;
        int USE_CSA;
        int MORE_DSP;
    } params_t;

    function automatic int latency(input params_t p);
        return p.FF_IN + p.FF_MUL + p.FF_OUT + (p.FF_CSA & p.USE_CSA);
    endfunction

    // Returns 1 if the operand widths fit the BBAxBBA decomposition,
    // 0 otherwise.  Usable at generate time in both the module
    // itself (to emit $fatal) and in the wrapper's routing logic.
    //
    // Lower bounds: A is split at DSP_A_U, 2*DSP_B_U, and DSP_M_U,
    // so both operands must exceed DSP_M_U (= DSP_A_U + DSP_B_U)
    // bits - otherwise the high-part slices would be empty.
    // Upper bounds: each operand fits three chunks (B+B+A),
    // i.e. DSP_A_U + 2*DSP_B_U bits.
    function automatic bit valid(int LOGA, int LOGB);
        return (LOGA > DSP_M_U) && (LOGB > DSP_M_U) &&
               (LOGA <= DSP_A_U + 2 * DSP_B_U) &&
               (LOGB <= DSP_A_U + 2 * DSP_B_U);
    endfunction

endpackage
