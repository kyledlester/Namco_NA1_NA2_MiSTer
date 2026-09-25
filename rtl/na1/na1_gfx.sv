// M8 CPU-visible translation only. Two independent authoritative backends.
// Hold req and its tuple until ack; withdraw for >=1 edge to rearm.
// Backends must cancel uncompleted transactions on reset/req withdrawal,
// commit each held request once, and retain completed writes across reset.
module na1_gfx(
 input wire clk_sys,reset,req,write,input wire [23:0] addr,
 input wire [15:0] wdata,selector,input wire [1:0] byte_en,
 output wire ack,output wire [15:0] rdata,
 output wire character_req,character_write,
 output wire [16:0] character_word_addr,
 output wire [15:0] character_wdata,output wire [1:0] character_byte_en,
 input wire character_ack,input wire [15:0] character_rdata,
 output wire shape_req,shape_write,output wire [13:0] shape_word_addr,
 output wire [15:0] shape_wdata,output wire [1:0] shape_byte_en,
 input wire shape_ack,input wire [15:0] shape_rdata
);
 localparam IDLE=0,WAIT_BACKEND=1,RESPONSE=2;
 reg [1:0] state=IDLE;
 reg held_shape=0,held_write=0;
 reg [16:0] held_word_addr=0;
 reg [15:0] held_wdata=0,response_data=0;
 reg [1:0] held_byte_en=0;
 wire selected=req && addr>=24'hf40000 && addr<=24'hf7ffff;
 wire [23:0] offset=addr-24'hf40000;
 wire backend_active=!reset && selected && state==WAIT_BACKEND;
 assign character_req=backend_active && !held_shape;
 assign shape_req=backend_active && held_shape;
 assign character_write=held_write;
 assign shape_write=held_write;
 assign character_word_addr=held_word_addr;
 assign shape_word_addr=held_word_addr[13:0];
 assign character_wdata=held_wdata;
 assign shape_wdata=held_wdata;
 assign character_byte_en=held_byte_en;
 assign shape_byte_en=held_byte_en;
 assign ack=!reset && selected && state==RESPONSE;
 assign rdata=ack && !held_write ? response_data : 16'd0;
 always @(posedge clk_sys) begin
  if(reset) begin
   state<=IDLE;held_shape<=0;held_write<=0;held_word_addr<=0;
   held_wdata<=0;held_byte_en<=0;response_data<=0;
  end else if(!selected) begin
   state<=IDLE;response_data<=0;
  end else case(state)
   IDLE: begin
    held_write<=write;held_word_addr<=offset[17:1];
    held_wdata<=wdata;held_byte_en<=byte_en;response_data<=0;
    held_shape<=selector==16'h0003;
    // Exact full-word comparison; the upper shape aperture never aliases.
    if(selector==16'h0002 || (selector==16'h0003 && offset<24'h008000))
     state<=WAIT_BACKEND;
    else state<=RESPONSE; // MAME's stored-window zero read / ignored write.
   end
   WAIT_BACKEND: if(held_shape ? shape_ack : character_ack) begin
    response_data<=held_write ? 16'd0 : (held_shape ? shape_rdata : character_rdata);
    state<=RESPONSE;
   end
   RESPONSE: ; // Held completion; no backend request and no repeat operation.
   default: state<=IDLE;
  endcase
 end
endmodule
