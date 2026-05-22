`timescale 1ns / 1ps

module vadd_cdc #(
        parameter PCI_WIDTH    = 512,
        parameter PIPE_WIDTH   = 512,
        parameter ADD_CONSTANT = 1
    ) 
    (
    input                        axis_clk,
    input                        rtl_clk,
    input                        axis_rst,  // active low

    // AXI Slave interface
    input  logic [PCI_WIDTH-1:0] s_tdata_0,
    input  logic                 s_tlast_0,
    input  logic                 s_tvalid_0,
    output logic                 s_tready_0,
    input  logic [PCI_WIDTH-1:0] s_tdata_1,
    input  logic                 s_tlast_1,
    input  logic                 s_tvalid_1,
    output logic                 s_tready_1,

    // AXI Master interface
    output logic [PCI_WIDTH-1:0] m_tdata_0,
    output logic                 m_tlast_0,
    output logic                 m_tvalid_0,
    input  logic                 m_tready_0,
    output logic [PCI_WIDTH-1:0] m_tdata_1,
    output logic                 m_tlast_1,
    output logic                 m_tvalid_1,
    input  logic                 m_tready_1
  );

  localparam int LOGQ       = 381;
  localparam int LOGW       = 17;
  localparam int LOGR       = LOGW * ((LOGQ + LOGW - 1) / LOGW);

  // -- Big multiplier (LOGQ x LOGQ) controls ----------------
  localparam bit MUL_FF_IN          = 1;
  localparam bit MUL_FF_MUL         = 1;
  localparam bit MUL_FF_OUT         = 1;
  localparam bit MUL_USE_CSA        = 1;
  localparam bit MUL_FF_CSA         = 1;
  localparam bit MUL_FF_DIAG        = 1;
  localparam bit MUL_FF_CSA_MID     = 1;
  localparam bit MUL_FF_ADD         = 1;
  localparam bit MUL_MORE_DSP       = 0;
  localparam bit MUL_NON_STD        = 0;
  localparam bit MUL_USE_KARATSUBA  = 1;
  localparam int MUL_K_PIPE_DSP     = 3;
  localparam int MUL_K_PIPE_PRE     = 1;
  localparam int MUL_K_PIPE_POST    = 1;
  localparam int MUL_K_PIPE_MID     = 1;
  // Pipeline register on the intmul_wrapper output C, between
  // the Karatsuba CPA and the logjumps input.  The Karatsuba
  // PIPE_POST register captures the CSA recomposition in
  // redundant form; the CPA that converts to non-redundant
  // binary is purely combinational (~762-bit carry chain) and
  // fans out into N_LIMBS limb extractions for logjumps.
  // This register breaks that path.  Vivado's max_fanout
  // attribute causes automatic register replication for the
  // high-fanout c_lo/c_hi extraction.
  //
  // Cost: +1 clock cycle of latency.
  //       No additional DSP or significant LUT cost.
  localparam bit MUL_FF_CPA         = 1;

  // -- LogJumps reduction controls --------------------------
  localparam bit LJ_FF_IN      = 1;
  localparam bit LJ_FF_MUL     = 1;
  localparam bit LJ_FF_OUT     = 1;
  localparam bit LJ_USE_CSA    = 1;
  localparam bit LJ_FF_CSA     = 1;
  localparam bit LJ_FF_DIAG    = 0;
  localparam bit LJ_FF_CSA_MID = 1;
  localparam bit LJ_FF_ADD     = 1;
  localparam bit LJ_MORE_DSP   = 1;
  localparam bit LJ_NON_STD    = 0;
  localparam bit LJ_FF_MR_POST = 1;
  // Split the wide join addition (T_acc + m_q) at the CARRY8-
  // aligned midpoint.  Independent of FF_MR_POST.  +1 cycle.
  localparam bit LJ_FF_JOIN_ADD = 1;
  localparam bit LJ_DSP_SMALL  = 1;
  localparam bit LJ_FF_RM      = 0;
  // -- m_val addition tree (addtree) pipeline localparams --;
  localparam int LJ_MT_REG_PERIOD = 2;
  localparam bit LJ_MT_REG_IN     = 1;
  localparam bit LJ_MT_REG_OUT    = 1;
  localparam bit LJ_MT_USE_CSA    = 1;

  // ==========================================================
  // modacc mode selection and configuration
  // ==========================================================
  //
  //   ACC_USE_ADDTREE = 0:
  //     Legacy binary reduction tree of fused modadd cells.
  //
  //   ACC_USE_ADDTREE = 1 (default):
  //     Phase 1 - Plain addtree summation (CSA-capable).
  //     Phase 2 - Binary-search conditional subtraction chain.
  //
  // -- Mode switch ---
  localparam bit ACC_USE_ADDTREE = 1;
  // -- Max conditional subtraction quotient ----------------
  localparam int ACC_MAX_COND_SUB = 12; // LOGR / LOGW - 1;
  // -- Addtree (Phase 1) configuration --------------------
  localparam int ACC_AT_REG_PERIOD = 3;
  localparam bit ACC_AT_REG_IN     = 1;
  localparam bit ACC_AT_REG_OUT    = 1;
  localparam bit ACC_AT_USE_CSA    = 1;
  // -- Cond-sub chain (Phase 2) configuration -------------
  localparam int ACC_CS_REG_PERIOD = 1;
  localparam bit ACC_CS_REG_OUT    = 1;
  // -- Split addtree final binary adder --------------------
  localparam bit ACC_AT_FF_ADD     = 1;

  // ==========================================================
  // Fixed-modulus mode (FIXED_Q)
  // ==========================================================
  //
  //   FIXED_Q = 0 (default):
  //     q, rho, and mu are run-time inputs.  Delay chains align
  //     them with the intmul_wrapper output (MUL_LAT cycles).
  //
  //   FIXED_Q = 1:
  //     The modulus and all derived constants are compile-time
  //     localparams.  Effects:
  //       - q, rho, mu delay chains eliminated (constants are
  //         passed directly to logjumps).
  //       - logjumps eliminates all internal rho*mu multipliers
  //         (RM_MUL_LAT = 0), q delay chains, and gets constant
  //         folding in all subtractors.
  //       - The run-time ports q, rho, mu are ignored.
  //
  // -- Mode switch ---
  localparam bit                              FIXED_Q        = 1;
  // -- Compile-time modulus (LOGQ bits) ---
  localparam bit [LOGQ-1:0]                   Q_VALUE        = 381'h1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab;
  // -- Compile-time Montgomery constant mu = -q^{-1} mod 2^{LOGW} ---
  localparam bit [LOGW-1:0]                   MU_VALUE       = 'h0fffd;
  // -- Compile-time rho values, packed LE ---
  //    RHO_VALUES[k*LOGQ +: LOGQ] = rho[k+1]  for k = 0 .. N_MUL-1
  //    (same packing as the rho input port)
  localparam bit [(LOGR/LOGW-1)*LOGQ-1:0]     RHO_VALUES     = 'h275073cccb0b33be44aaf5b83644fac86b854cd1cdb24e7c0e3c91ecbd79e2e91aa3af3475c7e16a5a86c9c05c67a8845af26cd0e23d04dce5270d77a2167e9d1ed756886fc1f4289fcd384a948cf24b5d66fc05acac45c7cc85c68298629a88ed96a04e5af6859e57d03dbe5b2134ae03b06d79e079a3948a803cb2e762ae2124a3f202f88c15925d29863c4eed5939537402c7dda19600f9b4d586bb49df94862f2e3fd4ca14d93fe650e14277acf6c75dfb89baa65fc6abc4f0aa50d5ea82c98ac1592ce76f5d653d16f11a124d3cb619fe708b81cdd7dda6fcc90c6c9e2de6b80a18060fe0948aa5192049938b7fcba7ef337d67655301d07ae9bcec78eb4c55952b3c515438f21359360b9fd02ea689cc52756eefd092051d0c7c2ba87e83e5aa272d48b2af62faa4249d23bc48eac080308cb6f2f839fd307df4e7f9a60505c5f0ec53b391d0ca1e6da4415114215b1d87485f20a6b9a06f71a10f22ccb4e0d7d4118a138ba0ed6096fe90c0e3e71e5557928cb8a1e6fcd2881c082c2a0720194dd521f8d3ee1927ea1e4db5759b9fea6485224ac26e0e5fc4dcf1eaf477e5b10440d1d5cd28c6e1badebf1cfff47d06c9626fd2589c5d0acb6a7f3db92765cd350be7c5058afc21ff74e884ede6a30e7d5d59cc6e1d5af3a8492e33562a8090f45a21606886bb1a68c5eccd67d803beccd5e14b6238701847aac103ea43f3f5c4637855af61b60378da2917eed2bae905785bade219e65697de322c92a8bfa73bb6e3c08e40a2f5afc14ba1a959a7c2f130fe1b621988c8aa63bc6431013bfb6d99551efb4624ae3f802c116e34d8c3320271f93452861dbb4e5e201cfba23b496f81989f08382ceb880c216f0e26ff5cce7e58db7818504b921db2f8aeadd31b2493f41b3681bd46d3bbc97ee4fde4e9edf08400442d343aa3407b60280311e657237990e95e69127675bf2a757c7b7053761bfcef973d118134d709708f8e3098044530b04d3d6d5fa005c567c7b078dd5aafaec632c76b5a059abf558e49f2a88ad10381f57ddd9fc15e68ece71c58530b10da1ea40f519b3c674a2467086cd5cc1b8d647553e7415625fe0070fc1316f1ca27d87dd84a44203242af48af8d0da30732e30cde0bf1eee5d104231465b74e64a09b683177a52125fbf97723dfc15a5de9d40cdb8f768c5b0d8c9f8710733155078666f05f57674fff8b042ee85609e3bbf0b41b896dcdfb1e8af4dd50d76294bcfe8a95784c159e1dcd09d21550a5f027cb3401fcd2b11eb513cb30ae9bc0750882652898225bccb03cd3b38111fa8823841e26eebbc371c8016a025f03e9013e58d0061f35adf022df566894a356af5e8ca070bcc71c82ad0aa31b268249dcd172c1660c72aa9f603d301e901e9015556d0061f381e09d0d4ba66331a614717a2ef88f0f887b1c1817794e873f6709089e1fd1fd58abf601dcffe9017fffd556;
  // -- Pre-computed rho_mu constants, packed LE ---
  //    RHO_MU_VALUES[k*LOGW +: LOGW] = (rho[n-1-k] * mu) mod 2^{LOGW}
  //    for k = 0 .. N_MUL-1.  Only used when FIXED_Q = 1.
  localparam bit [(LOGR/LOGW-1)*LOGW-1:0]     RHO_MU_VALUES  = 'h0fffcffff889f444f92d9dab6e482838c2ef0c9bbcbb4c13acb4a0e867b3cf58389a316ff1a2cafc91bfab0610833a;

  localparam IN_FIFO_DEPTH  = 512;
  localparam OUT_FIFO_DEPTH = 512;
  localparam PIPELINE_LAT   = modmul_pkg::modmul_latency(
        int'(LOGW), int'(LOGQ),
        int'(LOGR),
        // Big multiplier
        int'(MUL_FF_IN), int'(MUL_FF_MUL), int'(MUL_FF_OUT),
        int'(MUL_USE_CSA), int'(MUL_FF_CSA),
        int'(MUL_MORE_DSP), int'(MUL_NON_STD),
        int'(MUL_FF_ADD), int'(MUL_FF_DIAG), int'(MUL_FF_CSA_MID),
        int'(MUL_USE_KARATSUBA),
        int'(MUL_K_PIPE_DSP), int'(MUL_K_PIPE_PRE),
        int'(MUL_K_PIPE_POST), int'(MUL_K_PIPE_MID),
        // LogJumps reduction
        int'(LJ_FF_IN), int'(LJ_FF_MUL), int'(LJ_FF_OUT),
        int'(LJ_USE_CSA), int'(LJ_FF_CSA),
        int'(LJ_MORE_DSP), int'(LJ_NON_STD),
        int'(LJ_FF_ADD), int'(LJ_FF_DIAG), int'(LJ_FF_CSA_MID),
        int'(LJ_FF_MR_POST), int'(LJ_FF_RM),
        int'(LJ_MT_REG_PERIOD), int'(LJ_MT_REG_IN), int'(LJ_MT_REG_OUT),
        int'(LJ_MT_USE_CSA),
        int'(LJ_DSP_SMALL),
        // modacc mode parameters
        int'(ACC_USE_ADDTREE)  ,
        int'(ACC_MAX_COND_SUB) ,
        int'(ACC_AT_REG_PERIOD),
        int'(ACC_AT_REG_IN)    ,
        int'(ACC_AT_REG_OUT)   ,
        int'(ACC_AT_USE_CSA)   ,
        int'(ACC_CS_REG_PERIOD),
        int'(ACC_CS_REG_OUT)   ,
        // Fixed-modulus mode
        int'(FIXED_Q),
        int'(ACC_AT_FF_ADD),
        int'(LJ_FF_JOIN_ADD),
        // Post-CPA pipeline register
        int'(MUL_FF_CPA)
  );
  localparam FIFO_PROG_FULL = PIPELINE_LAT < 5 ? OUT_FIFO_DEPTH - 5 : OUT_FIFO_DEPTH - PIPELINE_LAT;

  logic m_tvalid_in_fifo_0, m_tready_in_fifo_0, m_tlast_in_fifo_0;
  logic [PCI_WIDTH-1:0] m_tdata_in_fifo_0;
  xpm_fifo_axis #(
        .CASCADE_HEIGHT         ( 0                 ), // DECIMAL
        .CDC_SYNC_STAGES        ( 3                 ), // DECIMAL
        .CLOCKING_MODE          ("independent_clock"), // String
        .ECC_MODE               ( "no_ecc"          ), // String
        .FIFO_DEPTH             ( IN_FIFO_DEPTH     ), // DECIMAL
        .FIFO_MEMORY_TYPE       ( "auto"            ), // String
        .PACKET_FIFO            ( "false"           ), // String
        .PROG_EMPTY_THRESH      ( 10                ), // DECIMAL
        .PROG_FULL_THRESH       ( 10                ), // DECIMAL
        .RD_DATA_COUNT_WIDTH    ( 1                 ), // DECIMAL
        .RELATED_CLOCKS         ( 0                 ), // DECIMAL
        .SIM_ASSERT_CHK         ( 0                 ), // DECIMAL; 0=disable simulation messages, 1=enable simulation messages
        .TDATA_WIDTH            ( PCI_WIDTH         ), // DECIMAL
        .TDEST_WIDTH            ( 1                 ), // DECIMAL
        .TID_WIDTH              ( 1                 ), // DECIMAL
        .TUSER_WIDTH            ( 1                 ), // DECIMAL
        .USE_ADV_FEATURES       ( "1000"            ), // String
        .WR_DATA_COUNT_WIDTH    ( 10                )  // DECIMAL
    ) in_fifo_0_inst (
        .almost_empty_axis      (                   ),
        .almost_full_axis       (                   ),
        .dbiterr_axis           (                   ),
        .m_aclk                 ( rtl_clk           ),
        .m_axis_tready          ( m_tready_in_fifo_0),
        .m_axis_tvalid          ( m_tvalid_in_fifo_0),
        .m_axis_tdata           ( m_tdata_in_fifo_0 ),
        .m_axis_tlast           ( m_tlast_in_fifo_0 ),
        .m_axis_tdest           (                   ),
        .m_axis_tid             (                   ),
        .m_axis_tkeep           (                   ),
        .m_axis_tstrb           (                   ),
        .m_axis_tuser           (                   ),
        .prog_empty_axis        (                   ),
        .prog_full_axis         (                   ),
        .rd_data_count_axis     (                   ),
        .sbiterr_axis           (                   ),
        .wr_data_count_axis     (                   ),
        .injectdbiterr_axis     (                   ),
        .injectsbiterr_axis     (                   ),
        .s_aclk                 ( axis_clk          ),
        .s_aresetn              ( axis_rst          ),
        .s_axis_tready          ( s_tready_0        ),
        .s_axis_tvalid          ( s_tvalid_0        ),
        .s_axis_tdata           ( s_tdata_0         ),
        .s_axis_tlast           ( s_tlast_0         ),
        .s_axis_tdest           (                   ),
        .s_axis_tid             (                   ),
        .s_axis_tkeep           (                   ),
        .s_axis_tstrb           (                   ),
        .s_axis_tuser           (                   )
    );

  logic m_tvalid_in_fifo_1, m_tready_in_fifo_1, m_tlast_in_fifo_1;
  logic [PCI_WIDTH-1:0] m_tdata_in_fifo_1;
  xpm_fifo_axis #(
        .CASCADE_HEIGHT         ( 0                 ), // DECIMAL
        .CDC_SYNC_STAGES        ( 3                 ), // DECIMAL
        .CLOCKING_MODE          ("independent_clock"), // String
        .ECC_MODE               ( "no_ecc"          ), // String
        .FIFO_DEPTH             ( IN_FIFO_DEPTH     ), // DECIMAL
        .FIFO_MEMORY_TYPE       ( "auto"            ), // String
        .PACKET_FIFO            ( "false"           ), // String
        .PROG_EMPTY_THRESH      ( 10                ), // DECIMAL
        .PROG_FULL_THRESH       ( 10                ), // DECIMAL
        .RD_DATA_COUNT_WIDTH    ( 1                 ), // DECIMAL
        .RELATED_CLOCKS         ( 0                 ), // DECIMAL
        .SIM_ASSERT_CHK         ( 0                 ), // DECIMAL; 0=disable simulation messages, 1=enable simulation messages
        .TDATA_WIDTH            ( PCI_WIDTH         ), // DECIMAL
        .TDEST_WIDTH            ( 1                 ), // DECIMAL
        .TID_WIDTH              ( 1                 ), // DECIMAL
        .TUSER_WIDTH            ( 1                 ), // DECIMAL
        .USE_ADV_FEATURES       ( "1000"            ), // String
        .WR_DATA_COUNT_WIDTH    ( 1                 )  // DECIMAL
    ) in_fifo_1_inst (
        .almost_empty_axis      (                   ),
        .almost_full_axis       (                   ),
        .dbiterr_axis           (                   ),
        .m_aclk                 ( rtl_clk           ),
        .m_axis_tready          ( m_tready_in_fifo_1),
        .m_axis_tvalid          ( m_tvalid_in_fifo_1),
        .m_axis_tdata           ( m_tdata_in_fifo_1 ),
        .m_axis_tlast           ( m_tlast_in_fifo_1 ),
        .m_axis_tdest           (                   ),
        .m_axis_tid             (                   ),
        .m_axis_tkeep           (                   ),
        .m_axis_tstrb           (                   ),
        .m_axis_tuser           (                   ),
        .prog_empty_axis        (                   ),
        .prog_full_axis         (                   ),
        .rd_data_count_axis     (                   ),
        .sbiterr_axis           (                   ),
        .wr_data_count_axis     (                   ),
        .injectdbiterr_axis     (                   ),
        .injectsbiterr_axis     (                   ),
        .s_aclk                 ( axis_clk          ),
        .s_aresetn              ( axis_rst          ),
        .s_axis_tready          ( s_tready_1        ),
        .s_axis_tvalid          ( s_tvalid_1        ),
        .s_axis_tdata           ( s_tdata_1         ),
        .s_axis_tlast           ( s_tlast_1         ),
        .s_axis_tdest           (                   ),
        .s_axis_tid             (                   ),
        .s_axis_tkeep           (                   ),
        .s_axis_tstrb           (                   ),
        .s_axis_tuser           (                   )
    );


    logic rtl_rst;
    xpm_cdc_sync_rst #(
        .DEST_SYNC_FF(3),  
        .INIT(1),  
        .INIT_SYNC_FF(1),  
        .SIM_ASSERT_CHK(1) 
    ) xpm_cdc_sync_rst_inst (
        .dest_rst(rtl_rst),
        .dest_clk(rtl_clk),
        .src_rst(~axis_rst)   
    );

    // now we have the input to the 500MHz clock domain with 512b/cc
    logic m_tvalid_in_fifo, m_tready_in_fifo, m_tdest_in_fifo, m_tlast_in_fifo;
    logic [PIPE_WIDTH-1:0] m_tdata_in_fifo;

    logic s_tvalid_out_fifo, s_tdest_out_fifo, s_prog_full, s_tlast_out_fifo;
    logic [PIPE_WIDTH-1:0] s_tdata_out_fifo;
    logic [PCI_WIDTH-1:0] s_tdata_out_fifo_0, s_tdata_out_fifo_1;
    
    // collect data from input fifos:
    generate
      if(PIPE_WIDTH == 512) begin
        assign s_tdata_out_fifo_0 = s_tdata_out_fifo;
        assign s_tdata_out_fifo_1 = s_tdata_out_fifo;

        assign m_tdata_in_fifo    = m_tvalid_in_fifo_0 ? m_tdata_in_fifo_0 : m_tdata_in_fifo_1;
        assign m_tvalid_in_fifo   = m_tvalid_in_fifo_0 || m_tvalid_in_fifo_1;
        assign m_tready_in_fifo_0 =  m_tvalid_in_fifo_0 && m_tready_in_fifo; 
        assign m_tready_in_fifo_1 = !m_tvalid_in_fifo_0 && m_tready_in_fifo; 
      end else if (PIPE_WIDTH == 1024) begin
        assign s_tdata_out_fifo_0 = s_tdata_out_fifo[PCI_WIDTH-1:0];
        assign s_tdata_out_fifo_1 = s_tdata_out_fifo[2*PCI_WIDTH-1:PCI_WIDTH];

        assign m_tdata_in_fifo    = {m_tdata_in_fifo_1, m_tdata_in_fifo_0};
        assign m_tvalid_in_fifo   = m_tvalid_in_fifo_0 && m_tvalid_in_fifo_1;
        assign m_tready_in_fifo_0 = m_tvalid_in_fifo && m_tready_in_fifo; 
        assign m_tready_in_fifo_1 = m_tvalid_in_fifo && m_tready_in_fifo; 
      end else begin
        $error("Invalid configuration of PIPE_WIDTH!");
      end
    endgenerate

    assign m_tlast_in_fifo  = m_tvalid_in_fifo_0 ? m_tlast_in_fifo_0 : m_tlast_in_fifo_1;
    assign m_tdest_in_fifo  = m_tvalid_in_fifo_0 ? 1'd0 : 1'd1;


    // perform pipelined computation:
    vadd_cdc_pipeline #(
        .WIDTH        ( PIPE_WIDTH      ),
        .ADD_CONSTANT ( ADD_CONSTANT    ),
        .PIPELINE_LAT ( PIPELINE_LAT    )
    ) pipeline_inst (
        .rtl_clk     ( rtl_clk          ),
        .rtl_rst     ( rtl_rst          ),  // active high

        // AXI Slave interface
        .s_tdata     ( m_tdata_in_fifo  ),
        .s_tlast     ( m_tlast_in_fifo  ),
        .s_tvalid    ( m_tvalid_in_fifo ),
        .s_tready    ( m_tready_in_fifo ),
        .s_tdest     ( m_tdest_in_fifo  ),

        // AXI Master interface
        .m_tdata     ( s_tdata_out_fifo ),
        .m_tlast     ( s_tlast_out_fifo ),
        .m_tvalid    ( s_tvalid_out_fifo),
        .m_prog_full ( s_prog_full      ),
        .m_tdest     ( s_tdest_out_fifo )
    );


    // distribute data to out fifos:
    logic s_tvalid_out_fifo_0, prog_full_out_fifo_0;
    logic s_tvalid_out_fifo_1, prog_full_out_fifo_1;
    generate
      if(PIPE_WIDTH == 512) begin
        assign s_prog_full = m_tdest_in_fifo == 1'd0 ? prog_full_out_fifo_0 : prog_full_out_fifo_1;
        assign s_tvalid_out_fifo_0 = s_tdest_out_fifo == 1'd0 && s_tvalid_out_fifo;
        assign s_tvalid_out_fifo_1 = s_tdest_out_fifo == 1'd1 && s_tvalid_out_fifo;    
      end else if (PIPE_WIDTH == 1024) begin
        assign s_prog_full = prog_full_out_fifo_0 || prog_full_out_fifo_1;
        assign s_tvalid_out_fifo_0 = s_tvalid_out_fifo;
        assign s_tvalid_out_fifo_1 = s_tvalid_out_fifo;
      end else begin
        $error("Invalid configuration of PIPE_WIDTH!");
      end
    endgenerate
    

    // out fifos:
    xpm_fifo_axis #(
        .CASCADE_HEIGHT         ( 0                 ), // DECIMAL
        .CDC_SYNC_STAGES        ( 3                 ), // DECIMAL
        .CLOCKING_MODE          ("independent_clock"), // String
        .ECC_MODE               ( "no_ecc"          ), // String
        .FIFO_DEPTH             ( OUT_FIFO_DEPTH    ), // DECIMAL
        .FIFO_MEMORY_TYPE       ( "auto"            ), // String
        .PACKET_FIFO            ( "false"           ), // String
        .PROG_EMPTY_THRESH      ( 10                ), // DECIMAL
        .PROG_FULL_THRESH       ( FIFO_PROG_FULL    ), // DECIMAL
        .RD_DATA_COUNT_WIDTH    ( 1                 ), // DECIMAL
        .RELATED_CLOCKS         ( 0                 ), // DECIMAL
        .SIM_ASSERT_CHK         ( 0                 ), // DECIMAL; 0=disable simulation messages, 1=enable simulation messages
        .TDATA_WIDTH            ( PCI_WIDTH         ), // DECIMAL
        .TDEST_WIDTH            ( 1                 ), // DECIMAL
        .TID_WIDTH              ( 1                 ), // DECIMAL
        .TUSER_WIDTH            ( 1                 ), // DECIMAL
        .USE_ADV_FEATURES       ( "100e"            ), // String
        .WR_DATA_COUNT_WIDTH    ( 10                )  // DECIMAL
    ) out_fifo_0_inst (
        .almost_empty_axis      (                   ),
        .almost_full_axis       (                   ),
        .dbiterr_axis           (                   ),
        .m_aclk                 ( axis_clk          ),
        .m_axis_tready          ( m_tready_0        ),
        .m_axis_tvalid          ( m_tvalid_0        ),
        .m_axis_tdata           ( m_tdata_0         ),
        .m_axis_tlast           ( m_tlast_0         ),
        .m_axis_tdest           (                   ),
        .m_axis_tid             (                   ),
        .m_axis_tkeep           (                   ),
        .m_axis_tstrb           (                   ),
        .m_axis_tuser           (                   ),
        .prog_empty_axis        (                   ),
        .prog_full_axis         ( prog_full_out_fifo_0),
        .rd_data_count_axis     (                   ),
        .sbiterr_axis           (                   ),
        .wr_data_count_axis     (                   ),
        .injectdbiterr_axis     (                   ),
        .injectsbiterr_axis     (                   ),
        .s_aclk                 ( rtl_clk           ),
        .s_aresetn              ( axis_rst          ),
        .s_axis_tready          (                   ),
        .s_axis_tvalid          ( s_tvalid_out_fifo_0),
        .s_axis_tdata           ( s_tdata_out_fifo_0),
        .s_axis_tlast           ( s_tlast_out_fifo  ),
        .s_axis_tdest           (                   ),
        .s_axis_tid             (                   ),
        .s_axis_tkeep           (                   ),
        .s_axis_tstrb           (                   ),
        .s_axis_tuser           (                   )
    );

    xpm_fifo_axis #(
        .CASCADE_HEIGHT         ( 0                 ), // DECIMAL
        .CDC_SYNC_STAGES        ( 3                 ), // DECIMAL
        .CLOCKING_MODE          ("independent_clock"), // String
        .ECC_MODE               ( "no_ecc"          ), // String
        .FIFO_DEPTH             ( OUT_FIFO_DEPTH    ), // DECIMAL
        .FIFO_MEMORY_TYPE       ( "auto"            ), // String
        .PACKET_FIFO            ( "false"           ), // String
        .PROG_EMPTY_THRESH      ( 10                ), // DECIMAL
        .PROG_FULL_THRESH       ( FIFO_PROG_FULL    ), // DECIMAL
        .RD_DATA_COUNT_WIDTH    ( 1                 ), // DECIMAL
        .RELATED_CLOCKS         ( 0                 ), // DECIMAL
        .SIM_ASSERT_CHK         ( 0                 ), // DECIMAL; 0=disable simulation messages, 1=enable simulation messages
        .TDATA_WIDTH            ( PCI_WIDTH         ), // DECIMAL
        .TDEST_WIDTH            ( 1                 ), // DECIMAL
        .TID_WIDTH              ( 1                 ), // DECIMAL
        .TUSER_WIDTH            ( 1                 ), // DECIMAL
        .USE_ADV_FEATURES       ( "100e"            ), // String
        .WR_DATA_COUNT_WIDTH    ( 10                )  // DECIMAL
    ) out_fifo_1_inst (
        .almost_empty_axis      (                   ),
        .almost_full_axis       (                   ),
        .dbiterr_axis           (                   ),
        .m_aclk                 ( axis_clk          ),
        .m_axis_tready          ( m_tready_1        ),
        .m_axis_tvalid          ( m_tvalid_1        ),
        .m_axis_tdata           ( m_tdata_1         ),
        .m_axis_tlast           ( m_tlast_1         ),
        .m_axis_tdest           (                   ),
        .m_axis_tid             (                   ),
        .m_axis_tkeep           (                   ),
        .m_axis_tstrb           (                   ),
        .m_axis_tuser           (                   ),
        .prog_empty_axis        (                   ),
        .prog_full_axis         ( prog_full_out_fifo_1),
        .rd_data_count_axis     (                   ),
        .sbiterr_axis           (                   ),
        .wr_data_count_axis     (                   ),
        .injectdbiterr_axis     (                   ),
        .injectsbiterr_axis     (                   ),
        .s_aclk                 ( rtl_clk           ),
        .s_aresetn              ( axis_rst          ),
        .s_axis_tready          (                   ),
        .s_axis_tvalid          ( s_tvalid_out_fifo_1),
        .s_axis_tdata           ( s_tdata_out_fifo_1),
        .s_axis_tlast           ( s_tlast_out_fifo  ),
        .s_axis_tdest           (                   ),
        .s_axis_tid             (                   ),
        .s_axis_tkeep           (                   ),
        .s_axis_tstrb           (                   ),
        .s_axis_tuser           (                   )
    );


endmodule
