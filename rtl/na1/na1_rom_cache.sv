// CPU read cache for the two immutable ROM images (program and mask), between
// the ROM-board I/O decode and the CPU/blitter ROM owner in na1_blitter_fabric.
//
// Why: MAME's NA-1 68000 completes every ROM/work-RAM bus cycle in the minimum
// four clocks. Here the ROM lives in SDRAM behind shared arbitration; its
// acknowledge arrives ~19 clk_sys edges after the request, one edge too late
// for a single FX68K wait state, so every ROM access costs two extra CPU
// clocks (6 instead of 4). Numan Athletics' Tower/Missile-flight updates need
// ~12-13.5 ms of zero-wait CPU time per 16.7 ms frame; at 6-clock ROM cycles
// they take ~19 ms, miss the next IRQ3 update gate and run every other frame
// (docs/NUMAN_ROOT_CAUSE.md). A hit acknowledges in time for a zero-wait
// cycle, restoring the 4-clock bus cycle for resident ROM words.
//
// Scope: CPU reads only; blitter ROM reads and ROM-board I/O addresses never
// reach this module. ROM contents change only through an index-0 download,
// which holds the machine in reset; `flush` (download active) clears every
// entry sequentially and bypasses the cache until the sweep finishes.
// Contract up and down: held request / level acknowledge, request withdrawn
// for >=1 edge between transactions (na1_memory / na1_sdram_backend).
// Direct mapped, one 16-bit word per entry, filled from the ordinary word
// response; key = {image, word address}. No game identity or address policy.
module na1_rom_cache #(parameter INDEX_BITS=14)(
 input wire clk_sys,reset,flush,
 input wire req,image,input wire [21:0] word_addr,
 output wire ack,output wire [15:0] rdata,
 output wire down_req,input wire down_ack,input wire [15:0] down_rdata
);
 localparam TAG_BITS=23-INDEX_BITS;
 localparam ENTRIES=1<<INDEX_BITS;
 localparam IDLE=3'd0,READ=3'd1,COMPARE=3'd2,MISS=3'd3,RESPOND=3'd4;
 // Entry = {valid, tag, data}. Power-up contents are zero (all invalid).
 (* ramstyle = "M10K, no_rw_check" *) reg [TAG_BITS+16:0] entries[0:ENTRIES-1];
 reg [2:0] state=IDLE;
 reg [INDEX_BITS-1:0] held_index=0;
 reg [TAG_BITS-1:0] held_tag=0;
 reg [TAG_BITS+16:0] entry=0;
 reg [15:0] response=0;
 reg flushing=1'b0;
 reg [INDEX_BITS-1:0] sweep=0;
// synthesis translate_off
`ifndef SYNTHESIS
 integer i;
 initial for(i=0;i<ENTRIES;i=i+1) entries[i]=0;
`endif
// synthesis translate_on
 wire bypass=flush || flushing;
 wire hit=entry[TAG_BITS+16] && entry[TAG_BITS+15:16]==held_tag;
 assign ack=!reset && req && state==RESPOND;
 assign rdata=ack ? response : 16'd0;
 assign down_req=!reset && req && state==MISS;
 always @(posedge clk_sys) begin
  // Registered synchronous read; the address is the held index (READ stage).
  entry<=entries[held_index];
  if(flush || flushing) begin
   // Sweep every entry to invalid. A flush request restarts the sweep.
   entries[sweep]<={(TAG_BITS+17){1'b0}};
   sweep<=flush ? {INDEX_BITS{1'b0}} : sweep+1'b1;
   flushing<=flush || sweep!={INDEX_BITS{1'b1}};
  end else if(state==MISS && req && down_ack && !reset)
   entries[held_index]<={1'b1,held_tag,down_rdata};
  if(reset) state<=IDLE;
  else case(state)
   IDLE: if(req) begin
    {held_tag,held_index}<={image,word_addr};
    state<=READ;
   end
   READ: state<=req ? COMPARE : IDLE;
   COMPARE: if(!req) state<=IDLE;
            else if(hit && !bypass) begin response<=entry[15:0];state<=RESPOND;end
            else state<=MISS;
   MISS: if(!req) state<=IDLE; // withdrawal cancels; the backend drains
         else if(down_ack) begin response<=down_rdata;state<=RESPOND;end
   RESPOND: if(!req) state<=IDLE;
   default: state<=IDLE;
  endcase
 end
endmodule
