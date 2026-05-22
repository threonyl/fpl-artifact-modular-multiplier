// --------------------------------------------------------------
// Package  : csa_2_pkg
// Purpose  : Helper functions for parameterizing csa_2
// --------------------------------------------------------------

package csa_2_pkg;

    // The 3-to-2 compressor is purely combinational.
    // Provided for consistency so top-level latency expressions
    // can reference it explicitly.
    function automatic int unsigned csa_2_latency();
        return 0;
    endfunction

    // Output width of a carry-save compressor equals its input width.
    // The carry vector is simply shifted left by one bit:
    //   sum[WIDTH-1]  is always 0   (no sum in the MSB)
    //   carry[0]      is always 0   (no carry-in at the LSB)
    function automatic int unsigned csa_2_output_width(
        int unsigned INPUT_WIDTH
    );
        return INPUT_WIDTH;
    endfunction

endpackage
