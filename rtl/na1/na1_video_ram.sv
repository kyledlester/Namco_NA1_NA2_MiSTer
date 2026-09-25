// M7 ordinary RAM wrapper. Each instance has independent storage and responder.
// Capture -> synchronous access -> held response; req low for >=1 edge rearms.
module na1_video_ram #(parameter [23:0] BASE=24'hffe000,
                       parameter WORDS=2048,ADDR_WIDTH=11)(
 input wire clk_sys,reset,req,write,input wire [23:0] addr,
 input wire [15:0] wdata,input wire [1:0] byte_en,
 output wire ack,output wire [15:0] rdata,
 // M15B renderer read port: registered one-cycle read, no arbitration.
 input wire render_enable,input wire [ADDR_WIDTH-1:0] render_word_addr,
 output wire [15:0] render_rdata
);
 localparam [31:0] LAST_WIDE={8'd0,BASE}+WORDS*2-1;
 localparam [23:0] LAST=LAST_WIDE[23:0];
 localparam IDLE=0,ACCESS=1,RESPONSE=2;
 reg [1:0] state=IDLE;
 reg held_write=0;
 reg [ADDR_WIDTH-1:0] held_word_addr=0;
 reg [15:0] held_wdata=0;
 reg [1:0] held_byte_en=0;
 wire selected=req && addr>=BASE && addr<=LAST;
 wire [23:0] offset=addr-BASE;
 wire storage_enable=!reset && selected && state==ACCESS;
 wire [15:0] storage_rdata;
 assign ack=!reset && selected && state==RESPONSE;
 assign rdata=ack && !held_write ? storage_rdata : 16'd0;
 na1_video_storage #(.WORDS(WORDS),.ADDR_WIDTH(ADDR_WIDTH)) storage(
  .clk_sys(clk_sys),.enable(storage_enable),.write(held_write),
  .word_addr(held_word_addr),.wdata(held_wdata),.byte_en(held_byte_en),
  .rdata(storage_rdata),.render_enable(render_enable),
  .render_word_addr(render_word_addr),.render_rdata(render_rdata));
 always @(posedge clk_sys) begin
  if(reset) begin
   state<=IDLE;held_write<=0;held_word_addr<=0;held_wdata<=0;held_byte_en<=0;
  end else case(state)
   IDLE: if(selected) begin
    held_write<=write;held_word_addr<=offset[ADDR_WIDTH:1];
    held_wdata<=wdata;held_byte_en<=byte_en;state<=ACCESS;
   end
   ACCESS: if(selected) state<=RESPONSE;else state<=IDLE;
   RESPONSE: if(!selected) state<=IDLE;
   default: state<=IDLE;
  endcase
 end
endmodule
