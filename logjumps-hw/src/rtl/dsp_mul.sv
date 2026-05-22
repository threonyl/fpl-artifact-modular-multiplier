// --------------------------------------------------------------
// Module   : dsp_mul
// Purpose  : Single unsigned multiply tile, infers DSP48E2
//
//   Performs  p = a * b  (unsigned) using a single DSP48E2 slice.
//
//   Unsigned operands are zero-extended by one bit and cast to
//   signed, so the DSP's signed 27*18 multiplier covers the full
//   unsigned range (26*17 useful bits).
//
//   PIPE_DSP maps directly to DSP48E2 internal registers:
//     0 > combinational (no registers)
//     1 > MREG only  (multiply-result register)
//     2 > AREG + BREG + MREG  (input + multiply registers)
//     3 > AREG + BREG + MREG + PREG  (all DSP-internal registers)
//    >3 > same as 3, plus (PIPE_DSP-3) fabric register stages
//
//   All pipeline stages up to 3 are kept inside the DSP
//   primitive.  This avoids fabric register placement issues
//   and prevents Vivado retiming from disturbing the clean
//   fabric<->DSP boundary - a critical requirement for high-
//   frequency designs where PIPE_PRE fabric registers must
//   remain near the pre-addition carry chains.
//
//   The (* use_dsp = "yes" *) attribute forces Vivado to map
//   the multiply into a DSP slice rather than fabric LUTs.
//
// Portability:
//   Changing dsp_pkg constants (DSP_A_U, DSP_B_U) adapts this
//   module from DSP48E2 (UltraScale+) to DSP58 (Versal) with
//   no RTL changes - only the maximum WA/WB values change.
//
// Author(s): Selim Kirbiyik, TU Graz (16.3.2026)
// --------------------------------------------------------------

`timescale 1ns / 1ps

module dsp_mul
    import dsp_pkg::*;
#(
    parameter int unsigned WA       = DSP_A_U,   // unsigned A width (max DSP_A_U=26)
    parameter int unsigned WB       = DSP_B_U,   // unsigned B width (max DSP_B_U=17)
    parameter int unsigned PIPE_DSP = 3           // pipeline stages inside DSP
)(
    input  logic                clk,
    input  logic [WA-1:0]      a,
    input  logic [WB-1:0]      b,
    output logic [WA+WB-1:0]   p
);

    // -- Signed-width extension --------------------------------
    //    DSP48E2 multiplier is signed.  We prepend a zero MSB
    //    to each unsigned operand so the sign bit is always 0,
    //    giving full unsigned range through the signed datapath.
    localparam int unsigned WAS = WA + 1;   // signed A width
    localparam int unsigned WBS = WB + 1;   // signed B width
    localparam int unsigned WPS = WAS + WBS; // signed product width

    wire signed [WAS-1:0] a_s = $signed({1'b0, a});
    wire signed [WBS-1:0] b_s = $signed({1'b0, b});

    generate
        if (PIPE_DSP == 0) begin : gen_comb
            // -- Purely combinational - no DSP registers -------
            (* use_dsp = "yes" *)
            wire signed [WPS-1:0] prod = a_s * b_s;
            assign p = prod[WA+WB-1:0];

        end else if (PIPE_DSP == 1) begin : gen_pipe1
            // -- MREG only -------------------------------------
            //    Multiply result is latched; inputs are combinational.
            (* use_dsp = "yes" *)
            logic signed [WPS-1:0] m_reg;

            always_ff @(posedge clk)
                m_reg <= a_s * b_s;

            assign p = m_reg[WA+WB-1:0];

        end else if (PIPE_DSP == 2) begin : gen_pipe2
            // -- AREG + BREG + MREG ----------------------------
            //    Input registers break the path into the DSP.
            //    Vivado infers AREG=1, BREG=1, MREG=1.
            (* use_dsp = "yes" *)
            logic signed [WAS-1:0] a_reg;
            logic signed [WBS-1:0] b_reg;
            logic signed [WPS-1:0] m_reg;

            always_ff @(posedge clk) begin
                a_reg <= a_s;
                b_reg <= b_s;
            end

            always_ff @(posedge clk)
                m_reg <= a_reg * b_reg;

            assign p = m_reg[WA+WB-1:0];

        end else begin : gen_pipe3
            // -- AREG + BREG + MREG + PREG ---------------------
            //    All four DSP-internal register stages are used.
            //    The coding pattern - two back-to-back registers
            //    after the multiply - lets Vivado infer MREG for
            //    the first and PREG for the second, keeping
            //    everything inside the DSP primitive.
            //
            //    DSP48E2 data flow:
            //      A/B > AREG/BREG > Multiplier > MREG > ALU > PREG > P
            //
            //    PREG is critical at >=450 MHz: it cuts the
            //    ~0.96 ns DSP-internal path (MREG>ALU>P) so that
            //    the subsequent CSA tree gets a full clock cycle.
            (* use_dsp = "yes" *)
            logic signed [WAS-1:0] a_reg;
            logic signed [WBS-1:0] b_reg;
            logic signed [WPS-1:0] m_reg;
            logic signed [WPS-1:0] p_reg;

            always_ff @(posedge clk) begin
                a_reg <= a_s;       // > AREG
                b_reg <= b_s;       // > BREG
            end

            always_ff @(posedge clk)
                m_reg <= a_reg * b_reg;   // > MREG

            always_ff @(posedge clk)
                p_reg <= m_reg;           // > PREG

            if (PIPE_DSP == 3) begin : gen_no_extra
                assign p = p_reg[WA+WB-1:0];
            end else begin : gen_extra
                // -- Additional fabric stages for PIPE_DSP > 3 -
                //    These live in fabric FFs outside the DSP.
                //    Rarely needed; included for completeness.
                logic [WA+WB-1:0] extra [PIPE_DSP-3];

                always_ff @(posedge clk)
                    extra[0] <= p_reg[WA+WB-1:0];

                for (genvar i = 1; i < PIPE_DSP - 3; i++) begin : gen_ext
                    always_ff @(posedge clk)
                        extra[i] <= extra[i-1];
                end

                assign p = extra[PIPE_DSP-4];
            end
        end
    endgenerate

endmodule
