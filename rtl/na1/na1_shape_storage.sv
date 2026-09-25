// M15D local shape storage: 16,384 x16 byte-enabled simple dual-port M10K.
// Port A is the CPU/blitter read/write port; port B is a read-only port
// reserved for the future renderer (M16). No array reset.
// M16: coded in the byte-enable RAM pattern Quartus infers as M10K (packed
// byte lanes written per lane). The former bit-slice writes
// (`words[a][15:8] <= ...`) synthesized to registers + 4096:1 multiplexers
// once the store became live (hundreds of thousands of ALUTs), which no
// earlier build saw because the stores were pruned with the CPU in reset.
// Read-during-write data is unused by the wrappers (no_rw_check).
module na1_shape_storage(
 input wire clk_sys,
 input wire a_enable,a_write,input wire [13:0] a_word_addr,
 input wire [15:0] a_wdata,input wire [1:0] a_byte_en,output reg [15:0] a_rdata,
 input wire b_enable,input wire [13:0] b_word_addr,output reg [15:0] b_rdata
);
 (* ramstyle = "M10K, no_rw_check" *) reg [1:0][7:0] words[0:16383];
// synthesis translate_off
`ifndef SYNTHESIS
 integer i;
 initial begin a_rdata=0;b_rdata=0;for(i=0;i<16384;i=i+1) words[i]=0;end
`endif
// synthesis translate_on
 always @(posedge clk_sys) if(a_enable) begin
  if(a_write) begin
   if(a_byte_en[1]) words[a_word_addr][1]<=a_wdata[15:8];
   if(a_byte_en[0]) words[a_word_addr][0]<=a_wdata[7:0];
  end
  a_rdata<=words[a_word_addr];
 end
 always @(posedge clk_sys) if(b_enable) b_rdata<=words[b_word_addr];
endmodule
