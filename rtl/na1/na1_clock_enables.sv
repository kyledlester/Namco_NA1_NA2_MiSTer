// 100 MHz clk_sys: exact average 50.113 MHz master and /4 CPU/MCU ticks.
// Tick spacing is quantized to clk_sys. FX68K phases share the master divider.
module na1_clock_enables(
    input wire clk_sys, input wire reset,
    output wire ce_master, output wire ce_68k, output wire ce_mcu,
    output wire ce_68k_phi2
);
    reg [26:0] phase;
    reg [1:0] divider;
    wire [27:0] next_phase = {1'b0, phase} + 28'd50113000;
    wire [27:0] wrapped_phase = next_phase - 28'd100000000;
    assign ce_master = !reset && next_phase >= 28'd100000000;
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
