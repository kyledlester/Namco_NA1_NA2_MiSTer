derive_pll_clocks

# M15C.1: the controller launches address/command/write data on clk_sys's
# rising edge.  altddio_out drives SDRAM_CLK low on that edge and high on the
# falling edge, so the SDRAM sees an inverted copy of the 100 MHz core clock.
set na1_core_clock_pin [get_pins -compatibility_mode {*|clocks|pll|*|divclk}]
create_generated_clock -name SDRAM_CLK -source $na1_core_clock_pin \
    -divide_by 1 -invert [get_ports {SDRAM_CLK}]

# MiSTer MemTest SDRAM-module limits (commit 2264c374d15d1257645203b581bc7b57a8e3917d).
# These cover the standard module's clock-to-data/read-hold behavior and the
# address/control/write-data setup and hold requirements at the SDRAM pins.
set_input_delay -max -clock SDRAM_CLK 6.4 [get_ports {SDRAM_DQ[*]}]
set_input_delay -min -clock SDRAM_CLK 3.7 [get_ports {SDRAM_DQ[*]}]

# M16 read-capture relationship. SDRAM read data is launched from the forwarded
# inverted SDRAM_CLK (its rising edges sit on clk_sys falling edges). The
# vendored controller samples DQ into dq_reg on every clk_sys rising edge and
# consumes the sample taken 15 ns after the launching SDRAM_CLK edge
# (data_ready_delay1 indexing, CL=2), i.e. the second rising edge after it.
# Default TimeQuest analysis paired the launch with the unused rising edge only
# 5 ns later, which no path can meet (-7.637 ns on all 16 DQ bits). A setup
# multicycle of 2 models the capture edge actually consumed; the delay values
# above are unchanged. No hold exception: with -setup 2 alone TimeQuest checks
# the next burst word against this capture edge, which is the real hold hazard.
set_multicycle_path -setup 2 -from [get_clocks {SDRAM_CLK}] \
    -to [get_clocks {*|clocks|pll|*|divclk}]

set na1_sdram_outputs [get_ports {
    SDRAM_A[*] SDRAM_BA[*]
    SDRAM_nCS SDRAM_nWE SDRAM_nRAS SDRAM_nCAS
    SDRAM_DQMH SDRAM_DQML SDRAM_DQ[*]
}]
set_output_delay -max -clock SDRAM_CLK 1.6 $na1_sdram_outputs
set_output_delay -min -clock SDRAM_CLK -0.9 $na1_sdram_outputs

derive_clock_uncertainty
# Core reset crossings must be reviewed in TimeQuest once fitting is available.
# No broad false-path exception is added to hide synchronizer timing paths.

# The framework's HQ2x Blend stage only advances on its clk_en (the
# scandoubler's 4x pixel enable: 4 x 7.16 MHz, i.e. every 3-4 clk_sys cycles
# at 100 MHz, never on consecutive cycles), so register-to-register paths
# inside Blend have at least two clocks. Without this the HQ2x filter paths
# fail setup by ~2 ns at 100 MHz.
set_multicycle_path -setup 2 -from [get_registers {*|Hq2x:Hq2x|Blend:blender|*}] \
    -to [get_registers {*|Hq2x:Hq2x|Blend:blender|*}]
set_multicycle_path -hold 1 -from [get_registers {*|Hq2x:Hq2x|Blend:blender|*}] \
    -to [get_registers {*|Hq2x:Hq2x|Blend:blender|*}]
