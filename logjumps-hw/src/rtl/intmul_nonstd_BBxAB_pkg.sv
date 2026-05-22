// --------------------------------------------------------------
// Package : intmul_nonstd_BBxAB_pkg
// Purpose : Parameters, latency, and constraint checking for the
//           non-standard BBxAB integer multiplier.
//
// Naming convention (matches module name BBxAB):
//   "B" refers to a chunk of DSP_B_U bits (narrow DSP port)
//   "A" refers to a chunk of DSP_A_U bits (wide DSP port)
//
// Operand constraints:
//   LOGA <= 2*DSP_B_U   (two narrow-port widths)
//   LOGB <= DSP_A_U + DSP_B_U   (one wide + one narrow)
// --------------------------------------------------------------

package intmul_nonstd_BBxAB_pkg;

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
    } intmul_nonstd_BBxAB_params_t;

    function automatic int intmul_nonstd_BBxAB_lat(input intmul_nonstd_BBxAB_params_t params);
        return params.FF_IN + params.FF_MUL + params.FF_OUT + (params.FF_CSA & params.USE_CSA);
    endfunction

    // Returns 1 if the operand widths fit the BBxAB decomposition,
    // 0 otherwise.  Usable at generate time in both the module
    // itself (to emit $fatal) and in the wrapper's routing logic.
    //
    // Lower bounds: A is split at DSP_A_U and DSP_B_U, B is split
    // at DSP_A_U, so both operands must exceed DSP_A_U bits
    // (otherwise the hi-part slices would be empty / out of range).
    // Upper bounds: encode the BBxAB shape - A fits two narrow
    // chunks, B fits one wide + one narrow chunk.
    function automatic bit intmul_nonstd_BBxAB_valid(int LOGA, int LOGB);
        return (LOGA > DSP_A_U) && (LOGB > DSP_A_U) &&
               (LOGA <= 2 * DSP_B_U) &&
               (LOGB <= DSP_A_U + DSP_B_U);
    endfunction

endpackage