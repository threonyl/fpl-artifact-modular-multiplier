module vadd_cdc_tb ();
 
function automatic logic [511:0] byte_endian_swap_512(input logic [511:0] in_data);
    logic [511:0] out_data;
    for (int i = 0; i < 64; i++) begin
        out_data[i*8 +: 8] = in_data[(63-i)*8 +: 8];
    end
    return out_data;
endfunction

  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic fast_clk = 0;
  always #2 fast_clk = ~fast_clk;

  localparam ADD_CONSTANT = 1;
  localparam PCI_WIDTH = 512;
  localparam PIPE_WIDTH = 1024;

  // AXI Slave interface
  logic [PCI_WIDTH-1:0] s_tdata_0, s_tdata_0_sw;
  logic s_tlast_0 = 0;
  logic s_tvalid_0 = 0;
  logic s_tready_0;
  logic [PCI_WIDTH-1:0] s_tdata_1, s_tdata_1_sw;
  logic s_tlast_1 = 0;
  logic s_tvalid_1 = 0;
  logic s_tready_1;

  // AXI Master interface
  logic [PCI_WIDTH-1:0] m_tdata_0, m_tdata_0_ref, m_tdata_0_ref_sw;
  logic m_tlast_0;
  logic m_tvalid_0;
  logic m_tready_0 = 0;
  logic [PCI_WIDTH-1:0] m_tdata_1;
  logic m_tlast_1;
  logic m_tvalid_1;
  logic m_tready_1 = 0;

  vadd_cdc_top  #(
    .PCI_WIDTH(PCI_WIDTH),
    .PIPE_WIDTH(PIPE_WIDTH),
    .ADD_CONSTANT(ADD_CONSTANT)
  ) dut (
    .axis_clk(clk),
    .rtl_clk(fast_clk),
    .axis_rst(~rst),

    // AXI Slave interface
    .s_tdata_0(s_tdata_0),
    .s_tlast_0(s_tlast_0),
    .s_tvalid_0(s_tvalid_0),
    .s_tready_0(s_tready_0),
    .s_tdata_1(s_tdata_1),
    .s_tlast_1(s_tlast_1),
    .s_tvalid_1(s_tvalid_1),
    .s_tready_1(s_tready_1),

    // AXI Master interface
    .m_tdata_0(m_tdata_0),
    .m_tlast_0(m_tlast_0),
    .m_tvalid_0(m_tvalid_0),
    .m_tready_0(m_tready_0),
    .m_tdata_1(m_tdata_1),
    .m_tlast_1(m_tlast_1),
    .m_tvalid_1(m_tvalid_1),
    .m_tready_1(m_tready_1)
  );

  integer fd_in0, fd_in1, fd_out;
  
  // receive output 0 (write)
  logic error = 0;
  initial begin
    #101;

    fd_out = $fopen("/home/fkrieger/Documents/Projects/logjumps/cryptocore_u280/sw/dma/mem/reference/pci_00_r.bin", "rb");
    if(fd_out == 0) begin
      $error("Error opening File\n");
      $finish;
    end
    
    for(integer i = 0; i < 500; i += 1) begin
      $fread(m_tdata_0_ref_sw, fd_out, i*64, 64);
      m_tdata_0_ref = byte_endian_swap_512(m_tdata_0_ref_sw);
      
      m_tready_0 = 1;
      @(posedge clk iff m_tvalid_0 && m_tready_0);
      assert (m_tdata_0 == m_tdata_0_ref);
      if(m_tdata_0 != m_tdata_0_ref) begin
        error = 1;
        $display("Error in m_tdata_0");
      end
      #1;
      m_tready_0 = 0;
      
      // 0-10000: no pressure
      // 10000-20000: write pressure
      // 20000-30000: read pressure
      // >30000: both pressure
      if( (i > 10000 && i <= 20000) || i > 30000) begin
        repeat($random % 3) begin
          @(posedge clk);
          #1;
        end
      end
    end

  end

  // receive output 1 (write)
  initial begin
    #101;

    
    for(integer i = 0; i < 500; i += 1) begin
      
      m_tready_1 = 1;
      @(posedge clk iff m_tvalid_1 && m_tready_1);
      assert (m_tdata_1 == {8'h00, {(PCI_WIDTH-8){1'd0}}});
      if(m_tdata_1 != {8'h00, {(PCI_WIDTH-8){1'd0}}}) begin
        error = 1;
        $display("Error in m_tdata_1");
      end
      #1;
      m_tready_1 = 0;
      
      // 0-10000: no pressure
      // 10000-20000: write pressure
      // 20000-30000: read pressure
      // >30000: both pressure
      if( (i > 10000 && i <= 20000) || i > 30000) begin
        repeat($random % 3) begin
          @(posedge clk);
          #1;
        end
      end

    end

    #101;
    if(error)
      $display("ERRORS IN SIMULATION!\n");
    else
      $display("OK!\n");

    $finish;
  end

  // provide input 0 (read)
  initial begin
    #501;

    fd_in0 = $fopen("/home/fkrieger/Documents/Projects/logjumps/cryptocore_u280/sw/dma/mem/input/pci_00_i.bin", "rb");
    if(fd_in0 == 0) begin
      $error("Error opening File\n");
      $finish;
    end

    rst = 0;
    #11;
    
    for(integer i = 0; i < 500; i += 1) begin
      $fread(s_tdata_0_sw, fd_in0, i*64, 64);
      s_tdata_0 = byte_endian_swap_512(s_tdata_0_sw);
      
      s_tvalid_0 = 1;
      // s_tdata_0 = {(PIPE_WIDTH){1'd0}} + i;
      @(posedge clk iff s_tvalid_0 && s_tready_0);
      #1;
      s_tvalid_0 = 0;

      if( i > 20000) begin
        repeat($random % 3) begin
          @(posedge clk);
          #1;
        end
      end

    end

  end

   // provide input 1 (read)
  initial begin
    #601;

    fd_in1 = $fopen("/home/fkrieger/Documents/Projects/logjumps/cryptocore_u280/sw/dma/mem/input/pci_01_i.bin", "rb");
    if(fd_in1 == 0) begin
      $error("Error opening File\n");
      $finish;
    end
    
    for(integer i = 0; i < 500; i += 1) begin
      $fread(s_tdata_1_sw, fd_in1, i*64, 64);
      s_tdata_1 = byte_endian_swap_512(s_tdata_1_sw);

      s_tvalid_1 = 1;
      // s_tdata_1 = {8'hff, {(PCI_WIDTH-8){1'd0}}} + i;
      @(posedge clk iff s_tvalid_1 && s_tready_1);
      #1;
      s_tvalid_1 = 0;

      if( i > 20000) begin
        repeat($random % 3) begin
          @(posedge clk);
          #1;
        end
      end

    end

  end


endmodule