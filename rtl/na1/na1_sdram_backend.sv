// M15D general SDRAM backend: several logical held-request clients above one
// physical MiSTer controller channel (ch1 of rtl/vendor/sdram.sv).
//
// Client contract (all clients, index i): hold req/write/word_addr/wdata/
// byte_en stable until ack. ack is a level held while req stays high; rdata
// is valid only while ack. Withdraw req for >=1 edge before the next request.
// Withdrawing req before ack cancels the logical transaction; an already
// issued physical operation still retires (a write commits once) but its
// completion is drained and never acknowledged to anyone.
//
// Physical contract (verified against the vendored controller):
// * ch1_req is OR-latched inside the controller and cleared only when the
//   idle state consumes it, so the request must be a single-cycle pulse and
//   no second pulse may be issued until the previous transaction has retired.
// * ch1_ready is a one-cycle pulse. For reads dout[47:0] is valid at the
//   edge where ready is sampled; dout[63:48] is written one edge later. The
//   backend therefore completes every transaction one cycle after ready and
//   captures all four burst words at that point.
// * address/data/byte enables are sampled when the controller leaves idle,
//   which may be many cycles after the pulse (refresh), so they are held
//   registered until completion.
//
// Arbitration: at most one physical transaction outstanding, one outstanding
// logical transaction per client. While download_active only client
// DOWNLOAD may be served. Otherwise client PRIORITY (character prefetch) wins
// whenever it is pending; the remaining clients are served round robin.
// No aging, slots, bank or row optimisation, and no manual refresh.
// M20A: client BURST2 (the C219 sample reader) additionally receives its
// full four-word burst in burst_rdata2, held while its ack holds, exactly as
// burst_rdata serves PRIORITY; a separate register so neither client can
// overwrite the other's held burst. BURST2 is an ordinary round-robin client.
module na1_sdram_backend #(parameter CLIENTS=4,PRIORITY=3,DOWNLOAD=0,BURST2=-1)(
 input wire clk_sys,
 input wire reset,            // runtime reset: cancel logical clients, drain
 input wire reset_controller, // controller init: drop everything immediately
 input wire download_active,
 input wire [CLIENTS-1:0] req,write,
 input wire [CLIENTS*26-1:0] word_addr,
 input wire [CLIENTS*16-1:0] wdata,
 input wire [CLIENTS*2-1:0] byte_en,
 output wire [CLIENTS-1:0] ack,
 output wire [CLIENTS*16-1:0] rdata,
 output reg [63:0] burst_rdata=0,     // PRIORITY client's full burst, stable while its ack holds
 output reg [63:0] burst_rdata2=0,    // BURST2 client's full burst, stable while its ack holds
 output reg phy_req=0,output reg phy_rnw=1,
 output reg [25:0] phy_word_addr=0,output reg [15:0] phy_wdata=0,
 output reg [1:0] phy_byte_en=2'b11,
 input wire phy_ready,input wire [63:0] phy_rdata,
 output wire phy_busy
);
 localparam OW=(CLIENTS>1)?$clog2(CLIENTS):1;
 localparam [OW-1:0] PRI=PRIORITY;
 reg busy=0,drain=0,ready_seen=0;
 reg [OW-1:0] owner=0,last=0;
 reg [CLIENTS-1:0] done=0;
 reg [15:0] response[0:CLIENTS-1];
 assign phy_busy=busy;

 // A client is pending when it holds a request that has neither been granted
 // nor completed. done[i] clears as soon as req[i] is withdrawn.
 wire [CLIENTS-1:0] pending;
 wire [CLIENTS-1:0] eligible;
 genvar g;
 generate for(g=0;g<CLIENTS;g=g+1) begin: clients
  assign pending[g]=req[g] && !done[g] && !(busy && owner==g);
  assign eligible[g]=pending[g] && (download_active ? g==DOWNLOAD : 1'b1);
  assign ack[g]=!reset && req[g] && done[g];
  assign rdata[g*16+:16]=ack[g] ? response[g] : 16'd0;
 end endgenerate

 // Round-robin pick among non-priority clients, starting after `last`.
 reg [OW-1:0] rr_pick;reg rr_found;
 integer k;reg [OW:0] idx;
 always @* begin
  rr_found=0;rr_pick=0;
  for(k=1;k<=CLIENTS;k=k+1) begin
   idx=last+k;
   if(idx>=CLIENTS) idx=idx-CLIENTS;
   if(!rr_found && idx!=PRIORITY && eligible[idx[OW-1:0]]) begin
    rr_found=1;rr_pick=idx[OW-1:0];
   end
  end
 end
 wire grant_priority=eligible[PRIORITY];
 wire grant=!busy && !ready_seen && (grant_priority || rr_found);
 wire [OW-1:0] grant_idx=grant_priority ? PRI : rr_pick;
 // Granted client's tuple as constant-index muxes (unrolled at compile time).
 // A variable part-select `word_addr[grant_idx*26+:26]` made Quartus infer a
 // grant_idx*26 DSP multiplier plus a barrel shifter on the critical
 // blitter -> phy_word_addr path (M16 fit: -2.126 ns). Same function, same
 // cycle: grant_idx only takes the values 0..CLIENTS-1.
 reg grant_write;reg [25:0] grant_addr;reg [15:0] grant_wdata;reg [1:0] grant_be;
 integer j;
 always @* begin
  grant_write=0;grant_addr=0;grant_wdata=0;grant_be=2'b11;
  for(j=0;j<CLIENTS;j=j+1) if(grant_idx==j) begin
   grant_write=write[j];grant_addr=word_addr[j*26+:26];
   grant_wdata=wdata[j*16+:16];grant_be=byte_en[j*2+:2];
  end
 end

 integer i;
 initial for(i=0;i<CLIENTS;i=i+1) response[i]=0;
 always @(posedge clk_sys) begin
  phy_req<=0;
  if(reset_controller) begin
   busy<=0;drain<=0;ready_seen<=0;done<=0;last<=0;owner<=0;
  end else begin
   if(reset) begin
    done<=0;
    if(busy) drain<=1;
   end else begin
    for(i=0;i<CLIENTS;i=i+1) if(!req[i]) done[i]<=0;
    if(busy && !req[owner]) drain<=1;
   end
   if(busy) begin
    if(phy_ready) ready_seen<=1;
    if(ready_seen) begin
     // One cycle after ready: all four burst words are valid.
     ready_seen<=0;busy<=0;drain<=0;
     if(!drain && !reset) begin
      if(owner==PRI) burst_rdata<=phy_rdata;
      if(BURST2>=0 && owner==BURST2) burst_rdata2<=phy_rdata;
      response[owner]<=phy_rnw ? phy_rdata[15:0] : 16'd0;
      done[owner]<=1;
     end
    end
   end else if(grant && !reset) begin
    owner<=grant_idx;busy<=1;phy_req<=1;
    phy_rnw<=!grant_write;
    phy_word_addr<=grant_addr;
    phy_wdata<=grant_wdata;
    phy_byte_en<=grant_write ? grant_be : 2'b11;
    if(grant_idx!=PRIORITY) last<=grant_idx;
   end
  end
 end
endmodule
