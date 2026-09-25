// Replaceable MAME compatibility timebase: 256 lines/frame at 60 Hz.
// Not measured NA-1 video timing; no pixels, sync or CPU-dependent scheduling.
module na1_scanline_events #(parameter SYS_HZ=100000000)(
 input wire clk_sys,reset, output reg tick=0, output reg [7:0] line=0
);
 reg [31:0] fraction=0;
 wire [32:0] next_fraction={1'b0,fraction}+33'd15360;
 wire [32:0] wrapped_fraction=next_fraction-SYS_HZ;
 always @(posedge clk_sys) begin
  tick<=0;
  if(reset) begin fraction<=0;line<=0;end
  else if(next_fraction>=SYS_HZ) begin
   fraction<=wrapped_fraction[31:0];line<=line+8'd1;tick<=1;
  end else fraction<=next_fraction[31:0];
 end
endmodule
