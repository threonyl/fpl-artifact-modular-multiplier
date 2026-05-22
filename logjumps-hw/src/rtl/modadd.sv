module modadd #(
    parameter int unsigned  LOGQ        = 398,
    parameter bit           REG_IN      = 1,
    parameter bit           REG_OUT     = 1,
    parameter bit           REG_ADD     = 1,
    parameter bit           CONC_ADDSUB = 0,
    // -- Fixed-modulus mode ----------------------------------------
    //    When FIXED_Q = 1 the modulus is the compile-time constant
    //    Q_VALUE and the i_q input port is ignored.  This lets the
    //    synthesiser constant-fold one operand of every subtractor,
    //    shortening the critical path and eliminating q-pipeline FFs.
    parameter bit              FIXED_Q  = 0,
    parameter bit [LOGQ-1:0]   Q_VALUE  = '0
) (
    input  logic            clk,
    input  logic [LOGQ-1:0] i_a,
    input  logic [LOGQ-1:0] i_b,
    input  logic [LOGQ-1:0] i_q,
    output logic [LOGQ-1:0] o_c
);

// -----------------------------------------------------------------
// Effective modulus: compile-time constant or run-time input
// -----------------------------------------------------------------
// When FIXED_Q = 1 the synthesiser sees a constant on the q path
// and can heavily optimise the subtraction carry chain.
// -----------------------------------------------------------------
wire [LOGQ-1:0] q_eff;
generate
if (FIXED_Q) begin : gen_q_fixed
    assign q_eff = Q_VALUE;
end else begin : gen_q_variable
    assign q_eff = i_q;
end
endgenerate

logic [LOGQ-1:0] a_op, b_op, q_op;
logic [LOGQ-1:0] q_op_r;

logic [LOGQ:0] r, r_s;

localparam LATENCY = modadd_pkg::modadd_latency(REG_IN, REG_OUT, REG_ADD, CONC_ADDSUB);

// Buffer inputs
if (REG_IN) begin: gen_reg_in_1
    always_ff @(posedge clk) begin
        a_op <= i_a;
        b_op <= i_b;
        q_op <= q_eff;
    end
end else begin: gen_reg_in_0
    assign a_op = i_a;
    assign b_op = i_b;
    assign q_op = q_eff;
end

// q forwarding
if (!CONC_ADDSUB && REG_ADD) begin : gen_q_fwd
    always_ff @(posedge clk) q_op_r <= q_op;
end else begin : gen_q_fwd
    assign q_op_r = q_op;
end

// Addition
if (REG_ADD) begin: gen_reg_add_1
    always_ff @(posedge clk) begin
        r <= {1'b0,a_op} + {1'b0,b_op};
    end
end else begin: gen_reg_add_0
    assign r = {1'b0,a_op} + {1'b0,b_op};
end

// Subtraction
if (CONC_ADDSUB) begin : gen_sub_conc_1
    logic [LOGQ:0] r_s_comb;
    assign r_s_comb = {1'b0, a_op} + {1'b0, b_op} - {1'b0, q_op};
    if (REG_ADD) begin : gen_sub_reg
        always_ff @(posedge clk) r_s <= r_s_comb;
    end else begin : gen_sub_pass
        assign r_s = r_s_comb;
    end
end else begin : gen_sub_conc_0
    logic [LOGQ:0] r_s_comb;
    assign r_s_comb = r - {1'b0, q_op_r};
    if (REG_ADD) begin : gen_sub_reg
        always_ff @(posedge clk) r_s <= r_s_comb;
    end else begin : gen_sub_pass
        assign r_s = r_s_comb;
    end
end

// Align r with r_s when subtraction takes an extra pipeline stage
logic [LOGQ:0] r_mux;
if (!CONC_ADDSUB && REG_ADD) begin : gen_r_align
    always_ff @(posedge clk) r_mux <= r;
end else begin : gen_r_align
    assign r_mux = r;
end

// Buffer output
if (REG_OUT) begin: gen_reg_out_1
    always_ff @(posedge clk) begin
        o_c <= r_s[LOGQ] ? r_mux[LOGQ-1:0] : r_s[LOGQ-1:0];
    end
end else begin: gen_reg_out_0
    assign o_c = r_s[LOGQ] ? r_mux[LOGQ-1:0] : r_s[LOGQ-1:0];
end

endmodule