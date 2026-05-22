// ----------------------------------------------------------------------
// Module : intmul_nonstd_BBAxBBA
// Purpose: Unsigned integer multiplier for operands up to
//          (DSP_A_U + 2*DSP_B_U) bits each, using 8 DSP
//          multipliers plus one optional extra (MORE_DSP).
//
// Architecture
// ------------
// Each operand is partitioned around three boundaries determined
// by the DSP port widths (A_U = 26, B_U = 17 for DSP48E2):
//
//          +--- hi (A_U) ---+-- mid (2*B_U - A_U) --+-- lo (A_U) ---+
//   bit    LOGX-1        2*B_U                    A_U              0
//
// The 8+1 partial products are sized to each fit one DSP primitive
// (one A_U-wide operand x one B_U-wide operand = M_U-wide result).
// Product M covers the small "overlap" region between A_U and 2*B_U
// and can optionally use an extra DSP (MORE_DSP) or be mapped to LUTs.
//
// Pipeline stages (each independently enabled):
//   FF_IN  -> register input partitions
//   FF_MUL -> register DSP/multiplier outputs
//   FF_CSA -> register carry-save adder outputs (only when USE_CSA=1)
//   FF_OUT -> register final sum
//
// Author(s): Beren Aydogan, Tolun Tosun, Sabanci University (2025) [https://github.com/cisec-su/modmul-hdl/blob/7b9e7077b55dc4920d77febcf4b3c2c4ed33c691/src/intmul/intmul_nonstd_BBAxBBA.sv]
//            Selim Kirbiyik, TU Graz (Modified, 23.2.2026)
// ----------------------------------------------------------------------

module intmul_nonstd_BBAxBBA
    import dsp_pkg::*;
    import intmul_nonstd_BBAxBBA_pkg::*;
    import csa_tree_pkg::*;
#(
    parameter int LOGA     = 60,
    parameter int LOGB     = 60,
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

// ----------------------- Parameter Validation ------------------------

if (!intmul_nonstd_BBAxBBA_pkg::valid(LOGA, LOGB)) begin : gen_param_check
    $fatal(1, "intmul_nonstd_BBAxBBA: invalid parameters - LOGA=%0d (valid %0d..%0d), LOGB=%0d (valid %0d..%0d)",
           LOGA, DSP_M_U + 1, DSP_A_U + 2 * DSP_B_U,
           LOGB, DSP_M_U + 1, DSP_A_U + 2 * DSP_B_U);
end

// ----------------------- Derived Constants ---------------------------

localparam int W   = LOGA + LOGB;       // full product width
localparam int AU  = DSP_A_U;           // 26 - unsigned A-port width
localparam int BU  = DSP_B_U;           // 17 - unsigned B-port width
localparam int MU  = DSP_M_U;           // 43 - unsigned product width
localparam int OV  = 2*BU - AU;         // 8  - overlap region width

localparam params_t PARAMS = '{LOGA, LOGB, int'(FF_IN), int'(FF_MUL),
                               int'(FF_OUT), int'(FF_CSA), int'(USE_CSA),
                               int'(MORE_DSP)};
localparam int LAT = latency(PARAMS);

// --------------- Input Partitioning (combinational) ------------------
//
// Each operand X (A or B) is sliced into several overlapping windows
// that are sized to fit DSP A-ports (AU bits) or B-ports (BU bits).
//
//   Name       Width   Slice              Used in
//   ----       -----   -----              -------
//   X_lo_a     AU      X[AU-1   : 0]        P0,P1 (A-port)
//   X_lo_bl    BU      X[BU-1   : 0]        P2    (B-port)
//   X_lo_bh    BU      X[2*BU-1 : BU]       P3    (B-port)
//   X_hi_a    <=AU     X[LOGX-1 : 2*BU]     P4,P5 (A-port) / P2,P3 (A-port)
//   X_hi_bl   <=BU     X[MU-1   : AU]       P7    (B-port) / P5    (B-port)
//   X_hi_bh   <=BU     X[LOGX-1 : MU]       P6    (B-port) / P4    (B-port)
//   X_ov       OV      X[2*BU-1 : AU]       M     (overlap product)

// - A-side partitions -
wire [AU-1:0]           a_lo_a   = A[AU-1      : 0];       // P0, P1
wire [BU-1:0]           a_lo_bl  = A[BU-1      : 0];       // P2
wire [BU-1:0]           a_lo_bh  = A[2*BU-1    : BU];      // P3
wire [AU-1:0]           a_hi_a   = A[LOGA-1    : 2*BU];    // P4, P5
wire [BU-1:0]           a_hi_bl  = A[MU-1      : AU];      // P7
wire [BU-1:0]           a_hi_bh  = A[LOGA-1    : MU];      // P6
wire [2*BU-1:AU]        a_ov     = A[2*BU-1    : AU];      // M

