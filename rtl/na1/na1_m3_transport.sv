// M3 stored transport with M4 logical MCU mailbox access. No rendering,
// embedded blitter or synchronization response; optional M13 handoff/helper
// remain separate from this register/mailbox transport.
module na1_m3_transport #(parameter FULL_VREG=1, parameter ENABLE_IRQ=0, parameter ENABLE_BLIT=0)(
 input wire clk_sys,reset, input wire [12:0] req,
 input wire write, input wire [23:0] addr, input wire [15:0] wdata,
 input wire [1:0] byte_en, output wire [12:0] ack,
 output wire [207:0] rdata, output reg mcu_irq0_request,
 output reg [15:0] mcu_irq0_wdata,output reg [1:0] mcu_irq0_byte_en,
 output wire [127:0] mailbox_state,
 output wire [15:0] gfx_selector,
 output wire [15:0] irq_mask, output wire [7:0] irq_position,
 output wire irq_enabled,irq_write_commit,
 output wire [191:0] blit_registers,output wire blit_req,input wire blit_ack,
 output wire [2047:0] render_words,
 // Logical numeric slot words, not a physical C69 byte bus.
 input wire mcu_mailbox_req,mcu_mailbox_write,
 input wire [2:0] mcu_mailbox_slot,input wire [15:0] mcu_mailbox_wdata,
 input wire [1:0] mcu_mailbox_byte_en,
 output wire mcu_mailbox_ack,output reg [15:0] mcu_mailbox_rdata
);
 wire [15:0] register_1c;
 reg [15:0] mailbox[0:7];
 wire register_ack;reg mailbox_ack=0;
 wire [15:0] register_data;reg [15:0] mailbox_data=0;
 reg mcu_mailbox_done=0;
 genvar g;
 generate for(g=0;g<8;g=g+1) begin: snapshot
  assign mailbox_state[g*16+:16]=mailbox[g];
 end endgenerate
 assign mcu_mailbox_ack=!reset && mcu_mailbox_req && mcu_mailbox_done;
 na1_video_registers #(.FULL_BANK(FULL_VREG),.ENABLE_IRQ(ENABLE_IRQ),.ENABLE_BLIT(ENABLE_BLIT)) registers(
  .clk_sys(clk_sys),.reset(reset),.req(req[6]),.write(write),.addr(addr),
  .wdata(wdata),.byte_en(byte_en),.ack(register_ack),.rdata(register_data),
  .register_1c(register_1c),.gfx_selector(gfx_selector),.render_words(render_words),
  .irq_mask(irq_mask),.irq_position(irq_position),.irq_enabled(irq_enabled),.irq_write_commit(irq_write_commit),
  .blit_registers(blit_registers),.blit_req(blit_req),.blit_ack(blit_ack));
 wire mailbox_req=req[1] && addr>=24'h3f8000 && addr<=24'h3fffff;
 wire [2:0] slot=addr[3:1];
 integer i;
 assign ack=reset ? 13'd0 : {6'd0,register_ack,4'd0,mailbox_ack,1'b0};
 assign rdata={96'd0,register_data,64'd0,mailbox_data,16'd0};
 // A low request edge rearms; held requests cannot repeat writes/events.
 always @(posedge clk_sys) begin
  mcu_irq0_request<=0;
  if(reset) begin
   mailbox_ack<=0;mailbox_data<=0;
   mcu_mailbox_done<=0;mcu_mailbox_rdata<=0;
   mcu_irq0_wdata<=0;mcu_irq0_byte_en<=0;
   for(i=0;i<8;i=i+1) mailbox[i]<=0;
  end else begin
   if(!mailbox_req) mailbox_ack<=0;
   else if(!mailbox_ack) begin
    if(write) begin
     if(byte_en[1]) mailbox[slot][15:8]<=wdata[15:8];
     if(byte_en[0]) mailbox[slot][7:0]<=wdata[7:0];
     mailbox_data<=0;
     // MAME tests full offset==4, not mirrored slot index==4.
     if(addr[23:1]==23'h1fc004) begin
      mcu_irq0_request<=1;mcu_irq0_wdata<=wdata;mcu_irq0_byte_en<=byte_en;
     end
    end else mailbox_data<=mailbox[slot];
    mailbox_ack<=1;
   end
   // [IMPLEMENTATION] CPU acceptance wins simultaneous mailbox accesses;
   // the MCU request remains held and completes on a later edge. No IRQ or
   // manufactured slot-2 status is produced by MCU mailbox access.
   if(!mcu_mailbox_req) mcu_mailbox_done<=0;
   else if(!mcu_mailbox_done && !(mailbox_req && !mailbox_ack)) begin
    if(mcu_mailbox_write) begin
     if(mcu_mailbox_byte_en[1]) mailbox[mcu_mailbox_slot][15:8]<=mcu_mailbox_wdata[15:8];
     if(mcu_mailbox_byte_en[0]) mailbox[mcu_mailbox_slot][7:0]<=mcu_mailbox_wdata[7:0];
     mcu_mailbox_rdata<=0;
    end else mcu_mailbox_rdata<=mailbox[mcu_mailbox_slot];
    mcu_mailbox_done<=1;
   end
  end
 end
endmodule
