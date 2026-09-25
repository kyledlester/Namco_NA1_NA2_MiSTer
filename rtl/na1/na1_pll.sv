// FPGA implementation clock, not an original NA-1 oscillator model.
module na1_pll(input wire refclk, input wire rst,
               output wire clk_sys, output wire locked);
    wire [0:0] clocks;
    altera_pll #(
        .reference_clock_frequency("50.0 MHz"),
        .number_of_clocks(1), .operation_mode("direct"),
        .output_clock_frequency0("100.0 MHz"),
        .phase_shift0("0 ps"), .duty_cycle0(50),
        .pll_type("General"), .pll_subtype("General")
    ) pll (
        .refclk(refclk), .rst(rst), .outclk(clocks), .locked(locked),
        .fbclk(1'b0), .fboutclk()
    );
    assign clk_sys = clocks[0];
endmodule
