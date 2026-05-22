// --------------------------------------------------------------
// Module  : intmul_nonstd_BBxAB
// Purpose : Non-standard unsigned integer multiplier using
//           3 DSP primitives + 1 small (LUT or DSP) multiply.
//
// The name encodes the operand structure in terms of DSP ports:
//   "B" = DSP_B_U bits  (narrow port, unsigned)
//   "A" = DSP_A_U bits  (wide port, unsigned)
//
//   BB x AB  ->  A-operand is up to 2*DSP_B_U bits wide
//               B-operand is up to DSP_A_U+DSP_B_U bits wide
//
// Decomposition strategy:
//   B is split at bit DSP_A_U into {b_hi, b_lo}.
//   A is split *twice*, at different boundaries, so that every
//   partial product fits a single DSP:
//
//     > For b_lo (DSP_A_U-bit):  A split at DSP_B_U
//         A = {a_hi_b, a_lo_b}
//         PP0 = a_lo_b x b_lo    DSP_B_U x DSP_A_U  -> DSP    shift 0
//         PP1 = a_hi_b x b_lo   <=DSP_B_U x DSP_A_U  -> DSP    shift DSP_B_U
//
//     > For b_hi (<=DSP_B_U-bit): A split at DSP_A_U
//         A = {a_hi_a, a_lo_a}
//         PP2 = a_lo_a x b_hi    DSP_A_U x <=DSP_B_U -> DSP    shift DSP_A_U
//         PP3 = a_hi_a x b_hi   <=small              -> LUT/DSP shift 2*DSP_A_U
//
//   C = PP0 + PP1*2^DSP_B_U + PP2*2^DSP_A_U + PP3*2^(2*DSP_A_U)
//
// Pipeline stages (each independently enabled):
//   FF_IN  -> register inputs
//   FF_MUL -> register partial products
//   FF_CSA -> register CSA tree output (only when USE_CSA=1)
//   FF_OUT -> register final sum
//
// Author(s): Beren Aydogan, Tolun Tosun, Sabanci University (2025) [https://github.com/cisec-su/modmul-hdl/blob/7b9e7077b55dc4920d77febcf4b3c2c4ed33c691/src/intmul/intmul_nonstd_BBxAB.sv]
//            Selim Kirbiyik, TU Graz (Modified, 23.2.2026)
// --------------------------------------------------------------

module intmul_nonstd_BBxAB
    import dsp_pkg::*;
    import intmul_nonstd_BBxAB_pkg::*;
