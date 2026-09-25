// M15D renderer-facing character row prefetch. One backend client fetches
// complete 8-pixel 8-bpp character rows (four consecutive character words,
// aligned to four) and queues each row in a shallow per-layer FIFO.
//
// Contract per layer l:
//  * command side: hold fetch_req[l]/fetch_row[l]; fetch_accept[l] pulses for
//    one cycle when the command is latched. M19: up to CMDQ commands may be
//    latched per layer (a small in-order command queue), and a command is
//    latched only while its result is guaranteed a FIFO slot (queued +
//    in-flight + queued results < DEPTH), so results are always pushed
//    without back-pressure. The queue lets the next row's memory request
//    issue the cycle after the previous one retires instead of waiting for
//    the renderer's walker round trip (M19 line-budget measurement).
//  * data side: row_valid[l] with row_data[l] (word 4r+k at bits 16k+15:16k);
//    row_pop[l] consumes the head entry in the same cycle. Entries are used
//    once and never retained: there are no tags, no cache and no invalidation.
//    Rows are pushed in the order their commands were accepted (per layer).
//  * coherency is structural: every row is read from authoritative character
//    SDRAM after all earlier retired writes; nothing here is authoritative.
//  * reset clears queues, the in-flight marker and the FIFOs; a memory
//    response arriving after reset for a pre-reset request is not pushed
//    (the backend drains it and never acknowledges, M15D).
// Rendering, decoding, scrolling and priority belong to the renderer.
module na1_char_prefetch #(parameter LAYERS=3,DEPTH=2,CMDQ=2)(
 input wire clk_sys,reset,
 input wire [LAYERS-1:0] fetch_req,input wire [LAYERS*15-1:0] fetch_row,
 output reg [LAYERS-1:0] fetch_accept=0,
 output wire [LAYERS-1:0] row_valid,output wire [LAYERS*64-1:0] row_data,
 input wire [LAYERS-1:0] row_pop,
 output wire mem_req,output wire [14:0] mem_row,
 input wire mem_ack,input wire [63:0] mem_data
);
 localparam LW=(LAYERS>1)?$clog2(LAYERS):1;
 localparam PW=(DEPTH>1)?$clog2(DEPTH):1;
 localparam CW=$clog2(DEPTH+1);
 localparam QW=(CMDQ>1)?$clog2(CMDQ):1;
 localparam QCW=$clog2(CMDQ+1);
 // per-layer command queue (not yet issued)
 reg [14:0] cmdq[0:LAYERS-1][0:CMDQ-1];
 reg [QW-1:0] q_rd[0:LAYERS-1],q_wr[0:LAYERS-1];
 reg [QCW-1:0] q_count[0:LAYERS-1];
 // per-layer result FIFO
 reg [63:0] fifo[0:LAYERS-1][0:DEPTH-1];
 reg [PW-1:0] rd_ptr[0:LAYERS-1],wr_ptr[0:LAYERS-1];
 reg [CW-1:0] count[0:LAYERS-1];
 reg active=0;reg [LW-1:0] active_layer=0,last_layer=0;
 reg [14:0] active_row=0;
 integer l,q;
 initial for(l=0;l<LAYERS;l=l+1) begin
  q_rd[l]=0;q_wr[l]=0;q_count[l]=0;rd_ptr[l]=0;wr_ptr[l]=0;count[l]=0;
  for(q=0;q<CMDQ;q=q+1) cmdq[l][q]=0;
 end
 genvar g;
 generate for(g=0;g<LAYERS;g=g+1) begin: layers
  assign row_valid[g]=!reset && count[g]!=0;
  assign row_data[g*64+:64]=row_valid[g] ? fifo[g][rd_ptr[g]] : 64'd0;
 end endgenerate
 // Results outstanding per layer: queued commands + in-flight + FIFO entries.
 function [CW:0] outstanding(input integer i);
  outstanding=q_count[i]+count[i]+((active && active_layer==i) ? 1'b1 : 1'b0);
 endfunction
 // Round-robin choice among layers with a queued, unissued command.
 reg [LW-1:0] pick;reg found;integer k;reg [LW:0] idx;
 always @* begin
  found=0;pick=0;
  for(k=1;k<=LAYERS;k=k+1) begin
   idx=last_layer+k;if(idx>=LAYERS) idx=idx-LAYERS;
   if(!found && q_count[idx[LW-1:0]]!=0) begin found=1;pick=idx[LW-1:0];end
  end
 end
 assign mem_req=!reset && active;
 assign mem_row=active_row;
 always @(posedge clk_sys) begin
  fetch_accept<=0;
  if(reset) begin
   active<=0;active_layer<=0;last_layer<=0;active_row<=0;
   for(l=0;l<LAYERS;l=l+1) begin
    q_rd[l]<=0;q_wr[l]<=0;q_count[l]<=0;rd_ptr[l]<=0;wr_ptr[l]<=0;count[l]<=0;
   end
  end else begin
   for(l=0;l<LAYERS;l=l+1) begin : per_layer
    reg pop,acc,iss;
    pop=row_pop[l] && count[l]!=0;
    // Accept only when the result is guaranteed a FIFO slot and the queue has
    // room, and never in the cycle after an accept: the requester withdraws
    // (or replaces) its held command only when it sees fetch_accept.
    acc=fetch_req[l] && !fetch_accept[l] && q_count[l]<CMDQ && outstanding(l)<DEPTH;
    // Issue the head of this layer's queue when the memory side is free.
    iss=!active && found && pick==l;
    if(acc) begin
     cmdq[l][q_wr[l]]<=fetch_row[l*15+:15];
     q_wr[l]<=(q_wr[l]==CMDQ-1) ? {QW{1'b0}} : q_wr[l]+1'b1;
     fetch_accept[l]<=1;
    end
    if(iss) q_rd[l]<=(q_rd[l]==CMDQ-1) ? {QW{1'b0}} : q_rd[l]+1'b1;
    q_count[l]<=q_count[l]+(acc ? 1'b1 : 1'b0)-(iss ? 1'b1 : 1'b0);
    if(pop) rd_ptr[l]<=(rd_ptr[l]==DEPTH-1) ? {PW{1'b0}} : rd_ptr[l]+1'b1;
    // FIFO count: push on the in-flight response, pop on row_pop.
    count[l]<=count[l]+((active && mem_ack && active_layer==l) ? 1'b1 : 1'b0)-(pop ? 1'b1 : 1'b0);
   end
   if(active) begin
    if(mem_ack) begin
     fifo[active_layer][wr_ptr[active_layer]]<=mem_data;
     wr_ptr[active_layer]<=(wr_ptr[active_layer]==DEPTH-1) ? {PW{1'b0}} : wr_ptr[active_layer]+1'b1;
     active<=0;last_layer<=active_layer;
    end
   end else if(found) begin
    active<=1;active_layer<=pick;active_row<=cmdq[pick][q_rd[pick]];
   end
  end
 end
endmodule
