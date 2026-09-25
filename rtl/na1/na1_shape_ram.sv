// M15D shape RAM backend for na1_gfx selector 3: 32 KiB local storage with
// the M8 backend contract (hold req until ack; withdraw for >=1 edge to
// rearm; reset/withdrawal cancels transport, completed writes remain).
// Shape RAM never moves to external SDRAM.
module na1_shape_ram(
 input wire clk_sys,reset,
 input wire req,write,input wire [13:0] word_addr,
 input wire [15:0] wdata,input wire [1:0] byte_en,
 output wire ack,output wire [15:0] rdata,
 // Renderer-facing read port: registered one-cycle read, no arbitration.
 input wire render_enable,input wire [13:0] render_word_addr,
 output wire [15:0] render_rdata
);
 localparam IDLE=0,ACCESS=1,RESPONSE=2;
 reg [1:0] state=IDLE;
 reg held_write=0;
 reg [13:0] held_word_addr=0;
 reg [15:0] held_wdata=0;
 reg [1:0] held_byte_en=0;
 wire selected=req && !reset;
 wire storage_enable=selected && state==ACCESS;
 wire [15:0] storage_rdata;
 assign ack=selected && state==RESPONSE;
 assign rdata=ack && !held_write ? storage_rdata : 16'd0;
 na1_shape_storage storage(.clk_sys(clk_sys),
  .a_enable(storage_enable),.a_write(held_write),.a_word_addr(held_word_addr),
  .a_wdata(held_wdata),.a_byte_en(held_byte_en),.a_rdata(storage_rdata),
  .b_enable(render_enable),.b_word_addr(render_word_addr),.b_rdata(render_rdata));
 always @(posedge clk_sys) begin
  if(reset) begin
   state<=IDLE;held_write<=0;held_word_addr<=0;held_wdata<=0;held_byte_en<=0;
  end else case(state)
   IDLE: if(selected) begin
    held_write<=write;held_word_addr<=word_addr;
    held_wdata<=wdata;held_byte_en<=byte_en;state<=ACCESS;
   end
   ACCESS: if(selected) state<=RESPONSE;else state<=IDLE;
   RESPONSE: if(!selected) state<=IDLE;
   default: state<=IDLE;
  endcase
 end
endmodule
