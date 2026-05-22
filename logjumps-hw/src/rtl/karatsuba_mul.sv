// --------------------------------------------------------------
// Module   : karatsuba_mul
// Purpose  : Recursive Karatsuba multiplier (binary output)
//
//   Computes  C = A * B  (unsigned) using 2-level recursive
//   Karatsuba decomposition with schoolbook base cases.
//
// Algorithm:
//   The Karatsuba identity reduces one W-bit multiply to three
//   (W/2)-bit multiplies plus additions:
//
//     A = a_hi * 2^HALF + a_lo          (split at HALF = ceil(W/2))
//     B = b_hi * 2^HALF + b_lo
//
//     z0 = a_lo * b_lo                  (low x low)
//     z2 = a_hi * b_hi                  (high x high)
//     zx = (a_lo + a_hi) * (b_lo + b_hi)   (cross term)
//     z1 = zx - z0 - z2                (always >= 0 for unsigned)
//
//     A*B = z0 + z1 * 2^HALF + z2 * 2^(2*HALF)
//
//   The module recursively instantiates itself via generate-if.
//   When both operands fit within KARATSUBA_THRESHOLD (98 bits),
//   the base case instantiates schoolbook_mul instead.
//
// Decomposition tree (384x384):
//   384x384
//    +- Karatsuba split at 192
//        +- z0: 192x192
//        |    +- Karatsuba split at 96
//        |        +- z0: 96x96   (schoolbook, 24 DSPs)
//        |        +- z2: 96x96   (schoolbook, 24 DSPs)
//        |        +- zx: 97x97   (schoolbook, 24 DSPs)
//        +- z2: 192x192           (same structure, 72 DSPs)
//        +- zx: 193x193
//             +- Karatsuba split at 97
//                 +- z0: 97x97   (schoolbook, 24 DSPs)
//                 +- z2: 96x96   (schoolbook, 24 DSPs)
//                 +- zx: 98x98   (schoolbook, 24 DSPs)
//   Total: 9 base multipliers x 24 DSPs = 216 DSPs
//
// Subtraction strategy:
//   z1 = zx - z0 - z2 is computed via complement-and-add at
//   the full LOGC width.  The identity used:
//     result = z0 + zx*2^HALF + z2*2^(2*HALF)
//            + ~(z0 << HALF) + ~(z2 << HALF) + 2
//
//   The ~(X) terms implement -(X)-1 at LOGC width, and the +2
//   corrects for the two -1 offsets.  The 2*(2^LOGC) overflow
//   from the complements vanishes when the final CPA truncates
//   to LOGC bits.
//
//   These 5 terms are reduced to a carry-save pair by csa_tree,
//   then a CPA converts to binary.
//
// Pipeline stages:
//   PIPE_PRE  (1)  Register after pre-additions (a_lo+a_hi, b_lo+b_hi)
//                  and operand pass-throughs for z0/z2.  Also serves
//                  as a balance register so all three sub-multiply
//                  paths see their inputs at the same cycle.
//                  DONT_TOUCH prevents Vivado from absorbing these
//                  into DSP AREG - keeps them in fabric near the
//                  pre-addition carry chains for clean placement.
//
//   PIPE_DSP (1-3) DSP-internal registers (passed to schoolbook_mul
//                  and dsp_mul).  See dsp_mul.sv for details.
//
//   PIPE_MID (0-1) Register between recomposition CSA tree and CPA.
//                  0 > merged (<=225 MHz), 1 > split (>=450 MHz).
//
//   PIPE_POST (1)  Register after the recomposition CPA.
//
// Delay balancing:
//   The three sub-multiplies (z0, z2, zx) may have different
//   pipeline depths when operand widths straddle the Karatsuba
//   threshold (e.g. z0/z2 are 98-bit base cases with LAT=5 while
//   zx is 99-bit and needs an extra Karatsuba level with LAT=8).
//   SRL-friendly shift registers pad faster sub-multiply outputs
//   to match the slowest, ensuring the recomposition CSA tree
//   always combines values from the same input cycle.
//
// Latency:
//   PIPE_PRE + max(LAT_z0, LAT_z2, LAT_zx) + PIPE_MID + PIPE_POST
//   applied recursively, with schoolbook_latency at the leaves.
//
// Proven configurations (384x384, Alveo U55C):
//   455 MHz / 11 cyc:  PIPE_DSP=3, PIPE_MID=1
//   225 MHz /  6 cyc:  PIPE_DSP=1, PIPE_MID=0
//
// Author(s): Selim Kirbiyik, TU Graz (16.3.2026)
// --------------------------------------------------------------

