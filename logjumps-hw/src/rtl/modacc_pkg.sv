// --------------------------------------------------------------
// Package : modacc_pkg
// Purpose : Compile-time helpers for the modacc module.
//
//   Supports two operating modes:
//
//   (A) Legacy mode (USE_ADDTREE = 0):
//       Binary reduction tree of modadd cells.  Each tree level
//       fuses addition with modular reduction.
//
//   (B) Addtree + conditional-subtraction mode (USE_ADDTREE = 1):
//       Phase 1 - Plain summation via addtree (optionally CSA).
//       Phase 2 - Binary-search conditional subtraction chain
//                 that subtracts 2^k * q for k = K-1 down to 0,
//                 where K = clog2(MAX_COND_SUB + 1).
//
//       Example (MAX_COND_SUB = 12, K = 4):
//         Stage 0: if val >= 8q then val -= 8q
//         Stage 1: if val >= 4q then val -= 4q
//         Stage 2: if val >= 2q then val -= 2q
//         Stage 3: if val >= 1q then val -= 1q
//
// Author : Selim Kirbiyik, TU Graz
// --------------------------------------------------------------

package modacc_pkg;

    import modadd_pkg::*;
    import addtree_pkg::*;

    // ---------------------------------------------------------------
    // Utility: compile-time ceiling-log2
    //
    //   clog2_val(0) = 0,  clog2_val(1) = 0,  clog2_val(2) = 1,
    //   clog2_val(3) = 2,  clog2_val(4) = 2,  clog2_val(5) = 3, ...
    // ---------------------------------------------------------------
    function automatic int unsigned clog2_val(int unsigned n);
        int unsigned s, v;
        if (n <= 1) return 0;
        s = 0;
        v = n - 1;
        while (v > 0) begin
            v = v >> 1;
            s = s + 1;
        end
        return s;
    endfunction

    // ---------------------------------------------------------------
    // Legacy-mode helpers (binary reduction tree of modadd cells)
    // ---------------------------------------------------------------

    // Number of elements at a given tree stage.
    //   stage 0 -> n  (the original input count)
    //   stage s -> ceil(stage(s-1) / 2)
    function automatic int unsigned stage_width(
        int unsigned n,
        int unsigned s
    );
        for (int unsigned i = 0; i < s; i++)
            n = (n + 1) / 2;
        return n;
    endfunction

    // Number of binary-reduction stages needed to reduce n inputs to 1.
    function automatic int unsigned num_stages(int unsigned n);
        int unsigned s = 0;
        while (n > 1) begin
            n = (n + 1) / 2;
            s = s + 1;
        end
        return s;
    endfunction

    // Legacy-mode pipeline latency:  num_stages * modadd_latency.
    function automatic int unsigned modacc_legacy_latency(
        int unsigned NUM_INPUTS,
        bit          REG_IN,
        bit          REG_OUT,
        bit          REG_ADD,
        bit          CONC_ADDSUB
    );
        int unsigned ml;
        ml = modadd_pkg::modadd_latency(REG_IN, REG_OUT, REG_ADD, CONC_ADDSUB);
        return num_stages(NUM_INPUTS) * ml;
    endfunction

    // ---------------------------------------------------------------
    // Addtree-mode helpers (plain sum + conditional subtraction)
    // ---------------------------------------------------------------

    // Extra bits required for the plain sum of NUM_INPUTS operands.
    //   SUM_W = LOGQ + sum_extra_bits(NUM_INPUTS)
    function automatic int unsigned sum_extra_bits(int unsigned num_inputs);
        if (num_inputs <= 1) return 0;
        return clog2_val(num_inputs);
    endfunction

    // Number of conditional-subtraction stages for a given
    // MAX_COND_SUB value.  Equals clog2(MAX_COND_SUB + 1).
    //
    //   MAX_COND_SUB =  0 -> 0 stages (no subtraction)
    //   MAX_COND_SUB =  1 -> 1 stage  (check 1q)
    //   MAX_COND_SUB =  3 -> 2 stages (check 2q, 1q)
    //   MAX_COND_SUB = 12 -> 4 stages (check 8q, 4q, 2q, 1q)
    //   MAX_COND_SUB = 16 -> 5 stages (check 16q, 8q, 4q, 2q, 1q)
    function automatic int unsigned num_cond_sub_stages(int unsigned max_cond_sub);
        if (max_cond_sub == 0) return 0;
        return clog2_val(max_cond_sub + 1);
    endfunction

    // Conditional-subtraction chain pipeline latency.
    //
    //   Pipeline registers follow the same convention as addtree:
    //     CS_REG_PERIOD = 0  -> purely combinational chain
    //     CS_REG_PERIOD = 1  -> register after every stage
    //     CS_REG_PERIOD = N  -> register after every N-th stage
    //
    //   CS_REG_OUT is merged with the last intermediate register
    //   when num_cs is an exact multiple of CS_REG_PERIOD.
    function automatic int unsigned cond_sub_latency(
        int unsigned max_cond_sub,
        int unsigned cs_reg_period,
        bit          cs_reg_out
    );
        int unsigned num_cs = num_cond_sub_stages(max_cond_sub);
        int unsigned lat;
        bit          last_has_reg;

        if (num_cs == 0) return 0;

        lat = 0;

        // Intermediate pipeline registers
        if (cs_reg_period > 0)
            lat = num_cs / cs_reg_period;

        // Output register (only if last stage doesn't already have one)
        last_has_reg = (cs_reg_period > 0) && ((num_cs % cs_reg_period) == 0);
        if (cs_reg_out && !last_has_reg)
            lat = lat + 1;

        return lat;
    endfunction

    // Total addtree-mode pipeline latency:
    //   addtree_latency + cond_sub_latency
    function automatic int unsigned modacc_addtree_latency(
        int unsigned NUM_INPUTS,
        int unsigned MAX_COND_SUB,
        int unsigned AT_REG_PERIOD,
        bit          AT_REG_IN,
        bit          AT_REG_OUT,
        bit          AT_USE_CSA,
        int unsigned CS_REG_PERIOD,
        bit          CS_REG_OUT,
        bit          AT_FF_ADD = 0
    );
        int unsigned at_lat;
        int unsigned cs_lat;

        at_lat = addtree_pkg::addtree_latency(
            NUM_INPUTS, AT_REG_PERIOD,
            AT_REG_IN, AT_REG_OUT, AT_USE_CSA,
            AT_FF_ADD
        );
        cs_lat = cond_sub_latency(MAX_COND_SUB, CS_REG_PERIOD, CS_REG_OUT);

        return at_lat + cs_lat;
    endfunction

    // ---------------------------------------------------------------
    // Unified latency function (backward compatible)
    //
    //   When USE_ADDTREE = 0 the addtree-mode parameters are
    //   ignored and the legacy latency is returned.
    // ---------------------------------------------------------------
    function automatic int unsigned modacc_latency(
        int unsigned NUM_INPUTS,
        bit          REG_IN,
        bit          REG_OUT,
        bit          REG_ADD,
        bit          CONC_ADDSUB,
        // -- Addtree-mode parameters (ignored when USE_ADDTREE = 0) --
        bit          USE_ADDTREE    = 0,
        int unsigned MAX_COND_SUB   = 0,
        int unsigned AT_REG_PERIOD  = 1,
        bit          AT_REG_IN      = 1,
        bit          AT_REG_OUT     = 1,
        bit          AT_USE_CSA     = 1,
        int unsigned CS_REG_PERIOD  = 1,
        bit          CS_REG_OUT     = 1,
        bit          AT_FF_ADD      = 0
    );
        if (USE_ADDTREE)
            return modacc_addtree_latency(
                NUM_INPUTS, MAX_COND_SUB,
                AT_REG_PERIOD, AT_REG_IN, AT_REG_OUT, AT_USE_CSA,
                CS_REG_PERIOD, CS_REG_OUT,
                AT_FF_ADD
            );
        else
            return modacc_legacy_latency(
                NUM_INPUTS, REG_IN, REG_OUT, REG_ADD, CONC_ADDSUB
            );
    endfunction

endpackage