// - B-side partitions -
wire [BU-1:0]           b_lo_bl  = B[BU-1      : 0];       // P0
wire [BU-1:0]           b_lo_bh  = B[2*BU-1    : BU];      // P1
wire [AU-1:0]           b_hi_a   = B[LOGB-1    : 2*BU];    // P2, P3
wire [BU-1:0]           b_hi_bl  = B[MU-1      : AU];      // P5
wire [BU-1:0]           b_hi_bh  = B[LOGB-1    : MU];      // P4
wire [AU-1:0]           b_lo_a   = B[AU-1      : 0];       // P6, P7
wire [2*BU-1:AU]        b_ov     = B[2*BU-1    : AU];      // M

// --------------- Optional Input Register (FF_IN) ---------------------

reg  [AU-1:0]     a_lo_a_q,  a_hi_a_q;
reg  [BU-1:0]     a_lo_bl_q, a_lo_bh_q, a_hi_bl_q, a_hi_bh_q;
reg  [2*BU-1:AU]  a_ov_q;
reg  [BU-1:0]     b_lo_bl_q, b_lo_bh_q, b_hi_bl_q, b_hi_bh_q;
reg  [AU-1:0]     b_hi_a_q,  b_lo_a_q;
reg  [2*BU-1:AU]  b_ov_q;

if (FF_IN) begin : gen_ff_in
    always_ff @(posedge clk) begin
        a_lo_a_q  <= a_lo_a;
        a_lo_bl_q <= a_lo_bl;
        a_lo_bh_q <= a_lo_bh;
        a_hi_a_q  <= a_hi_a;
        a_hi_bl_q <= a_hi_bl;
        a_hi_bh_q <= a_hi_bh;
        a_ov_q    <= a_ov;
    end
    always_ff @(posedge clk) begin
        b_lo_bl_q <= b_lo_bl;
        b_lo_bh_q <= b_lo_bh;
        b_hi_a_q  <= b_hi_a;
        b_hi_bl_q <= b_hi_bl;
        b_hi_bh_q <= b_hi_bh;
        b_lo_a_q  <= b_lo_a;
        b_ov_q    <= b_ov;
    end
end

// Muxed inputs: registered when FF_IN=1, combinational otherwise.
wire [AU-1:0]     a_lo_a_m  = FF_IN ? a_lo_a_q  : a_lo_a;
wire [BU-1:0]     a_lo_bl_m = FF_IN ? a_lo_bl_q : a_lo_bl;
wire [BU-1:0]     a_lo_bh_m = FF_IN ? a_lo_bh_q : a_lo_bh;
wire [AU-1:0]     a_hi_a_m  = FF_IN ? a_hi_a_q  : a_hi_a;
wire [BU-1:0]     a_hi_bl_m = FF_IN ? a_hi_bl_q : a_hi_bl;
wire [BU-1:0]     a_hi_bh_m = FF_IN ? a_hi_bh_q : a_hi_bh;
wire [2*BU-1:AU]  a_ov_m    = FF_IN ? a_ov_q    : a_ov;

wire [BU-1:0]     b_lo_bl_m = FF_IN ? b_lo_bl_q : b_lo_bl;
wire [BU-1:0]     b_lo_bh_m = FF_IN ? b_lo_bh_q : b_lo_bh;
wire [AU-1:0]     b_hi_a_m  = FF_IN ? b_hi_a_q  : b_hi_a;
wire [BU-1:0]     b_hi_bl_m = FF_IN ? b_hi_bl_q : b_hi_bl;
wire [BU-1:0]     b_hi_bh_m = FF_IN ? b_hi_bh_q : b_hi_bh;
wire [AU-1:0]     b_lo_a_m  = FF_IN ? b_lo_a_q  : b_lo_a;
wire [2*BU-1:AU]  b_ov_m    = FF_IN ? b_ov_q    : b_ov;

// --------------- Partial Products (8 DSPs + 1 overlap) ---------------
//
//  Index   A operand (port)    B operand (port)    Shift
//  -----   ----------------    ----------------    -----
//  P0      a_lo_a   (A)        b_lo_bl  (B)        0
//  P1      a_lo_a   (A)        b_lo_bh  (B)        BU
//  P2      a_lo_bl  (B)        b_hi_a   (A)        2*BU
//  P3      a_lo_bh  (B)        b_hi_a   (A)        3*BU
//  P4      a_hi_a   (A)        b_hi_bh  (B)        2*BU + MU
//  P5      a_hi_a   (A)        b_hi_bl  (B)        2*BU + AU
//  P6      a_hi_bh  (B)        b_lo_a   (A)        MU
//  P7      a_hi_bl  (B)        b_lo_a   (A)        AU
//  M       a_ov              x b_ov                 2*AU

(* MORE_DSP = "yes" *) wire [MU-1:0] P [0:7];

