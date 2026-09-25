// M5: 4096 logical 68000 words. No reset clears the memory array.
// Synchronous read, lane writes; read-during-write data is unused by the wrapper.
// M16: coded in the byte-enable RAM pattern Quartus infers as M10K (packed
// byte lanes written per lane). The former bit-slice writes
// (`words[a][15:8] <= ...`) synthesized to registers + 4096:1 multiplexers
// once the store became live (hundreds of thousands of ALUTs), which no
// earlier build saw because the stores were pruned with the CPU in reset.
// Read-during-write data is unused by the wrappers (no_rw_check).
module na1_additional_storage(
    input wire clk_sys,enable,write,
    input wire [11:0] word_addr,
    input wire [15:0] wdata,input wire [1:0] byte_en,
    output reg [15:0] rdata
);
    (* ramstyle = "M10K, no_rw_check" *) reg [1:0][7:0] words[0:4095];
// synthesis translate_off
`ifndef SYNTHESIS
    // [IMPLEMENTATION] Deterministic simulation fixture, NOT physical NA-1
    // power-up contents. Quartus does not synthesize this initialization loop.
    integer i;
    initial begin
        rdata=0;
        for(i=0;i<4096;i=i+1) words[i]=0;
    end
`endif
// synthesis translate_on
    always @(posedge clk_sys) if(enable) begin
        if(write) begin
            if(byte_en[1]) words[word_addr][1]<=wdata[15:8];
            if(byte_en[0]) words[word_addr][0]<=wdata[7:0];
        end
        rdata<=words[word_addr];
    end
endmodule
