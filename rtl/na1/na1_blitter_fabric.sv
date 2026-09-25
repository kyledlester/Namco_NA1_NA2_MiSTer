// Resource-level CPU/blitter ownership. Register/mailbox transport stays on
// the original CPU tuple: EFFF18 can wait while DMA uses destination stores.
// All destination accesses use existing handlers with full BE11. No arrays.
module na1_blitter_fabric(
 input wire clk_sys,reset,blit_req,input wire [191:0] blit_registers,
 output wire blit_ack,blit_fault,
 input wire cpu_rom_req,cpu_rom_image,input wire [21:0] cpu_rom_word_addr,
 output wire cpu_rom_ack,output wire [15:0] cpu_rom_rdata,
 output wire rom_req,rom_image,output wire [21:0] rom_word_addr,
 input wire rom_ack,input wire [15:0] rom_rdata,
 input wire cpu_work_req,cpu_work_write,input wire [17:0] cpu_work_word_addr,
 input wire [15:0] cpu_work_wdata,input wire [1:0] cpu_work_byte_en,
 output wire cpu_work_ack,output wire [15:0] cpu_work_rdata,
 output wire work_req,work_write,output wire [17:0] work_word_addr,
 output wire [15:0] work_wdata,output wire [1:0] work_byte_en,
 input wire work_ack,input wire [15:0] work_rdata,
 input wire [12:0] cpu_peripheral_req,input wire cpu_peripheral_write,
 input wire [23:0] cpu_peripheral_addr,input wire [15:0] cpu_peripheral_wdata,
 input wire [1:0] cpu_peripheral_byte_en,
 output wire [12:0] cpu_peripheral_ack,output wire [207:0] cpu_peripheral_rdata,
 input wire [12:0] direct_ack,input wire [207:0] direct_rdata,
 output wire [12:0] peripheral_req,output wire peripheral_write,
 output wire [23:0] peripheral_addr,output wire [15:0] peripheral_wdata,
 output wire [1:0] peripheral_byte_en,
 input wire [12:0] peripheral_ack,input wire [207:0] peripheral_rdata,
 output wire source_event,destination_event,complete_event,
 output wire [31:0] source_addr,destination_addr,
 output wire [15:0] destination_data,output wire [2:0] debug_state
);
 wire sr,sa,dr,da;wire [15:0] sd;
 na1_blitter engine(.clk_sys(clk_sys),.reset(reset),.req(blit_req),.registers(blit_registers),
  .ack(blit_ack),.fault(blit_fault),.source_req(sr),.source_addr(source_addr),.source_ack(sa),.source_data(sd),
  .destination_req(dr),.destination_addr(destination_addr),.destination_data(destination_data),.destination_ack(da),
  .source_event(source_event),.destination_event(destination_event),.complete_event(complete_event),.debug_state(debug_state));
 wire dma_rom=sr && source_addr>=32'h400000;
 wire dma_mask=source_addr<32'hc00000;
 wire [31:0] rom_offset=source_addr-(dma_mask ? 32'h400000 : 32'hc00000);
 wire rom_dma_ack,work_dma_ack;wire [15:0] rom_dma_data,work_dma_data;
 na1_word_arbiter #(.WIDTH(23)) rom_owner(.clk_sys(clk_sys),.reset(reset),
  .req0(cpu_rom_req),.tuple0({cpu_rom_image,cpu_rom_word_addr}),.ack0(cpu_rom_ack),.data0(cpu_rom_rdata),
  .req1(dma_rom),.tuple1({dma_mask,rom_offset[22:1]}),.ack1(rom_dma_ack),.data1(rom_dma_data),
  .backend_req(rom_req),.backend_tuple({rom_image,rom_word_addr}),.backend_ack(rom_ack),.backend_data(rom_rdata));
 na1_word_arbiter #(.WIDTH(37)) work_owner(.clk_sys(clk_sys),.reset(reset),
  .req0(cpu_work_req),.tuple0({cpu_work_write,cpu_work_word_addr,cpu_work_wdata,cpu_work_byte_en}),.ack0(cpu_work_ack),.data0(cpu_work_rdata),
  .req1(sr && !dma_rom),.tuple1({1'b0,source_addr[18:1],16'd0,2'b11}),.ack1(work_dma_ack),.data1(work_dma_data),
  .backend_req(work_req),.backend_tuple({work_write,work_word_addr,work_wdata,work_byte_en}),.backend_ack(work_ack),.backend_data(work_rdata));
 assign sa=dma_rom ? rom_dma_ack : work_dma_ack;
 assign sd=dma_rom ? rom_dma_data : work_dma_data;
 wire [12:0] cpu_store_req=cpu_peripheral_req & 13'h1fbd; // except mailbox and registers
 wire [12:0] dma_region;
 na1_decode decode_destination(.addr(destination_addr[23:0]),.region(dma_region));
 wire store_cpu_ack;wire [15:0] store_cpu_data;
 reg [15:0] store_data;integer i;
 always @* begin
  store_data=0;
  for(i=0;i<13;i=i+1) if(peripheral_req[i]) store_data=peripheral_rdata[i*16+:16];
 end
 wire store_active;wire [55:0] store_tuple;
 na1_word_arbiter #(.WIDTH(56)) stores_owner(.clk_sys(clk_sys),.reset(reset),
  .req0(|cpu_store_req),.tuple0({cpu_store_req,cpu_peripheral_write,cpu_peripheral_addr,cpu_peripheral_wdata,cpu_peripheral_byte_en}),
  .ack0(store_cpu_ack),.data0(store_cpu_data),
  .req1(dr),.tuple1({dma_region,1'b1,destination_addr[23:0],destination_data,2'b11}),.ack1(da),.data1(),
  .backend_req(store_active),.backend_tuple(store_tuple),.backend_ack(|(peripheral_req & peripheral_ack)),.backend_data(store_data));
 assign peripheral_req=store_active ? store_tuple[55:43] : 13'd0;
 assign {peripheral_write,peripheral_addr,peripheral_wdata,peripheral_byte_en}=store_tuple[42:0];
 assign cpu_peripheral_ack=direct_ack | ({13{store_cpu_ack}} & cpu_store_req);
 genvar g;
 generate for(g=0;g<13;g=g+1) begin: response_slots
  assign cpu_peripheral_rdata[g*16+:16]=direct_rdata[g*16+:16] |
      (cpu_store_req[g] && store_cpu_ack ? store_cpu_data : 16'd0);
 end endgenerate
endmodule
