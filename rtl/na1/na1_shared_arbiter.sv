// Logical CPU-word interface on both masters. No physical C69 endian adapter.
// [IMPLEMENTATION] Non-preemptive round robin; latched requests and responses.
// A request is held until ack, then withdrawn for >=1 edge. No burst semantics.
module na1_shared_arbiter(
 input wire clk_sys,reset,
 input wire cpu_req,cpu_write, input wire [17:0] cpu_word_addr,
 input wire [15:0] cpu_wdata,input wire [1:0] cpu_byte_en,
 output wire cpu_ack,output wire [15:0] cpu_rdata,
 input wire mcu_req,mcu_write,input wire [17:0] mcu_word_addr,
 input wire [15:0] mcu_wdata,input wire [1:0] mcu_byte_en,
 output wire mcu_ack,output wire [15:0] mcu_rdata,
 output wire work_req,output reg work_write,output reg [17:0] work_word_addr,
 output reg [15:0] work_wdata,output reg [1:0] work_byte_en,
 input wire work_ack,input wire [15:0] work_rdata
);
 localparam IDLE=0,ACTIVE=1,RESPONSE=2,GAP=3;
 reg [1:0] state=IDLE;
 reg owner_mcu=0,last_mcu=1;
 reg [15:0] response_data=0;
 wire owner_req=owner_mcu ? mcu_req : cpu_req;
 wire grant_mcu=mcu_req && (!cpu_req || !last_mcu);
 assign work_req=!reset && state==ACTIVE && owner_req;
 assign cpu_ack=!reset && state==RESPONSE && !owner_mcu && cpu_req;
 assign mcu_ack=!reset && state==RESPONSE && owner_mcu && mcu_req;
 assign cpu_rdata=cpu_ack ? response_data : 16'd0;
 assign mcu_rdata=mcu_ack ? response_data : 16'd0;
 always @(posedge clk_sys) begin
  if(reset) begin
   state<=IDLE;owner_mcu<=0;last_mcu<=1;response_data<=0;
   work_write<=0;work_word_addr<=0;work_wdata<=0;work_byte_en<=0;
  end else case(state)
   IDLE: if(cpu_req || mcu_req) begin
    owner_mcu<=grant_mcu;last_mcu<=grant_mcu;
    work_write<=grant_mcu ? mcu_write : cpu_write;
    work_word_addr<=grant_mcu ? mcu_word_addr : cpu_word_addr;
    work_wdata<=grant_mcu ? mcu_wdata : cpu_wdata;
    work_byte_en<=grant_mcu ? mcu_byte_en : cpu_byte_en;
    state<=ACTIVE;
   end
   ACTIVE: if(!owner_req) state<=GAP;
           else if(work_ack) begin response_data<=work_rdata;state<=RESPONSE;end
   RESPONSE: if(!owner_req) state<=GAP;
   GAP: state<=IDLE; // backend sees a low request edge before another grant
   default: state<=IDLE;
  endcase
 end
endmodule
