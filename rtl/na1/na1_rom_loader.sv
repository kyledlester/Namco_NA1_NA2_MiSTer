// Logical loader boundary, deliberately independent of MRA/ioctl indices.
// Already assembled big-endian 16-bit words; no physical EPROM lane mapping.
// Stable valid/data until ready. Backend accepts writes on valid && ready.
// Does not define SDRAM placement, fill data, download arbitration or reset.
module na1_rom_loader(
    input wire valid, input wire image, input wire [21:0] word_addr,
    input wire [15:0] data,
    output wire ready, output wire rejected,
    output wire storage_valid, output wire storage_image,
    output wire [21:0] storage_word_addr, output wire [15:0] storage_data,
    input wire storage_ready
);
    wire in_range = image || word_addr[21:20] == 2'b00;
    assign storage_valid = valid && in_range;
    assign storage_image = image;
    assign storage_word_addr = word_addr;
    assign storage_data = data;
    assign rejected = valid && !in_range;
    assign ready = in_range ? storage_ready : 1'b1;
endmodule
