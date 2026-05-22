// --------------------------------------------------------------
// Package : intmul_wrapper_pkg
// Purpose : Parameter types and latency computation for the
//           intmul_wrapper multiplier selection layer.
// --------------------------------------------------------------

package intmul_wrapper_pkg;

    import dsp_pkg::*;
    import mac_std_pkg::*;
    import intmul_nonstd_BBxAB_pkg::*;
    import intmul_nonstd_BBAxBBA_pkg::*;
    import karatsuba_mul_pkg::*;

    // -- Topology selector ---------------------------------------
    typedef enum int {
        TOPO_STD,        // mac_std              - generic DSP tiling
        TOPO_BBxAB,      // intmul_nonstd_BBxAB  - 3 DSPs + 1 small
        TOPO_BBAxBBA,    // intmul_nonstd_BBAxBBA - 8 DSPs + 1 overlap
        TOPO_KARATSUBA   // karatsuba_multiplier  - recursive Karatsuba
    } topo_t;

    // Determine which sub-module a given (LOGA, LOGB, NON_STD)
    // configuration maps to.  When USE_KARATSUBA is active the
    // Karatsuba topology is selected unconditionally.  Otherwise,
    // when NON_STD is active the function picks the smallest
    // non-standard topology whose validity constraints (both
    // lower and upper bounds) are satisfied; otherwise it falls
    // back to the standard tiled multiplier.
    //
    // Priority: USE_KARATSUBA > NON_STD > fallback to STD.
    //
    // BBxAB validity  (after orienting min->A, max->B):
    //   DSP_A_U < A <= 2*DSP_B_U   and   DSP_A_U < B <= DSP_A_U+DSP_B_U
    //
    // BBAxBBA validity:
    //   DSP_M_U < A <= DSP_A_U+2*DSP_B_U   and   same for B
    //
    function automatic topo_t select_topo(
        input int loga, logb, non_std, use_karatsuba
    );
        if (use_karatsuba != 0)
            return TOPO_KARATSUBA;

        if (non_std == 0)
            return TOPO_STD;

        // BBxAB expects the narrower operand on port A.
        // Orient so that lo <= hi, then test the canonical form.
        begin
            int lo = (loga <= logb) ? loga : logb;
            int hi = (loga <= logb) ? logb : loga;

            if (intmul_nonstd_BBxAB_valid(lo, hi))
                return TOPO_BBxAB;
        end

        if (intmul_nonstd_BBAxBBA_pkg::valid(loga, logb))
            return TOPO_BBAxBBA;

        // Operands don't fit any non-standard topology - fall back.
        return TOPO_STD;
    endfunction

    function automatic int latency(
        input int loga, logb,
        input int ff_in, ff_mul, ff_out,
        input int use_csa, ff_csa,
        input int more_dsp, non_std,
        input int ff_add, ff_diag, ff_csa_mid,
        input int use_karatsuba,
        input int k_pipe_dsp, k_pipe_pre, k_pipe_post,
        input int k_pipe_mid
    );
        topo_t topo = select_topo(loga, logb, non_std, use_karatsuba);

        case (topo)
            TOPO_KARATSUBA: begin
                karatsuba_mul_params_t kp = '{
                    loga, logb,
                    k_pipe_dsp, k_pipe_pre, k_pipe_post,
                    k_pipe_mid
                };
                return karatsuba_mul_pkg::latency(kp);
            end

            TOPO_STD: begin
                mac_std_params_t p = '{
                    loga:    loga,    logb:    logb,
                    mode_e:  int'(E_DISABLED), loge: 0,
                    ff_in_a: ff_in,   ff_in_b: ff_in,
                    ff_in_e: 0,       ff_mul:  ff_mul,
                    ff_out:  ff_out,   ff_csa:  ff_csa,
                    use_csa: use_csa,  ff_add:  ff_add,
                    ff_diag: ff_diag,  ff_csa_mid: ff_csa_mid,
                    pipe_dsp: 0
                };
                return mac_std_pkg::latency(p);
            end

            TOPO_BBxAB: begin
                // Orient so the narrower operand is on port A,
                // matching the swap logic in the wrapper module.
                int la = (loga <= logb) ? loga : logb;
                int lb = (loga <= logb) ? logb : loga;
                intmul_nonstd_BBxAB_params_t p = '{
                    la, lb, ff_in, ff_mul, ff_out,
                    ff_csa, use_csa, more_dsp
                };
                return intmul_nonstd_BBxAB_lat(p);
            end

            TOPO_BBAxBBA: begin
                intmul_nonstd_BBAxBBA_pkg::params_t p = '{
                    loga, logb, ff_in, ff_mul, ff_out,
                    ff_csa, use_csa, more_dsp
                };
                return intmul_nonstd_BBAxBBA_pkg::latency(p);
            end

            default:
                return 0;
        endcase
    endfunction

endpackage
