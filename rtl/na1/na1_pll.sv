// FPGA implementation clock, not an original NA-1 oscillator model.
//
// clk_sys = 100.226 MHz = 2 x the 50.113 MHz NA-1 master [MAME-CONFIRMED].
// It is also CLK_VIDEO and (inverted) SDRAM_CLK. Chosen so the video pixel
// enable is an exact integer division (clk_sys / 14 = 7.159 MHz, the MiSTer
// CE_PIXEL contract) while every other emulated clock keeps its exact average
// rate through na1_clock_enables / na1_audio_tick. See docs/VIDEO_CE_FIX.md.
//
// 100.226 / 50 is not reachable with integer M/N/C counters, hence
// fractional_vco_multiplier("true"); the achieved frequency is in the
// fitter's PLL Usage Summary. NA1.sv's SYS_HZ must equal this frequency
// (scripts/test-video-ce.ps1 checks that the two agree).
//
// Fallback (docs/VIDEO_CE_FIX.md, Option A): "100.000000 MHz" here and
// SYS_HZ = 100_000_000 in NA1.sv; nothing else changes.
//
// Hierarchy (na1_pll:clocks|altera_pll:pll) is matched by sys/sys_top.sdc's
// *|clocks|pll|*|divclk clock group and NA1.sdc's SDRAM_CLK generated clock:
// keep the instance names.
module na1_pll(input wire refclk, input wire rst,
               output wire clk_sys, output wire locked);
    wire [0:0] clocks;
    altera_pll #(
        .fractional_vco_multiplier("true"),
        .reference_clock_frequency("50.0 MHz"),
        .number_of_clocks(1), .operation_mode("direct"),
        .output_clock_frequency0("100.226000 MHz"),
        .phase_shift0("0 ps"), .duty_cycle0(50),
        .pll_type("General"), .pll_subtype("General")
    ) pll (
        .refclk(refclk), .rst(rst), .outclk(clocks), .locked(locked),
        .fbclk(1'b0), .fboutclk()
    );
    assign clk_sys = clocks[0];
endmodule