`timescale 1ns / 1ps

module karatsuba_mul
    import karatsuba_mul_pkg::*;
    import csa_tree_pkg::*;
#(
    parameter int unsigned LOGA      = 384,
    parameter int unsigned LOGB      = 384,
    parameter int unsigned PIPE_DSP  = 3,
    parameter int unsigned PIPE_PRE  = 1,
    parameter int unsigned PIPE_POST = 1,
    parameter int unsigned PIPE_MID  = 1,   // 1: CSA>reg>CPA>reg  0: CSA+CPA>reg

    // Derived - accessible by testbenches (e.g. cocotb) via hierarchy
    parameter int unsigned LOGC = logc('{LOGA, LOGB, PIPE_DSP, PIPE_PRE, PIPE_POST, PIPE_MID}),
    parameter int unsigned LAT  = latency('{LOGA, LOGB, PIPE_DSP, PIPE_PRE, PIPE_POST, PIPE_MID})
)(
    input  logic                  clk,
    input  logic [LOGA-1:0]       A,
    input  logic [LOGB-1:0]       B,
    output logic [LOGA+LOGB-1:0]  C
);

    // LOGC is derived in the parameter list above

    generate
    if (is_base_case(LOGA, LOGB)) begin : gen_base
        // -- Base case: mac_std schoolbook multiplication ------
        //    Both operands <= KARATSUBA_THRESHOLD - use mac_std
        //    with dsp_mul tiles, CSA tree reduction, and
        //    configurable CSA-to-CPA pipeline.
        //
        //    PIPE_DSP controls DSP-internal registers (dsp_mul).
        //    PIPE_MID maps to FF_CSA: when 1, a register splits
        //    the CSA output from the final CPA for higher fmax.
        //    FF_OUT always enabled for the CPA output register.
        mac_std #(
            .LOGA       (LOGA),
            .LOGB       (LOGB),
            .MODE_E     (mac_std_pkg::E_DISABLED),
            .LOGE       (1),
            .FF_IN_A    (1'b0),     // handled by PIPE_DSP (AREG)
            .FF_IN_B    (1'b0),     // handled by PIPE_DSP (BREG)
            .FF_IN_E    (1'b0),
            .FF_MUL     (1'b0),     // handled by PIPE_DSP (MREG)
            .FF_OUT     (1'b1),     // CPA output register (always on)
            .USE_CSA    (1'b1),     // CSA tree reduction
            .FF_CSA     (PIPE_MID[0]),  // CSA-to-CPA pipeline
            .FF_DIAG    (1'b0),
            .FF_CSA_MID (1'b0),
            .FF_ADD     (1'b0),
            .PIPE_DSP   (PIPE_DSP)
        ) u_base (
            .clk (clk),
            .A   (A),
            .B   (B),
            .E   ('0),
            .C   (C)
        );

    end else begin : gen_karatsuba
        // -- Karatsuba decomposition ---------------------------

        // Split point: ceil(max(LOGA,LOGB) / 2)
        localparam int unsigned HALF = karatsuba_split(LOGA, LOGB);

        // Operand half-widths after splitting at HALF
        localparam int unsigned W_ALO = HALF;           // a_lo width
        localparam int unsigned W_AHI = LOGA - HALF;    // a_hi width
        localparam int unsigned W_BLO = HALF;           // b_lo width
        localparam int unsigned W_BHI = LOGB - HALF;    // b_hi width

        // Pre-addition widths: one extra bit for the carry from
        // a_lo + a_hi and b_lo + b_hi.
        localparam int unsigned W_ASUM = ((W_ALO > W_AHI) ? W_ALO : W_AHI) + 1;
        localparam int unsigned W_BSUM = ((W_BLO > W_BHI) ? W_BLO : W_BHI) + 1;

        // Sub-product widths
        localparam int unsigned W_Z0    = W_ALO + W_BLO;    // z0 = a_lo * b_lo
        localparam int unsigned W_Z2    = W_AHI + W_BHI;    // z2 = a_hi * b_hi
        localparam int unsigned W_CROSS = W_ASUM + W_BSUM;  // zx = (a_lo+a_hi) * (b_lo+b_hi)

        // -- Sub-multiply latencies for delay balancing --------
        //    The three sub-multiplies can have different pipeline
        //    depths when operand widths straddle KARATSUBA_THRESHOLD.
        //    e.g. z0(98x98) is a schoolbook base case (LAT=5) while
        //    zx(99x99) needs an extra Karatsuba level (LAT=8).
        //    Without delay balancing, the recomposition CSA tree
        //    would combine values from different input cycles,
        //    corrupting results when inputs change every clock.
        localparam int unsigned LAT_Z0 = latency('{
            int'(W_ALO), int'(W_BLO),
            int'(PIPE_DSP), int'(PIPE_PRE),
            int'(PIPE_POST), int'(PIPE_MID)
        });
        localparam int unsigned LAT_Z2 = latency('{
            int'(W_AHI), int'(W_BHI),
            int'(PIPE_DSP), int'(PIPE_PRE),
            int'(PIPE_POST), int'(PIPE_MID)
        });
        localparam int unsigned LAT_ZX = latency('{
            int'(W_ASUM), int'(W_BSUM),
            int'(PIPE_DSP), int'(PIPE_PRE),
            int'(PIPE_POST), int'(PIPE_MID)
        });

        localparam int unsigned LAT_SUB_MAX =
            (LAT_Z0 >= LAT_Z2 && LAT_Z0 >= LAT_ZX) ? LAT_Z0 :
            (LAT_Z2 >= LAT_ZX)                      ? LAT_Z2 :
                                                       LAT_ZX;

        localparam int unsigned DELAY_Z0 = LAT_SUB_MAX - LAT_Z0;
        localparam int unsigned DELAY_Z2 = LAT_SUB_MAX - LAT_Z2;
        localparam int unsigned DELAY_ZX = LAT_SUB_MAX - LAT_ZX;

        // -- Split operands ------------------------------------
        wire [W_ALO-1:0] a_lo = A[W_ALO-1:0];
        wire [W_AHI-1:0] a_hi = A[LOGA-1:HALF];
        wire [W_BLO-1:0] b_lo = B[W_BLO-1:0];
        wire [W_BHI-1:0] b_hi = B[LOGB-1:HALF];

        // -- Pre-additions for cross term ----------------------
        //    These carry chains are the reason PIPE_PRE exists:
        //    a 193-bit addition at the outer level needs a full
        //    clock cycle at high frequencies.
        logic [W_ASUM-1:0] a_sum;
        logic [W_BSUM-1:0] b_sum;

        assign a_sum = W_ASUM'(a_lo) + W_ASUM'(a_hi);
        assign b_sum = W_BSUM'(b_lo) + W_BSUM'(b_hi);

        // -- Pipeline after pre-additions ----------------------
        //    DONT_TOUCH prevents Vivado synthesis from absorbing
        //    these fabric registers into DSP AREG.  Without it,
        //    retiming merges PIPE_PRE into AREG, creating a long
        //    unregistered path from the pre-addition carry chain
        //    exit to a distant DSP - a routing nightmare at
        //    high frequency.
        //
        //    The z0/z2 operands (a_lo, a_hi, b_lo, b_hi) are
        //    delayed by the same PIPE_PRE stages to keep all
        //    three sub-multiply paths time-aligned.
        wire [W_ASUM-1:0] a_sum_p;
        wire [W_BSUM-1:0] b_sum_p;
        wire [W_ALO-1:0]  a_lo_p;
        wire [W_AHI-1:0]  a_hi_p;
        wire [W_BLO-1:0]  b_lo_p;
        wire [W_BHI-1:0]  b_hi_p;

        if (PIPE_PRE == 0) begin : gen_pre_bypass
            // No pipeline registers - combinational pass-through
            assign a_sum_p = a_sum;
            assign b_sum_p = b_sum;
            assign a_lo_p  = a_lo;
            assign a_hi_p  = a_hi;
            assign b_lo_p  = b_lo;
            assign b_hi_p  = b_hi;
        end else begin : gen_pre_pipe
            (* DONT_TOUCH = "yes" *) logic [W_ASUM-1:0] pre_asum [PIPE_PRE];
            (* DONT_TOUCH = "yes" *) logic [W_BSUM-1:0] pre_bsum [PIPE_PRE];
            (* DONT_TOUCH = "yes" *) logic [W_ALO-1:0]  pre_alo  [PIPE_PRE];
            (* DONT_TOUCH = "yes" *) logic [W_AHI-1:0]  pre_ahi  [PIPE_PRE];
            (* DONT_TOUCH = "yes" *) logic [W_BLO-1:0]  pre_blo  [PIPE_PRE];
            (* DONT_TOUCH = "yes" *) logic [W_BHI-1:0]  pre_bhi  [PIPE_PRE];

            always_ff @(posedge clk) begin
                pre_asum[0] <= a_sum;
                pre_bsum[0] <= b_sum;
                pre_alo[0]  <= a_lo;
                pre_ahi[0]  <= a_hi;
                pre_blo[0]  <= b_lo;
                pre_bhi[0]  <= b_hi;
            end

            for (genvar s = 1; s < PIPE_PRE; s++) begin : gen_pre_stage
                always_ff @(posedge clk) begin
                    pre_asum[s] <= pre_asum[s-1];
                    pre_bsum[s] <= pre_bsum[s-1];
                    pre_alo[s]  <= pre_alo[s-1];
                    pre_ahi[s]  <= pre_ahi[s-1];
                    pre_blo[s]  <= pre_blo[s-1];
                    pre_bhi[s]  <= pre_bhi[s-1];
                end
            end

            assign a_sum_p = pre_asum[PIPE_PRE-1];
            assign b_sum_p = pre_bsum[PIPE_PRE-1];
            assign a_lo_p  = pre_alo[PIPE_PRE-1];
            assign a_hi_p  = pre_ahi[PIPE_PRE-1];
            assign b_lo_p  = pre_blo[PIPE_PRE-1];
            assign b_hi_p  = pre_bhi[PIPE_PRE-1];
        end

        // -- Three sub-multiplications -------------------------
        //    All three run in parallel.  Each recursively
        //    instantiates karatsuba_mul (or bottoms out at
        //    schoolbook_mul when operands <= KARATSUBA_THRESHOLD).
        logic [W_Z0-1:0]    z0_raw;    // a_lo * b_lo
        logic [W_Z2-1:0]    z2_raw;    // a_hi * b_hi
        logic [W_CROSS-1:0] zx_raw;    // (a_lo+a_hi) * (b_lo+b_hi)

        karatsuba_mul #(
            .LOGA      (W_ALO),
            .LOGB      (W_BLO),
            .PIPE_DSP  (PIPE_DSP),
            .PIPE_PRE  (PIPE_PRE),
            .PIPE_POST (PIPE_POST),
            .PIPE_MID  (PIPE_MID)
        ) u_z0 (
            .clk (clk),
            .A   (a_lo_p),
            .B   (b_lo_p),
            .C   (z0_raw)
        );

        karatsuba_mul #(
            .LOGA      (W_AHI),
            .LOGB      (W_BHI),
            .PIPE_DSP  (PIPE_DSP),
            .PIPE_PRE  (PIPE_PRE),
            .PIPE_POST (PIPE_POST),
            .PIPE_MID  (PIPE_MID)
        ) u_z2 (
            .clk (clk),
            .A   (a_hi_p),
            .B   (b_hi_p),
            .C   (z2_raw)
        );

        karatsuba_mul #(
            .LOGA      (W_ASUM),
            .LOGB      (W_BSUM),
            .PIPE_DSP  (PIPE_DSP),
            .PIPE_PRE  (PIPE_PRE),
            .PIPE_POST (PIPE_POST),
            .PIPE_MID  (PIPE_MID)
        ) u_zx (
            .clk (clk),
            .A   (a_sum_p),
            .B   (b_sum_p),
            .C   (zx_raw)
        );

        // -- Delay balancing -----------------------------------
        //    Pad faster sub-multiply outputs with shift registers
        //    so all three arrive at the recomposition CSA tree
        //    aligned to the same input cycle.
        //
        //    The critical-path sub-multiply (highest LAT) gets
        //    DELAY=0 (wire-through).  Faster sub-multiplies get
        //    DELAY = LAT_SUB_MAX - LAT_this cycles of SRL delay.
        //
        //    For 384x384: all sub-multiplies have equal LAT at
        //    every level, so all DELAYs are 0 (no overhead).
        //    For 391x391: z0(98x98)/z2(98x98) LAT=5 vs
        //    zx(99x99) LAT=8, so DELAY_Z0=DELAY_Z2=3, DELAY_ZX=0.

        logic [W_Z0-1:0]    z0_bal;
        logic [W_Z2-1:0]    z2_bal;
        logic [W_CROSS-1:0] zx_bal;

        // -- z0 delay balancing --
        if (DELAY_Z0 == 0) begin : gen_z0_nodel
            assign z0_bal = z0_raw;
        end else begin : gen_z0_del
            (* shreg_extract = "yes", srl_style = "srl_reg" *)
            reg [W_Z0-1:0] z0_sr [0:DELAY_Z0-1];
            always_ff @(posedge clk) z0_sr[0] <= z0_raw;
            for (genvar d = 1; d < DELAY_Z0; d++) begin : gen_z0_sr
                always_ff @(posedge clk) z0_sr[d] <= z0_sr[d-1];
            end
            assign z0_bal = z0_sr[DELAY_Z0-1];
        end

        // -- z2 delay balancing --
        if (DELAY_Z2 == 0) begin : gen_z2_nodel
            assign z2_bal = z2_raw;
        end else begin : gen_z2_del
            (* shreg_extract = "yes", srl_style = "srl_reg" *)
            reg [W_Z2-1:0] z2_sr [0:DELAY_Z2-1];
            always_ff @(posedge clk) z2_sr[0] <= z2_raw;
            for (genvar d = 1; d < DELAY_Z2; d++) begin : gen_z2_sr
                always_ff @(posedge clk) z2_sr[d] <= z2_sr[d-1];
            end
            assign z2_bal = z2_sr[DELAY_Z2-1];
        end

        // -- zx delay balancing --
        if (DELAY_ZX == 0) begin : gen_zx_nodel
            assign zx_bal = zx_raw;
        end else begin : gen_zx_del
            (* shreg_extract = "yes", srl_style = "srl_reg" *)
            reg [W_CROSS-1:0] zx_sr [0:DELAY_ZX-1];
            always_ff @(posedge clk) zx_sr[0] <= zx_raw;
            for (genvar d = 1; d < DELAY_ZX; d++) begin : gen_zx_sr
                always_ff @(posedge clk) zx_sr[d] <= zx_sr[d-1];
            end
            assign zx_bal = zx_sr[DELAY_ZX-1];
        end

        // -- Recomposition -------------------------------------
        //    Combines the three sub-products into the final result
        //    using the Karatsuba identity:
        //
        //      result = z0 + (zx - z0 - z2)*2^HALF + z2*2^(2*HALF)
        //
        //    Expanded and rearranged for CSA-friendly form:
        //
        //      result = z0                       term[0]
        //             + zx << HALF               term[1]
        //             + z2 << (2*HALF)           term[2]
        //             + ~(z0 << HALF)            term[3]  (complement = -(z0<<HALF) - 1)
        //             + ~(z2 << HALF)            term[4]  (complement = -(z2<<HALF) - 1)
        //             + 2                        correction for the two -1 offsets
        //
        //    The complements are taken at LOGC width.  Each ~(X)
        //    adds 2^LOGC - 1 - X, so the two complements introduce
        //    2*(2^LOGC - 1).  Together with the +2 correction:
        //      2*(2^LOGC - 1) + 2 = 2^(LOGC+1)
        //    which vanishes when the final CPA truncates to LOGC bits.

        localparam int unsigned CSA_W = csa_tree_output_width(LOGC, 5);

        logic [LOGC-1:0] term [5];

        assign term[0] = LOGC'(z0_bal);                    // +z0
        assign term[1] = LOGC'(zx_bal) << HALF;            // +zx * 2^HALF
        assign term[2] = LOGC'(z2_bal) << (2 * HALF);      // +z2 * 2^(2*HALF)
        assign term[3] = ~(LOGC'(z0_bal) << HALF);         // -(z0 * 2^HALF) via complement
        assign term[4] = ~(LOGC'(z2_bal) << HALF);         // -(z2 * 2^HALF) via complement

        // Reduce 5 terms to carry-save pair
        logic [CSA_W-1:0] recompose_out [2];

        csa_tree #(
            .INPUT_WIDTH  (LOGC),
            .NUM_INPUTS   (5),
            .OUTPUT_WIDTH (CSA_W)
        ) u_csa_recompose (
            .operands (term),
            .result   (recompose_out)
        );

        // -- CPA: convert carry-save to binary ----------------
        //    The +2 correction for the two complements is folded
        //    into the addition.
        logic [LOGC-1:0] result_cpa;

        if (PIPE_MID == 0) begin : gen_merged_recomp
            // CSA + CPA in a single cycle - suitable for <=225 MHz.
            assign result_cpa = LOGC'(recompose_out[0] + recompose_out[1] + 2);
        end else begin : gen_split_recomp
            // Pipeline register between CSA tree and CPA
            // required at >=450 MHz.
            logic [CSA_W-1:0] recompose_r [2];

            always_ff @(posedge clk) begin
                recompose_r[0] <= recompose_out[0];
                recompose_r[1] <= recompose_out[1];
            end

            assign result_cpa = LOGC'(recompose_r[0] + recompose_r[1] + 2);
        end

        // -- Output register -----------------------------------
        if (PIPE_POST == 0) begin : gen_post_bypass
            // No output pipeline - combinational pass-through
            assign C = result_cpa;
        end else begin : gen_post_pipe
            logic [LOGC-1:0] post [PIPE_POST];

            always_ff @(posedge clk)
                post[0] <= result_cpa;

            for (genvar s = 1; s < PIPE_POST; s++) begin : gen_post_stage
                always_ff @(posedge clk)
                    post[s] <= post[s-1];
            end

            assign C = post[PIPE_POST-1];
        end

    end
    endgenerate

endmodule