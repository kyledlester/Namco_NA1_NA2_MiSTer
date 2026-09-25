// Single 128-word owner. Optional M11 IRQ and M13 trigger handoff; no renderer.
// FULL_BANK=0 is a historical regression configuration, not production mapping.
module na1_video_registers #(parameter FULL_BANK=1, parameter ENABLE_IRQ=0, parameter ENABLE_BLIT=0)(
 input wire clk_sys,reset,req,write,input wire [23:0] addr,
 input wire [15:0] wdata,input wire [1:0] byte_en,
 output wire ack,output reg [15:0] rdata=0,
 output wire [15:0] gfx_selector,register_1c,
 output wire [15:0] irq_mask, output wire [7:0] irq_position,
 output reg irq_enabled=0, output reg irq_write_commit=0,
 output wire [191:0] blit_registers,output wire blit_req,input wire blit_ack,
 output wire [2047:0] render_words // M15B observation of all 128 stored words
);
 reg [15:0] words[0:127];
 reg done=0;
 wire [6:0] index=addr[7:1];
 wire in_range=addr>=24'hefff00 && addr<=24'hefffff;
 // Writes to these active registers are rejected BEFORE storage acceptance.
 wire trigger=write && index==7'h0c;
 wire active_write=write && ((!ENABLE_BLIT && index==7'h0c) || (!ENABLE_IRQ && index==7'h0d));
 wire selected=req && in_range && !active_write &&
               (!ENABLE_IRQ || index!=7'h0d || |byte_en) &&
               (!trigger || !ENABLE_BLIT || |byte_en) && (FULL_BANK || index==7'h0e);
 assign irq_mask=words[7'h0d];
 assign irq_position=words[7'h45][7:0];
 assign ack=!reset && selected && done && (!trigger || !ENABLE_BLIT || blit_ack);
 assign blit_req=ENABLE_BLIT && !reset && selected && trigger && done;
 genvar b;
 generate for(b=0;b<12;b=b+1) begin: blit_snapshot
  assign blit_registers[b*16+:16]=words[b];
 end endgenerate
 generate for(b=0;b<128;b=b+1) begin: render_snapshot
  assign render_words[b*16+:16]=words[b];
 end endgenerate
 assign gfx_selector=words[6]; // Observation of the single stored $EFFF0C owner.
 assign register_1c=words[7'h0e]; // Observation alias; no second storage word.
// synthesis translate_off
`ifndef SYNTHESIS
 integer i;
 // [IMPLEMENTATION] Simulation-only initial contents, not physical reset values.
 initial for(i=0;i<128;i=i+1) words[i]=0;
`endif
// synthesis translate_on
 always @(posedge clk_sys) begin
  irq_write_commit<=0;
  if(reset) begin
   done<=0;rdata<=0;
   // Preserve ONLY the existing M3-defined $1C reset policy.
   words[7'h0e]<=0;
   // M29.4 [HW-CONFIRMED]: system reset is the game's power-on, so IRQ
   // delivery stays off until its first $EFFF1A write (MAME: enable flag 0
   // until that write). Retaining it let a stale run between MRA download
   // segments leave IRQ3/IRQ4 pending before Exvania's single $0017 write.
   irq_enabled<=0;
  end else if(!selected) done<=0;
  else if(!done) begin
   if(write) begin
    if(ENABLE_IRQ && index==7'h0d) begin irq_enabled<=1;irq_write_commit<=1;end
    if(byte_en[1]) words[index][15:8]<=wdata[15:8];
    if(byte_en[0]) words[index][7:0]<=wdata[7:0];
    rdata<=0;
   end else rdata<=words[index];
   done<=1;
  end
 end
endmodule
