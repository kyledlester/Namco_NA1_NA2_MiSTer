// M1 bus foundation, independent of a CPU implementation. All ports synchronous
// to clk_sys. Hold requests stable until ack; drop req for >=1 clock between
// transactions. ack is a level, not a pulse. Not a physical 68000 timing model.
module na1_memory(
    input wire clk_sys, input wire reset,
    input wire cpu_req, input wire cpu_write, input wire [23:0] cpu_addr,
    input wire [15:0] cpu_wdata, input wire [1:0] cpu_byte_en,
    output reg [15:0] cpu_rdata, output reg cpu_ack,
    output wire [12:0] region,
    // Logical shared/work RAM backend: 512 KiB, word-relative addressing.
    // No storage or master arbitration here. Same held req/ack contract as CPU.
    output wire work_req, output wire work_write,
    output wire [17:0] work_word_addr,
    output wire [15:0] work_wdata, output wire [1:0] work_byte_en,
    input wire [15:0] work_rdata, input wire work_ack,
    // Future peripheral targets: full byte address/control, one-hot requests.
    // Bits 0/2/3 are always zero on this port (separate memory backends).
    output wire [12:0] peripheral_req,
    output wire peripheral_write, output wire [23:0] peripheral_addr,
    output wire [15:0] peripheral_wdata, output wire [1:0] peripheral_byte_en,
    input wire [12:0] peripheral_ack,
    input wire [207:0] peripheral_rdata,
    // Read-only ROM backend. image=0 program (2 MiB), image=1 mask (8 MiB).
    // word_addr is relative to that logical image, never a physical SDRAM addr.
    output wire rom_req, output wire rom_image,
    output wire [21:0] rom_word_addr,
    input wire [15:0] rom_rdata, input wire rom_ack
);
    wire active = cpu_req && !reset;
    na1_decode decode(.addr(cpu_addr), .region(region));
    assign work_req = active && region[0];
    assign work_write = cpu_write;
    assign work_word_addr = cpu_addr[18:1];
    assign work_wdata = cpu_wdata;
    assign work_byte_en = cpu_byte_en;
    assign peripheral_req = {13{active}} & region & 13'h1ff2;
    assign peripheral_write = cpu_write;
    assign peripheral_addr = cpu_addr;
    assign peripheral_wdata = cpu_wdata;
    assign peripheral_byte_en = cpu_byte_en;
    assign rom_req = active && !cpu_write && (region[2] || region[3]);
    assign rom_image = region[2];
    wire [23:0] mask_offset = cpu_addr - 24'h400000;
    assign rom_word_addr = region[2] ? mask_offset[22:1] : {2'b00,cpu_addr[20:1]};
    integer i;
    always @* begin
        i = 0;
        cpu_rdata = 16'd0;
        cpu_ack = 1'b0;
        if (active) begin
            if (region[0]) begin
                cpu_ack = work_ack;
                if (work_ack && !cpu_write) cpu_rdata = work_rdata;
            end else if (region[2] || region[3]) begin
                // Benign completion for ignored CPU ROM writes. No backend write.
                cpu_ack = cpu_write || rom_ack;
                if (!cpu_write && rom_ack) cpu_rdata = rom_rdata;
            end else if (region == 13'd0) begin
                // Scaffold policy, not a claim about physical NA-1 open bus.
                cpu_ack = 1'b1;
            end else begin
                for (i=0; i<13; i=i+1) begin
                    if (peripheral_req[i]) begin
                        cpu_ack = peripheral_ack[i];
                        if (peripheral_ack[i] && !cpu_write)
                            cpu_rdata = peripheral_rdata[i*16 +: 16];
                    end
                end
            end
        end
    end
endmodule
