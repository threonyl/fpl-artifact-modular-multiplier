// --------------------------------------------------------------
// Module  : intmul_wrapper
// Purpose : Unified unsigned integer multiplier front-end.
//
//   Selects the most efficient multiplication topology for the
//   given operand widths:
//
//     USE_KARATSUBA = 1  ->  karatsuba_multiplier (recursive, wide operands)
//     NON_STD = 1        ->  intmul_nonstd_BBxAB   if operands fit
//                            intmul_nonstd_BBAxBBA otherwise
//     Both = 0           ->  mac_std              (generic DSP tiling)
//
//   USE_KARATSUBA takes priority over NON_STD.
//
//   Karatsuba pipeline parameters (K_PIPE_*) are independent of
//   the FF_* parameters used by the other topologies.
//
//   Proven configurations for 384x384:
//     455 MHz / 11 cyc:  K_PIPE_DSP=3, K_PIPE_MID=1  (default)
//     225 MHz /  6 cyc:  K_PIPE_DSP=1, K_PIPE_MID=0
//
// Pipeline stages (standard topologies, each independently enabled):
//   FF_IN      register inputs
//   FF_MUL     register partial products
//   FF_DIAG    register diagonal bins      (USE_CSA = 1 only)
//   FF_CSA_MID register mid-CSA tree split (USE_CSA = 1 only)
//   FF_CSA     register CSA tree output    (USE_CSA = 1 only)
//   FF_ADD     register adder midpoint     (USE_CSA = 1 only)
//   FF_OUT     register final result
//
// Author(s): Selim Kirbiyik, TU Graz (23.2.2026)
//            Adapted from [https://github.com/cisec-su/modmul-hdl/blob/7b9e7077b55dc4920d77febcf4b3c2c4ed33c691/src/intmul/intmul_wrapper.sv]
//            Changes:
//              > The module is just a thin wrapper, package handles selection
//              > The package is also a thin wrapper, checks valid ranges from the module packages
//              > Added Karatsuba multiplier topology for wide operands
// --------------------------------------------------------------

module intmul_wrapper
    import dsp_pkg::*;
    import mac_std_pkg::*;
    import intmul_wrapper_pkg::*;