#(
    parameter int LOGA     = 2 * DSP_B_U,
    parameter int LOGB     = DSP_A_U + DSP_B_U,
    parameter bit FF_IN    = 1,
    parameter bit FF_MUL   = 1,
    parameter bit FF_OUT   = 1,
    parameter bit USE_CSA  = 0,
    parameter bit FF_CSA   = 0,
    parameter bit MORE_DSP = 0
)(
    input  logic                  clk,
    input  logic [LOGA     -1:0] A,
    input  logic [LOGB     -1:0] B,
    output logic [LOGA+LOGB-1:0] C
);

    // -- Parameter validation ------------------------------------
    if (!intmul_nonstd_BBxAB_valid(LOGA, LOGB)) begin : gen_param_check
        $fatal(1, "intmul_nonstd_BBxAB: invalid parameters - LOGA=%0d (valid %0d..%0d), LOGB=%0d (valid %0d..%0d)",
               LOGA, DSP_A_U + 1, 2 * DSP_B_U, LOGB, DSP_A_U + 1, DSP_A_U + DSP_B_U);
    end

    // -- Derived constants ---------------------------------------
    localparam int PRODUCT_W = LOGA + LOGB;

    // A split at narrow-port boundary (DSP_B_U) - paired with b_lo
    localparam int A_LO_B_W = DSP_B_U;
    localparam int A_HI_B_W = LOGA - DSP_B_U;

    // A split at wide-port boundary (DSP_A_U) - paired with b_hi
    localparam int A_LO_A_W = DSP_A_U;
    localparam int A_HI_A_W = LOGA - DSP_A_U;

    // B split at wide-port boundary (DSP_A_U)
    localparam int B_LO_W = DSP_A_U;
    localparam int B_HI_W = LOGB - DSP_A_U;

    // CSA tree sizing
    localparam int NUM_PP    = 4;
    localparam int CSA_OUT_W = PRODUCT_W + $clog2(NUM_PP);

    // Latency
    localparam intmul_nonstd_BBxAB_params_t PARAMS = '{
        LOGA, LOGB, int'(FF_IN), int'(FF_MUL), int'(FF_OUT),
        int'(FF_CSA), int'(USE_CSA), int'(MORE_DSP)
    };
    localparam int LAT = intmul_nonstd_BBxAB_lat(PARAMS);

    // -- Input partitioning --------------------------------------
    //   A split at DSP_B_U:  A = {a_hi_b, a_lo_b}
    //   A split at DSP_A_U:  A = {a_hi_a, a_lo_a}
    //   B split at DSP_A_U:  B = {b_hi,   b_lo  }
    logic [A_LO_B_W-1:0] a_lo_b;
    logic [A_HI_B_W-1:0] a_hi_b;
    logic [A_LO_A_W-1:0] a_lo_a;
    logic [A_HI_A_W-1:0] a_hi_a;
    logic [B_LO_W-1:0]   b_lo;
    logic [B_HI_W-1:0]   b_hi;

    assign a_lo_b = A[DSP_B_U-1:0];
    assign a_hi_b = A[LOGA-1:DSP_B_U];
    assign a_lo_a = A[DSP_A_U-1:0];
    assign a_hi_a = A[LOGA-1:DSP_A_U];
    assign b_lo   = B[DSP_A_U-1:0];
    assign b_hi   = B[LOGB-1:DSP_A_U];

    // -- Stage 0: optional input registers -----------------------
    logic [A_LO_B_W-1:0] a_lo_b_r;
    logic [A_HI_B_W-1:0] a_hi_b_r;
    logic [A_LO_A_W-1:0] a_lo_a_r;
    logic [A_HI_A_W-1:0] a_hi_a_r;
    logic [B_LO_W-1:0]   b_lo_r;
    logic [B_HI_W-1:0]   b_hi_r;

    if (FF_IN) begin : gen_ff_in
        always_ff @(posedge clk) begin
            a_lo_b_r <= a_lo_b;
            a_hi_b_r <= a_hi_b;
            a_lo_a_r <= a_lo_a;
            a_hi_a_r <= a_hi_a;
            b_lo_r   <= b_lo;
            b_hi_r   <= b_hi;
        end
    end

    wire [A_LO_B_W-1:0] a_lo_b_s0 = FF_IN ? a_lo_b_r : a_lo_b;
    wire [A_HI_B_W-1:0] a_hi_b_s0 = FF_IN ? a_hi_b_r : a_hi_b;
    wire [A_LO_A_W-1:0] a_lo_a_s0 = FF_IN ? a_lo_a_r : a_lo_a;
    wire [A_HI_A_W-1:0] a_hi_a_s0 = FF_IN ? a_hi_a_r : a_hi_a;
    wire [B_LO_W-1:0]   b_lo_s0   = FF_IN ? b_lo_r   : b_lo;
    wire [B_HI_W-1:0]   b_hi_s0   = FF_IN ? b_hi_r   : b_hi;

    // -- DSP multiplications -------------------------------------
    //  PP0 = a_lo_b x b_lo   (DSP_B_U x DSP_A_U - fits DSP)      shift 0
    //  PP1 = a_hi_b x b_lo   (<=DSP_B_U x DSP_A_U - fits DSP)     shift DSP_B_U
    //  PP2 = a_lo_a x b_hi   (DSP_A_U x <=DSP_B_U - fits DSP)     shift DSP_A_U
    (* MORE_DSP = "yes" *) logic [DSP_M_U-1:0] pp0, pp1, pp2;

    assign pp0 = a_lo_b_s0 * b_lo_s0;
    assign pp1 = a_hi_b_s0 * b_lo_s0;
    assign pp2 = a_lo_a_s0 * b_hi_s0;

    //  PP3 = a_hi_a x b_hi   (small product - LUT or DSP)         shift 2*DSP_A_U
    (* MORE_DSP = "yes" *) logic [DSP_A_U-1:0] pp3_dsp;
    (* MORE_DSP = "no"  *) logic [DSP_A_U-1:0] pp3_lut;
    logic [DSP_A_U-1:0] pp3;

    if (MORE_DSP) begin : gen_pp3_dsp
        assign pp3_dsp = a_hi_a_s0 * b_hi_s0;
    end else begin : gen_pp3_lut
        assign pp3_lut = a_hi_a_s0 * b_hi_s0;
    end

    assign pp3 = MORE_DSP ? pp3_dsp : pp3_lut;

    // -- Stage 1: optional post-multiply registers ---------------
    logic [DSP_M_U-1:0] pp0_r, pp1_r, pp2_r;
    logic [DSP_A_U-1:0] pp3_r;

    if (FF_MUL) begin : gen_ff_mul
        always_ff @(posedge clk) begin
            pp0_r <= pp0;
            pp1_r <= pp1;
            pp2_r <= pp2;
            pp3_r <= pp3;
        end
    end

    wire [DSP_M_U-1:0] pp0_s1 = FF_MUL ? pp0_r : pp0;
    wire [DSP_M_U-1:0] pp1_s1 = FF_MUL ? pp1_r : pp1;
    wire [DSP_M_U-1:0] pp2_s1 = FF_MUL ? pp2_r : pp2;
    wire [DSP_A_U-1:0] pp3_s1 = FF_MUL ? pp3_r : pp3;

    // -- Shift and zero-extend partial products ------------------
    logic [PRODUCT_W-1:0] shifted_pp [NUM_PP];

    always_comb begin
        shifted_pp[0] = PRODUCT_W'(pp0_s1);                        // PP0 << 0
        shifted_pp[1] = PRODUCT_W'(pp1_s1) << DSP_B_U;             // PP1 << DSP_B_U
        shifted_pp[2] = PRODUCT_W'(pp2_s1) << DSP_A_U;             // PP2 << DSP_A_U
        shifted_pp[3] = PRODUCT_W'(pp3_s1) << (2 * DSP_A_U);      // PP3 << 2*DSP_A_U
    end

    // -- Summation (direct adder tree or CSA) --------------------
    logic [PRODUCT_W-1:0] sum;

    if (USE_CSA) begin : gen_csa

        logic [CSA_OUT_W-1:0] csa_out [2];

        csa_tree #(
            .INPUT_WIDTH (PRODUCT_W),
            .NUM_INPUTS  (NUM_PP)
        ) u_csa_tree (
            .operands (shifted_pp),
            .result   (csa_out)
        );

        // Optional register after CSA, before final add
        logic [CSA_OUT_W-1:0] csa_out_r [2];

        if (FF_CSA) begin : gen_ff_csa
            always_ff @(posedge clk) begin
                csa_out_r[0] <= csa_out[0];
                csa_out_r[1] <= csa_out[1];
            end
        end

        wire [CSA_OUT_W-1:0] csa_s2 [2];
        assign csa_s2[0] = FF_CSA ? csa_out_r[0] : csa_out[0];
        assign csa_s2[1] = FF_CSA ? csa_out_r[1] : csa_out[1];

        always_comb sum = PRODUCT_W'(csa_s2[0] + csa_s2[1]);

    end else begin : gen_direct_add

        always_comb begin
            sum = '0;
            for (int i = 0; i < NUM_PP; i++)
                sum = sum + shifted_pp[i];
        end

    end

    // -- Stage 2: optional output register -----------------------
    logic [PRODUCT_W-1:0] sum_r;

    if (FF_OUT) begin : gen_ff_out
        always_ff @(posedge clk) begin
            sum_r <= sum;
        end
    end

    assign C = FF_OUT ? sum_r : sum;

endmodule