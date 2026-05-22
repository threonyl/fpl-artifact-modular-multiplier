// --------------------------------------------------------------
// Package  : karatsuba_mul_pkg
// Purpose  : Helper functions for parameterizing karatsuba_mul
// --------------------------------------------------------------

package karatsuba_mul_pkg;

    import dsp_pkg::*;
    import mac_std_pkg::*;

    // -- Maximum operand width that fits in a single schoolbook
    //    base case (DSP tile grid).
    localparam int unsigned KARATSUBA_THRESHOLD = 98;

    // ----------------------------------------------------------
    //  Collected parameters
    //
    //  Pipeline stages:
    //    PIPE_DSP  -> DSP-internal registers (AREG/BREG/MREG/PREG)
    //    PIPE_PRE  -> register after Karatsuba pre-additions
    //    PIPE_POST -> register after Karatsuba recomposition CPA
    //    PIPE_MID  -> register between CSA tree and CPA (0 merges them)
    // ----------------------------------------------------------
    typedef struct packed {
        int loga;
        int logb;
        int pipe_dsp;
        int pipe_pre;
        int pipe_post;
        int pipe_mid;
    } karatsuba_mul_params_t;

    // ----------------------------------------------------------
    //  Decomposition helpers
    // ----------------------------------------------------------

    // Split point for Karatsuba decomposition.
    // Splits the larger operand roughly in half.
    function automatic int unsigned karatsuba_split(
        int unsigned LOGA,
        int unsigned LOGB
    );
        int unsigned max_ab = (LOGA > LOGB) ? LOGA : LOGB;
        return (max_ab + 1) / 2;
    endfunction

    // Should we use schoolbook (base case)?
    function automatic bit is_base_case(
        int unsigned LOGA,
        int unsigned LOGB
    );
        return (LOGA <= KARATSUBA_THRESHOLD) && (LOGB <= KARATSUBA_THRESHOLD);
    endfunction

    // ----------------------------------------------------------
    //  DSP partitioning helpers
    // ----------------------------------------------------------

    // DSP count for a schoolbook multiplier
    function automatic int unsigned schoolbook_dsp_count(input karatsuba_mul_params_t p);
        int unsigned na = (p.loga + DSP_A_U - 1) / DSP_A_U;
        int unsigned nb = (p.logb + DSP_B_U - 1) / DSP_B_U;
        return na * nb;
    endfunction

    // Number of partial products in schoolbook
    function automatic int unsigned schoolbook_num_pp(input karatsuba_mul_params_t p);
        return schoolbook_dsp_count(p);
    endfunction

    // ----------------------------------------------------------
    //  Output-width calculation
    // ----------------------------------------------------------

    function automatic int unsigned logc(input karatsuba_mul_params_t p);
        return p.loga + p.logb;
    endfunction

    // ----------------------------------------------------------
    //  Pipeline latency (in clock cycles)
    // ----------------------------------------------------------

    // Latency of the schoolbook base case (mac_std).
    //
    // Builds a mac_std_params_t matching the exact parameters used
    // by the gen_base instantiation in karatsuba_mul and delegates
    // to mac_std_pkg::latency.  This ensures the latency calculation
    // stays in sync with mac_std regardless of future changes.
    //
    // Base-case mac_std configuration:
    //   FF_IN_A/B = 0  (input registers handled by PIPE_DSP/AREG/BREG)
    //   FF_MUL    = 0  (multiply register handled by PIPE_DSP/MREG)
    //   FF_OUT    = 1  (CPA output register always on)
    //   USE_CSA   = 1  (CSA tree reduction)
    //   FF_CSA    = PIPE_MID  (CSA-to-CPA pipeline)
    //   FF_DIAG   = 0, FF_CSA_MID = 0, FF_ADD = 0
    //   PIPE_DSP  = PIPE_DSP
    function automatic int unsigned schoolbook_latency(input karatsuba_mul_params_t p);
        mac_std_params_t mp = '{
            loga:       p.loga,
            logb:       p.logb,
            mode_e:     int'(mac_std_pkg::E_DISABLED),
            loge:       0,
            ff_in_a:    0,
            ff_in_b:    0,
            ff_in_e:    0,
            ff_mul:     0,
            ff_out:     1,
            ff_csa:     p.pipe_mid,
            use_csa:    1,
            ff_add:     0,
            ff_diag:    0,
            ff_csa_mid: 0,
            pipe_dsp:   p.pipe_dsp
        };
        return mac_std_pkg::latency(mp);
    endfunction

    // Latency of karatsuba_mul.
    //
    //   Iteratively follows the critical (cross-term) path through
    //   the Karatsuba decomposition tree.
    //
    //   At each level there are three parallel sub-multiplies whose
    //   operand widths differ:
    //     z0: HALF x HALF            (low x low)
    //     z2: (LA-HALF) x (LB-HALF)  (high x high)
    //     zx: (max_a+1) x (max_b+1)  (cross term, always widest)
    //
    //   Because the cross-term operands are strictly wider than both
    //   z0 and z2 in each dimension, zx always has >= the number of
    //   decomposition levels, making it the critical path.
    //
    //   Each Karatsuba level adds: PIPE_PRE + PIPE_MID + PIPE_POST
    //
    //   NOTE: the original version tracked the z0 path (la=split,
    //   lb=split) which UNDER-COUNTS when the cross term exceeds the
    //   schoolbook threshold by a few bits - e.g. for LOGQ=391 where
    //   the cross term at the second level is 100 bits (> 98 threshold)
    //   while z0/z2 are 98-99 bits.
    function automatic int unsigned latency(input karatsuba_mul_params_t p);
        int unsigned levels = 0;
        int unsigned la = p.loga;
        int unsigned lb = p.logb;
        int unsigned half;
        int unsigned w_alo, w_ahi, w_blo, w_bhi;

        while (!is_base_case(la, lb)) begin
            half  = karatsuba_split(la, lb);
            w_alo = half;
            w_ahi = la - half;
            w_blo = half;
            w_bhi = lb - half;
            // Follow the cross-term (widest) path
            la = ((w_alo > w_ahi) ? w_alo : w_ahi) + 1;
            lb = ((w_blo > w_bhi) ? w_blo : w_bhi) + 1;
            levels++;
        end

        begin
            // Compute base-case latency using the leaf operand widths
            karatsuba_mul_params_t leaf = '{
                int'(la), int'(lb),
                p.pipe_dsp, p.pipe_pre, p.pipe_post, p.pipe_mid
            };
            return levels * (p.pipe_pre + p.pipe_mid + p.pipe_post)
                 + schoolbook_latency(leaf);
        end
    endfunction

    // ----------------------------------------------------------
    //  Latency of karatsuba_multiplier (standalone top-level wrapper)
    //    Input register (PIPE_IN) + core + output register (PIPE_OUT)
    // ----------------------------------------------------------
    function automatic int unsigned karatsuba_multiplier_latency(
        int unsigned LOGA,
        int unsigned LOGB,
        int unsigned PIPE_DSP,
        int unsigned PIPE_PRE,
        int unsigned PIPE_POST,
        int unsigned PIPE_MID,
        int unsigned PIPE_IN,
        int unsigned PIPE_OUT
    );
        karatsuba_mul_params_t p = '{LOGA, LOGB, PIPE_DSP, PIPE_PRE, PIPE_POST, PIPE_MID};
        return PIPE_IN + latency(p) + PIPE_OUT;
    endfunction

endpackage