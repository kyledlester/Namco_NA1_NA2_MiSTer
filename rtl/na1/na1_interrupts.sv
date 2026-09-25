// Independent HOLD_LINE-compatible state. Mask gates new events, not pending.
// System reset clears pending. Timing continues while main CPU is held reset;
// IPL is suppressed during that hold. These are explicit FPGA reset decisions.
//
// M32 VBLANK POSITION. VBLANK_AT_LINE224=1 is MAME's placement (IRQ4 on the
// line-224 event), kept for the M11 unit benches. Production uses 0: IRQ4 on
// `vblank`, the end of the visible window (after logical line 255). MAME can
// place it at 224 only because it draws each frame after the fact; every game
// does its per-frame sprite/scroll/VRAM/register work in this handler, and a
// line-by-line renderer (like the real board) would show lines 225-255 half-
// updated. [INFERRED] from the games themselves: Emeraldia's posirq split
// (IRQ4 sets the upper configuration, IRQ3 at line 240 the lower one) only
// renders MAME's image if IRQ4 precedes the visible window. See
// docs/M31_VIDEO_CORRECTNESS.md section 9.
module na1_interrupts #(parameter VBLANK_AT_LINE224=1)(
 input wire clk_sys,reset,cpu_reset,tick, input wire [7:0] line,
 input wire vblank,
 input wire enabled, input wire [15:0] mask, input wire [7:0] position,
 input wire iack_service, input wire [2:0] iack_level,
 output reg pending3=0,pending4=0, output wire [2:0] level,
 output wire event3,event4
);
 assign event3=tick && enabled && !mask[2] && line==position;
 assign event4=enabled && !mask[3] && (VBLANK_AT_LINE224 ? (tick && line==8'd224) : vblank);
 assign level=reset || cpu_reset ? 3'd0 : pending4 ? 3'd4 : pending3 ? 3'd3 : 3'd0;
 always @(posedge clk_sys) begin
  if(reset) begin pending3<=0;pending4<=0;end
  else begin
   // Set dominates simultaneous IACK, preventing loss of a new line event.
   pending3<=event3 || (pending3 && !(iack_service && iack_level==3));
   pending4<=event4 || (pending4 && !(iack_service && iack_level==4));
  end
 end
endmodule
