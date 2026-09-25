// Two held-request clients, one word backend. No storage or physical addressing.
// Registered responses belong to the latched owner. A low-request gap rearms
// the backend even when the other client is already waiting. Reset/withdrawal
// cancels an unfinished request; the backend must cancel on req withdrawal.
module na1_word_arbiter #(parameter WIDTH=1)(
 input wire clk_sys,reset,req0,req1,
 input wire [WIDTH-1:0] tuple0,tuple1,
 output wire ack0,ack1,output wire [15:0] data0,data1,
 output wire backend_req,output wire [WIDTH-1:0] backend_tuple,
 input wire backend_ack,input wire [15:0] backend_data
);
 localparam IDLE=0,WAIT_WORD=1,RESPONSE=2,GAP=3;
 reg [1:0] state=IDLE;
 reg owner=0,last_owner=1;
 reg [WIDTH-1:0] held=0;
 reg [15:0] response=0;
 wire live=owner ? req1 : req0;
 wire choose=req1 && (!req0 || !last_owner);
 assign backend_req=!reset && state==WAIT_WORD && live;
 assign backend_tuple=held;
 assign ack0=!reset && state==RESPONSE && !owner && req0;
 assign ack1=!reset && state==RESPONSE && owner && req1;
 assign data0=ack0 ? response : 16'd0;
 assign data1=ack1 ? response : 16'd0;
 always @(posedge clk_sys) begin
  if(reset) begin state<=IDLE;owner<=0;last_owner<=1;held<=0;response<=0;end
  else case(state)
   IDLE: if(req0 || req1) begin
    owner<=choose;held<=choose ? tuple1 : tuple0;state<=WAIT_WORD;
   end
   WAIT_WORD: if(!live) state<=GAP;
              else if(backend_ack) begin response<=backend_data;state<=RESPONSE;end
   RESPONSE: if(!live) begin last_owner<=owner;state<=GAP;end
   GAP: state<=IDLE;
   default: state<=IDLE;
  endcase
 end
endmodule
