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
    output wire ce_master, output wire ce_68k, output wire ce_mcu,
    output wire ce_68k_phi2
);
    reg [26:0] phase;
    reg [1:0] divider;
    wire [27:0] next_phase = {1'b0, phase} + MASTER_HZ;
    wire [27:0] wrapped_phase = next_phase - SYS_HZ;
    assign ce_master = !reset && next_phase >= SYS_HZ;
    assign ce_68k = ce_master && divider == 2'd3;
    assign ce_mcu = ce_68k;
    // Complementary half-cycle enable for FX68K, two master ticks after phi1.
    assign ce_68k_phi2 = ce_master && divider == 2'd1;
    always @(posedge clk_sys) begin
        if (reset) begin
            phase <= 0;
            divider <= 0;
        end else begin
            if (ce_master) begin
                phase <= wrapped_phase[26:0];
                divider <= divider + 2'd1;
            end else phase <= next_phase[26:0];
        end
    end
endmodule