assign P[0] = a_lo_a_m  * b_lo_bl_m;
assign P[1] = a_lo_a_m  * b_lo_bh_m;
assign P[2] = a_lo_bl_m * b_hi_a_m;
assign P[3] = a_lo_bh_m * b_hi_a_m;
assign P[4] = a_hi_a_m  * b_hi_bh_m;
assign P[5] = a_hi_a_m  * b_hi_bl_m;
assign P[6] = a_hi_bh_m * b_lo_a_m;
assign P[7] = a_hi_bl_m * b_lo_a_m;

// Overlap product - optionally mapped to DSP or LUT fabric.
(* MORE_DSP = "yes" *) wire [MU-1:0] M_dsp;
(* MORE_DSP = "no"  *) wire [MU-1:0] M_lut;

if (MORE_DSP) begin : gen_m_dsp
    assign M_dsp = a_ov_m * b_ov_m;
end else begin : gen_m_lut
    assign M_lut = a_ov_m * b_ov_m;
end

wire [MU-1:0] M_prod = MORE_DSP ? M_dsp : M_lut;

// --------------- Optional Multiplier Register (FF_MUL) ---------------

reg  [MU-1:0] P_q [0:7];
reg  [MU-1:0] M_prod_q;

if (FF_MUL) begin : gen_ff_mul
    for (genvar i = 0; i < 8; i++) begin : gen_p_reg
        always_ff @(posedge clk) P_q[i] <= P[i];
    end
    always_ff @(posedge clk) M_prod_q <= M_prod;
end

wire [MU-1:0] Pm [0:7];        // muxed partial products
wire [MU-1:0] Mm;              // muxed overlap product

for (genvar i = 0; i < 8; i++) begin : gen_p_mux
    assign Pm[i] = FF_MUL ? P_q[i] : P[i];
end
assign Mm = FF_MUL ? M_prod_q : M_prod;

// --------------- Shift & Align Partial Products ----------------------

// Shifts are the sum of the starting bit positions of the two
// operand slices - they are fixed constants of the DSP geometry,
// independent of LOGA/LOGB.
localparam int SHIFT_P0 = 0;               // A@0      x B@0
localparam int SHIFT_P1 = BU;              // A@0      x B@BU
localparam int SHIFT_P2 = 2*BU;            // A@0      x B@2*BU
localparam int SHIFT_P3 = 3*BU;            // A@BU     x B@2*BU
localparam int SHIFT_P4 = 2*BU + MU;       // A@2*BU   x B@MU
localparam int SHIFT_P5 = 2*BU + AU;       // A@2*BU   x B@AU
localparam int SHIFT_P6 = MU;              // A@MU     x B@0
localparam int SHIFT_P7 = AU;              // A@AU     x B@0
localparam int SHIFT_M  = 2*AU;            // A@AU     x B@AU

reg [W-1:0] D [0:8];

always_comb begin
    D[0] = W'(Pm[0]) << SHIFT_P0;
    D[1] = W'(Pm[1]) << SHIFT_P1;
    D[2] = W'(Pm[2]) << SHIFT_P2;
    D[3] = W'(Pm[3]) << SHIFT_P3;
    D[4] = W'(Pm[7]) << SHIFT_P7;
    D[5] = W'(Pm[6]) << SHIFT_P6;
    D[6] = W'(Pm[5]) << SHIFT_P5;
    D[7] = W'(Pm[4]) << SHIFT_P4;
    D[8] = W'(Mm)    << SHIFT_M;
end

// --------------- Summation -------------------------------------------

localparam int CSA_W = csa_tree_pkg::csa_tree_output_width(W, 9);

wire [CSA_W-1:0] CSA_OUT   [2];
reg  [CSA_W-1:0] CSA_OUT_q [2];

reg [W-1:0] S;

if (USE_CSA) begin : gen_csa

    csa_tree #(
        .INPUT_WIDTH  (W),
        .NUM_INPUTS   (9),
        .OUTPUT_WIDTH (CSA_W)
    ) u_csa_tree (
        .operands (D),
        .result   (CSA_OUT)
    );

    // Optional CSA output register.
    if (FF_CSA) begin : gen_ff_csa
        for (genvar i = 0; i < 2; i++) begin : gen_csa_reg
            always_ff @(posedge clk) CSA_OUT_q[i] <= CSA_OUT[i];
        end
    end

    wire [CSA_W-1:0] csa0_m = FF_CSA ? CSA_OUT_q[0] : CSA_OUT[0];
    wire [CSA_W-1:0] csa1_m = FF_CSA ? CSA_OUT_q[1] : CSA_OUT[1];

    always_comb S = W'(csa0_m + csa1_m);

end else begin : gen_no_csa

    always_comb begin
        S = '0;
        for (int i = 0; i < 9; i++)
            S = S + D[i];
    end

end

// --------------- Optional Output Register (FF_OUT) -------------------

reg [W-1:0] S_q;

if (FF_OUT) begin : gen_ff_out
    always_ff @(posedge clk) S_q <= S;
end

assign C = FF_OUT ? S_q : S;

endmodule