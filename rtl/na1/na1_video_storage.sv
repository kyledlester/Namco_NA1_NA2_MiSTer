// M7 byte-enabled synchronous on-chip storage, used by three distinct regions.
// There is no array reset. M15B adds a read-only renderer port B (simple
// dual-port inference); the CPU/blitter port A remains the only writer.
// M16: coded in the byte-enable RAM pattern Quartus infers as M10K (packed
// byte lanes written per lane). The former bit-slice writes
// (`words[a][15:8] <= ...`) synthesized to registers + 4096:1 multiplexers
// once the store became live (hundreds of thousands of ALUTs), which no
// earlier build saw because the stores were pruned with the CPU in reset.
// Read-during-write data is unused by the wrappers (no_rw_check).
module na1_video_storage #(parameter WORDS=2048,ADDR_WIDTH=11)(
 input wire clk_sys,enable,write,input wire [ADDR_WIDTH-1:0] word_addr,
 input wire [15:0] wdata,input wire [1:0] byte_en,output reg [15:0] rdata,
 input wire render_enable,input wire [ADDR_WIDTH-1:0] render_word_addr,
 output reg [15:0] render_rdata
);
 (* ramstyle = "M10K, no_rw_check" *) reg [1:0][7:0] words[0:WORDS-1];
// synthesis translate_off
`ifndef SYNTHESIS
 integer i;
 initial begin rdata=0;render_rdata=0;for(i=0;i<WORDS;i=i+1) words[i]=0;end
`endif
// synthesis translate_on
 always @(posedge clk_sys) if(enable) begin
  if(write) begin
   if(byte_en[1]) words[word_addr][1]<=wdata[15:8];
   if(byte_en[0]) words[word_addr][0]<=wdata[7:0];
  end
  rdata<=words[word_addr];
 end
 always @(posedge clk_sys) if(render_enable) render_rdata<=words[render_word_addr];
endmodule
