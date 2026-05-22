// --------------------------------------------------------------
// Package : dsp_pkg
// Purpose : DSP primitive port-width constants
//
//   "Signed" widths (DSP_A, DSP_B, ...) include the sign bit.
//   "Unsigned" widths (DSP_A_U, DSP_B_U, ...) are one less and
//   represent the maximum unsigned operand that fits in the port.
//   DSP_M_U is the unsigned product width (A_U + B_U).
// --------------------------------------------------------------

package dsp_pkg;

    localparam int DSP_A = 27;
    localparam int DSP_B = 18;
    localparam int DSP_C = 48;
    localparam int DSP_P = 48;

    localparam int DSP_A_U = DSP_A - 1;
    localparam int DSP_B_U = DSP_B - 1;
    localparam int DSP_C_U = DSP_C - 1;
    localparam int DSP_M_U = DSP_A_U + DSP_B_U;

endpackage
