// Emulated-clock enables from clk_sys: exact average MASTER_HZ (50.113 MHz, the
// NA-1 master) and /4 CPU/MCU ticks, for any SYS_HZ >= MASTER_HZ.
// With the production clk_sys = 2 x MASTER_HZ the accumulator fires on exactly
// every second clock (ce_68k every 8th); with any other SYS_HZ (e.g. the 100 MHz
// fallback) tick spacing is quantized to clk_sys but the average stays exact.
// FX68K phases share the master divider.
module na1_clock_enables #(
    parameter integer SYS_HZ    = 100_226_000,
    parameter integer MASTER_HZ = 50_113_000
)(
    input wire clk_sys, input wire reset,
    output reg ce_master = 1'b0, output reg ce_68k = 1'b0, output wire ce_mcu,
    output reg ce_68k_phi2 = 1'b0
);
    reg [26:0] phase;
    reg [1:0] divider;
    wire [27:0] next_phase = {1'b0, phase} + MASTER_HZ;
    wire [27:0] wrapped_phase = next_phase - SYS_HZ;
    wire tick = !reset && next_phase >= SYS_HZ;
    // Setup-timing fix: the enables are registered copies of the phase compare
    // (they used to be combinational, putting the 28-bit add/compare in series
    // with the FX68K and M37702 datapaths). Every enable moves one clk_sys
    // later together, so their spacing and relative order are unchanged.
    always @(posedge clk_sys) begin
        ce_master <= tick;
        ce_68k <= tick && divider == 2'd3;
        // Complementary half-cycle enable for FX68K, two master ticks after phi1.
        ce_68k_phi2 <= tick && divider == 2'd1;
    end
    assign ce_mcu = ce_68k;
    always @(posedge clk_sys) begin
        if (reset) begin
            phase <= 0;
            divider <= 0;
        end else begin
            if (tick) begin
                phase <= wrapped_phase[26:0];
                divider <= divider + 2'd1;
            end else phase <= next_phase[26:0];
        end
    end
endmodule
