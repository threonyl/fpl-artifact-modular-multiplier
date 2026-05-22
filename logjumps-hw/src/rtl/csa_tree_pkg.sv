// --------------------------------------------------------------
// Package  : csa_tree_pkg
// Purpose  : Helper functions for parameterizing csa_tree
// --------------------------------------------------------------

package csa_tree_pkg;

    // -- Output width --------------------------------------------
    // Returns the output width required for a CSA tree that sums
    // NUM_INPUTS operands, each INPUT_WIDTH bits wide.
    //   output_width = INPUT_WIDTH + ceil(log2(NUM_INPUTS))
    function automatic int unsigned csa_tree_output_width(
        int unsigned INPUT_WIDTH,
        int unsigned NUM_INPUTS
    );
        return INPUT_WIDTH + (NUM_INPUTS > 1 ? $clog2(NUM_INPUTS) : 0);
    endfunction

    // -- Tree depth (number of compression stages) ---------------
    // Each stage maps  N  ->  2*floor(N/3) + (N mod 3)
    // and we count stages until the result is <= 2.
    function automatic int unsigned csa_tree_depth(
        int unsigned NUM_INPUTS
    );
        int unsigned depth = 0;
        int unsigned n     = NUM_INPUTS;
        while (n > 2) begin
            n     = 2 * (n / 3) + (n % 3);
            depth = depth + 1;
        end
        return depth;
    endfunction

    // -- Latency -------------------------------------------------
    // The tree is purely combinational (no pipeline registers).
    // Returns 0 for consistency with other *_latency() helpers.
    function automatic int unsigned csa_tree_latency(
        int unsigned NUM_INPUTS
    );
        return 0;
    endfunction

endpackage
