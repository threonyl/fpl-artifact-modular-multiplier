package mac_std_pkg;

    import dsp_pkg::*;

    // ----------------------------------------------------------------
    //  E-input mode: disabled, added to product, subtracted from product
    // ----------------------------------------------------------------
    typedef enum int {
        E_DISABLED = 0,
        E_ADD      = 1,
        E_SUB      = 2
    } mode_e_t;

    // ----------------------------------------------------------------
    //  Collected parameters
    //
    //  Pipeline stages (when USE_CSA = 1):
    //    FF_IN   -> register inputs
    //    FF_MUL  -> register partial products
    //    FF_DIAG -> register diagonal bins before CSA
    //    FF_CSA_MID -> register mid-CSA (split tree into two phases)
    //    FF_CSA  -> register CSA tree output
    //    FF_ADD  -> register carry-chain midpoint of final addition
    //    FF_OUT  -> register final result
    //
    //  PIPE_DSP (0-3):
    //    When > 0, each DSP tile uses dsp_mul with explicit
    //    DSP48E2-internal register control (AREG/BREG/MREG/PREG).
    //    This replaces FF_IN_A/FF_IN_B/FF_MUL for the multiply
    //    path - those three are IGNORED when PIPE_DSP > 0.
    //    When == 0 (default), the original fabric register
    //    behaviour controlled by FF_IN/FF_MUL is preserved.
    // ----------------------------------------------------------------
    typedef struct packed {
        int loga;
        int logb;
        int mode_e;
        int loge;
        int ff_in_a;
        int ff_in_b;
        int ff_in_e;
        int ff_mul;
        int ff_out;
        int ff_csa;
        int use_csa;
        int ff_add;
        int ff_diag;
        int ff_csa_mid;
        int pipe_dsp;     // 0: use FF_IN/FF_MUL  >0: use dsp_mul (see dsp_mul.sv)
    } mac_std_params_t;

    // ----------------------------------------------------------------
    //  DSP partitioning helpers
    //
    //  The wider operand is always mapped to port A of the DSP, the
    //  narrower to port B.  n_tiles_a/b give the number of DSP slices
    //  needed along each dimension.
    // ----------------------------------------------------------------
    function automatic int dsp_a_width(input mac_std_params_t p);
        return (p.loga >= p.logb) ? DSP_A_U : DSP_B_U;
    endfunction

    function automatic int dsp_b_width(input mac_std_params_t p);
        return (p.loga >= p.logb) ? DSP_B_U : DSP_A_U;
    endfunction

    function automatic int n_tiles_a(input mac_std_params_t p);
        return ((p.loga - 1) / dsp_a_width(p)) + 1;
    endfunction

    function automatic int n_tiles_b(input mac_std_params_t p);
        return ((p.logb - 1) / dsp_b_width(p)) + 1;
    endfunction

    // Total number of partial-product diagonals
    function automatic int n_diagonals(input mac_std_params_t p);
        return n_tiles_a(p) + n_tiles_b(p) - 1;
    endfunction

    // ----------------------------------------------------------------
    //  Output-width calculations
    //
    //  logd : width of the raw A*B product (no E contribution)
    //  logc : width of the final output C
    // ----------------------------------------------------------------
    function automatic int logd(input mac_std_params_t p);
        return p.loga + p.logb;
    endfunction

    function automatic int logc(input mac_std_params_t p);
        int ld = logd(p);
        case (p.mode_e)
            0:       return ld;                                              // no E
            1:       return (ld > p.loge) ? ld + 1 : p.loge + 1;            // A*B + E
            2:       return (ld >= p.loge) ? ld + 2 : p.loge + 1;           // A*B - E
            default: return ld;
        endcase
    endfunction

    // ----------------------------------------------------------------
    //  Pipeline latency (in clock cycles)
    // ----------------------------------------------------------------
    function automatic int latency(input mac_std_params_t p);
        int lat = 0;
        if (p.pipe_dsp > 0) begin
            // dsp_mul handles input + multiply registers internally;
            // FF_IN_A/FF_IN_B/FF_MUL are ignored.
            lat += p.pipe_dsp;
        end else begin
            lat += int'((p.ff_in_a != 0) || (p.ff_in_b != 0) || ((p.ff_in_e != 0) && (p.mode_e != 0)));
            lat += p.ff_mul;
        end
        lat += (p.ff_diag    & p.use_csa);
        lat += (p.ff_csa_mid & p.use_csa);
        lat += (p.ff_csa     & p.use_csa);
        lat += (p.ff_add     & p.use_csa);
        lat += p.ff_out;
        return lat;
    endfunction

endpackage