#(
    parameter int LOGA       = 381,
    parameter int LOGB       = 381,

    // -- Standard / non-standard topology controls ----------------
    parameter bit FF_IN      = 1,
    parameter bit FF_MUL     = 1,
    parameter bit FF_OUT     = 1,
    parameter bit USE_CSA    = 1,
    parameter bit FF_CSA     = 1,
    parameter bit FF_DIAG    = 1,
    parameter bit FF_CSA_MID = 1,   // split CSA tree with register
    parameter bit FF_ADD     = 1,
    parameter bit MORE_DSP   = 0,
    parameter bit NON_STD    = 0,

    // -- Karatsuba topology controls ------------------------------
    parameter bit USE_KARATSUBA     = 1,
    parameter int K_PIPE_DSP        = 3,
    parameter int K_PIPE_PRE        = 1,
    parameter int K_PIPE_POST       = 1,
    parameter int K_PIPE_MID        = 1
)(
    input  logic                  clk,
    input  logic [LOGA     -1:0] A,
    input  logic [LOGB     -1:0] B,
    output logic [LOGA+LOGB-1:0] C
);

    localparam topo_t TOPO = select_topo(LOGA, LOGB, int'(NON_STD), int'(USE_KARATSUBA));

    // Karatsuba only makes sense when both operands exceed the
    // schoolbook threshold - below that the standard DSP tiling
    // topologies are smaller and faster.
    if (USE_KARATSUBA) begin : gen_karatsuba_check
        localparam int unsigned K_THRESH = karatsuba_mul_pkg::KARATSUBA_THRESHOLD;
        if (LOGA <= K_THRESH && LOGB <= K_THRESH) begin : gen_err
            initial $fatal(1,
                "intmul_wrapper: USE_KARATSUBA=1 but LOGA=%0d, LOGB=%0d both fit in a single schoolbook (<=%0d). Use a standard topology instead.",
                LOGA, LOGB, K_THRESH);
        end
    end

    localparam int LAT = intmul_wrapper_pkg::latency(
        LOGA, LOGB,
        int'(FF_IN), int'(FF_MUL), int'(FF_OUT),
        int'(USE_CSA), int'(FF_CSA),
        int'(MORE_DSP), int'(NON_STD),
        int'(FF_ADD), int'(FF_DIAG), int'(FF_CSA_MID),
        int'(USE_KARATSUBA),
        K_PIPE_DSP, K_PIPE_PRE, K_PIPE_POST,
        K_PIPE_MID
    );

    if (TOPO == TOPO_KARATSUBA) begin : gen_karatsuba

        karatsuba_mul #(
            .LOGA      (LOGA),
            .LOGB      (LOGB),
            .PIPE_DSP  (K_PIPE_DSP),
            .PIPE_PRE  (K_PIPE_PRE),
            .PIPE_POST (K_PIPE_POST),
            .PIPE_MID  (K_PIPE_MID)
        ) u_karatsuba (
            .clk (clk),
            .A   (A),
            .B   (B),
            .C   (C)
        );

    end else if (TOPO == TOPO_STD) begin : gen_std

        mac_std #(
            .LOGA       (LOGA),
            .LOGB       (LOGB),
            .MODE_E     (E_DISABLED),
            .LOGE       (1),
            .FF_IN_A    (FF_IN),
            .FF_IN_B    (FF_IN),
            .FF_IN_E    (1'b0),
            .FF_MUL     (FF_MUL),
            .FF_OUT     (FF_OUT),
            .USE_CSA    (USE_CSA),
            .FF_CSA     (FF_CSA),
            .FF_DIAG    (FF_DIAG),
            .FF_CSA_MID (FF_CSA_MID),
            .FF_ADD     (FF_ADD)
        ) u_mac_std (
            .clk (clk),
            .A   (A),
            .B   (B),
            .E   ('0),
            .C   (C)
        );

    end else if (TOPO == TOPO_BBxAB) begin : gen_bbxab

        if (LOGA <= LOGB) begin : gen_no_swap
            intmul_nonstd_BBxAB #(
                .LOGA     (LOGA),   .LOGB     (LOGB),
                .FF_IN    (FF_IN),  .FF_MUL   (FF_MUL),
                .FF_OUT   (FF_OUT), .USE_CSA  (USE_CSA),
                .FF_CSA   (FF_CSA), .MORE_DSP (MORE_DSP)
            ) u_bbxab (
                .clk (clk), .A (A), .B (B), .C (C)
            );
        end else begin : gen_swap
            intmul_nonstd_BBxAB #(
                .LOGA     (LOGB),   .LOGB     (LOGA),
                .FF_IN    (FF_IN),  .FF_MUL   (FF_MUL),
                .FF_OUT   (FF_OUT), .USE_CSA  (USE_CSA),
                .FF_CSA   (FF_CSA), .MORE_DSP (MORE_DSP)
            ) u_bbxab (
                .clk (clk), .A (B), .B (A), .C (C)
            );
        end

    end else if (TOPO == TOPO_BBAxBBA) begin : gen_bbaxbba

        intmul_nonstd_BBAxBBA #(
            .LOGA     (LOGA),   .LOGB     (LOGB),
            .FF_IN    (FF_IN),  .FF_MUL   (FF_MUL),
            .FF_OUT   (FF_OUT), .USE_CSA  (USE_CSA),
            .FF_CSA   (FF_CSA), .MORE_DSP (MORE_DSP)
        ) u_bbaxbba (
            .clk (clk), .A (A), .B (B), .C (C)
        );

    end

endmodule
