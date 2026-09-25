// Pure 24-bit byte-address decoding. Bit order is part of the M1 interface:
// 0 work, 1 mailbox, 2 mask ROM, 3 program ROM, 4 EEPROM, 5 KEYCUS,
// 6 registers, 7 palette, 8 character, 9 video, 10 additional,
// 11 scroll, 12 sprite. No access strobes or peripheral behavior here.
module na1_decode(input wire [23:0] addr, output wire [12:0] region);
    assign region[0] = addr <= 24'h07ffff;
    assign region[1] = addr >= 24'h3f8000 && addr <= 24'h3fffff;
    assign region[2] = addr >= 24'h400000 && addr <= 24'hbfffff;
    assign region[3] = addr >= 24'hc00000 && addr <= 24'hdfffff;
    assign region[4] = addr >= 24'he00000 && addr <= 24'he00fff;
    assign region[5] = addr >= 24'he40000 && addr <= 24'he4000f;
    assign region[6] = addr >= 24'hefff00 && addr <= 24'hefffff;
    assign region[7] = addr >= 24'hf00000 && addr <= 24'hf01fff;
    assign region[8] = addr >= 24'hf40000 && addr <= 24'hf7ffff;
    assign region[9] = addr >= 24'hff0000 && addr <= 24'hffbfff;
    assign region[10] = addr >= 24'hffc000 && addr <= 24'hffdfff;
    assign region[11] = addr >= 24'hffe000 && addr <= 24'hffefff;
    assign region[12] = addr >= 24'hfff000;
endmodule
