//
// addtree_pkg - Package for the addtree binary reduction tree
//
// Provides compile-time helper functions for computing tree geometry,
// latency, and parameter validation.
//
// Supports both binary-reduction mode (default) and carry-save
// compression mode (USE_CSA = 1).
//

package addtree_pkg;

    // ---------------------------------------------------------------
    // Binary-reduction helpers
    // ---------------------------------------------------------------

    // stage_width - Number of elements at binary tree stage s
    //
    //   stage 0 -> n  (original input count)
    //   stage s -> ceil(stage_width(n, s-1) / 2)
    // ---------------------------------------------------------------
    function automatic int unsigned stage_width(
        int unsigned n,
        int unsigned s
    );
        for (int unsigned i = 0; i < s; i++)
            n = (n + 1) / 2;
        return n;
    endfunction

    // ---------------------------------------------------------------
    // num_stages - Number of binary-reduction stages to reduce
    //              n inputs down to 1
    // ---------------------------------------------------------------
    function automatic int unsigned num_stages(int unsigned n);
        int unsigned s = 0;
        while (n > 1) begin
            n = (n + 1) / 2;
            s = s + 1;
        end
        return s;
    endfunction

    // ---------------------------------------------------------------
    // Carry-save compression helpers
    // ---------------------------------------------------------------

    // csa_stage_width - Number of operands at CSA stage s
    //
    //   Each 3-to-2 compressor turns 3 operands into 2.
    //   Leftover operands (0, 1, or 2) pass through unchanged.
    //
    //   stage 0 -> n
    //   stage s -> 2 * floor(prev / 3) + (prev % 3)
    function automatic int unsigned csa_stage_width(
        int unsigned n,
        int unsigned s
    );
        for (int unsigned i = 0; i < s; i++)
            n = 2 * (n / 3) + (n % 3);
        return n;
    endfunction

    // csa_num_stages - Number of 3-to-2 compression stages
    //                  to reduce n operands down to <= 2
    function automatic int unsigned csa_num_stages(int unsigned n);
        int unsigned s = 0;
        while (n > 2) begin
            n = 2 * (n / 3) + (n % 3);
            s = s + 1;
        end
        return s;
    endfunction

    // total_stages - Unified stage count for pipeline calculations
    //
    //   Binary mode:  num_stages(n)             addition levels
    //   CSA mode:     csa_num_stages(n) + 1     compression levels + final adder
    function automatic int unsigned total_stages(
        int unsigned num_inputs,
        bit          use_csa
    );
        if (use_csa && num_inputs > 2)
            return csa_num_stages(num_inputs) + 1;
        else
            return num_stages(num_inputs);
    endfunction

    // ---------------------------------------------------------------
    // addtree_latency - Total pipeline latency in clock cycles
    //
    //   latency = REG_IN
    //           + (number of intermediate pipeline registers)
    //           + REG_OUT  (only if not merged with last intermediate)
    //
    // The last intermediate register is merged with REG_OUT when the
    // total stage count is an exact multiple of REG_PERIOD, avoiding
    // a redundant cycle.
    //
    // In CSA mode the total stage count includes the compression
    // stages plus one final binary addition stage.
    // ---------------------------------------------------------------
    function automatic int unsigned addtree_latency(
        int unsigned num_inputs,
        int unsigned reg_period,
        bit          reg_in,
        bit          reg_out,
        bit          use_csa = 0,
        bit          ff_add  = 0
    );
        int unsigned ns  = total_stages(num_inputs, use_csa);
        int unsigned lat = 0;

        if (ns == 0) return 0;  // 0 or 1 inputs -> passthrough

        // Input register
        lat += (reg_in) ? 1 : 0;

        // Intermediate pipeline registers
        if (reg_period > 0)
            lat += ns / reg_period;

        // FF_ADD: split the final binary adder (CSA mode only)
        // Adds one pipeline stage between the lower-half and upper-half
        // of the carry-propagate addition that resolves the last CSA pair.
        if (ff_add && use_csa && num_inputs > 2)
            lat += 1;

        // Output register (only if last stage doesn't already have one)
        if (reg_out && !(reg_period > 0 && (ns % reg_period) == 0))
            lat += 1;

        return lat;
    endfunction

    // ---------------------------------------------------------------
    // check_params - Parameter validation (call from initial block)
    //
    // Emits $fatal if REG_PERIOD exceeds the total stage count,
    // since no intermediate register would ever be placed and the
    // parameter is likely a mistake.
    // ---------------------------------------------------------------
    function automatic void check_params(
        int unsigned num_inputs,
        int unsigned reg_period,
        bit          use_csa = 0
    );
        int unsigned ns = total_stages(num_inputs, use_csa);

        if (reg_period > 0 && ns > 0 && reg_period > ns)
            $fatal(1,
                {"addtree: REG_PERIOD (%0d) exceeds total stage count (%0d). ",
                 "For %0d inputs the tree has %0d stages",
                 "%s",
                 ".  Use REG_PERIOD in [1, %0d], or 0 for purely combinational."},
                reg_period, ns, num_inputs, ns,
                (use_csa ? " (CSA + final adder)" : ""),
                ns);
    endfunction

endpackage