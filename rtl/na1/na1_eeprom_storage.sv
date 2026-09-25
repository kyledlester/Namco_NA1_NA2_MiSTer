// M6 logical 28C16 storage. A future persistence backend may replace this
// module without changing the CPU transaction wrapper. No array reset; the
// array powers up ERASED ($FF), like the real 28C16 (M29.1).
// M22: restored verbatim to this single-write-port structure after the
// M22.0 two-write-port version failed RAM inference entirely (14,170
// ALMs / 16,408 registers, 0 memory bits -- see docs/M22_IMPLEMENTATION.md
// "M22 fit failure"). Standard MiSTer NVRAM persistence is now provided
// by na1_eeprom.sv arbitrating THIS one proven single port between CPU
// and ioctl NVRAM traffic, instead of this module growing a second port.
module na1_eeprom_storage(
    input wire clk_sys,enable,write,
    input wire [10:0] cell_addr,input wire [7:0] wdata,
    output reg [7:0] rdata
);
    (* ramstyle = "M10K" *) reg [7:0] cells[0:2047];
    // M29.1 `[HW-CONFIRMED defect, fixed]`. This erased-state seed used to be
    // wrapped in translate_off/`ifndef SYNTHESIS`, so it applied in simulation
    // ONLY. On the DE10-Nano the inferred M10K powers up all-ZEROES, so every
    // game's first-ever boot saw a 2 KiB block of $00 where a real board has an
    // erased 28C16 -- which reads $FF. Verified against MAME this session: a
    // blank NA-1 EEPROM reads FF for all 2048 bytes.
    //
    // That is a genuine hardware mismatch, not a simulation convenience, and it
    // is exactly the state MAME's driver warns about for several NA-1 titles:
    // "when their EEPROM area is uninitialized, the game software automatically
    // writes these values there, but then hangs" (cgangpzl, cgangpzlj, exvania,
    // exvaniaj, ...). Quartus honours an initial block for inferred M10K and
    // emits the power-up contents with the bitstream, so the seed is now
    // synthesized. Ordinary CPU/core reset still does NOT erase the EEPROM.
    integer i;
    initial begin
        rdata=0;
        for(i=0;i<2048;i=i+1) cells[i]=8'hff;
    end
    always @(posedge clk_sys) if(enable) begin
        rdata<=cells[cell_addr];
        if(write) cells[cell_addr]<=wdata;
    end
endmodule
