// M20A audio sample cadence [IMPLEMENTATION]: one-clock tick at an exact
// average of RATE Hz from the CLK Hz system clock (fractional accumulator, no
// PLL). Default 44,100 Hz = MAME's C219 clock; the physical NA-1 rate is
// [UNKNOWN]. 100 MHz / 44.1 kHz = 2267.57 clocks per sample.
module na1_audio_tick #(parameter CLK=100000000,parameter RATE=44100)(
 input wire clk_sys,reset,output reg tick=0
);
 localparam W=$clog2(CLK)+1;
 localparam [W-1:0] R=RATE,C=CLK;
 reg [W-1:0] acc=0;
 wire [W-1:0] next=acc+R;
 always @(posedge clk_sys) begin
  tick<=0;
  if(reset) acc<=0;
  else if(next>=C) begin acc<=next-C;tick<=1; end
  else acc<=next;
 end
endmodule
