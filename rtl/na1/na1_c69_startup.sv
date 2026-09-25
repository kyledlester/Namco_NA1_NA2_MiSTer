// M16 production C69 startup sequencer: the minimum hardware-visible result of
// the executed C69 BIOS before it releases the 68000, as a bounded
// compatibility model. It is NOT an M37702/C69 emulator, executes no firmware
// and is not a claim about physical C69 timing.
//
// [MAME-CONFIRMED] (docs/FA_HARDWARE_SPEC.md, "C69 BIOS") machine reset holds
// the 68000; the BIOS stores the immediate vector words so that 68000-visible
// $000000-$000007 read 0000 0400 00C0 0000 (SSP $00000400, PC $00C00000), then
// writes $0C to port 4 and the P4 bit-3 rising edge releases the 68000, which
// fetches its vectors from ordinary shared/work RAM (no low-ROM overlay).
// [FA-TRACE] BIOS RAM-test writes ($FFFF then $0000) precede the release.
// [IMPLEMENTATION] This module: (1) zero-fills the whole 512 KiB work/shared
// RAM (the precondition every accepted genuine-F/A run used; the physical
// extent of the BIOS RAM test is [UNKNOWN]); (2) writes the four vector words;
// (3) pulses `release` for one clock, exactly once per reset. All accesses use
// the arbiter's MCU master port with the established held-request/level-ACK
// contract (request held until ack, then withdrawn for >= 1 edge).
module na1_c69_startup(
 input wire clk_sys,reset,
 // Logical shared-RAM master (68000-visible words/lanes), MCU side of the arbiter
 output wire req,output wire write,output wire [17:0] word_addr,
 output wire [15:0] wdata,output wire [1:0] byte_en,
 input wire ack,
 output reg cpu_release=0,  // one-clock P4 bit-3 equivalent
 output wire active,        // sequencer owns the MCU port
 output wire done
);
 localparam CLEAR=0,CLEAR_GAP=1,VECTOR=2,VECTOR_GAP=3,RELEASE=4,DONE=5;
 reg [2:0] state=CLEAR;
 reg [17:0] addr=0;
 // 68000-visible vector words at word addresses 0..3 (BIOS immediates).
 function [15:0] vector_word(input [1:0] i);
  case(i) 2'd0: vector_word=16'h0000; 2'd1: vector_word=16'h0400;
          2'd2: vector_word=16'h00c0; default: vector_word=16'h0000; endcase
 endfunction
 assign active=state!=DONE;
 assign done=state==DONE;
 assign req=!reset && (state==CLEAR || state==VECTOR);
 assign write=1'b1;
 assign byte_en=2'b11;
 assign word_addr=addr;
 assign wdata=state==VECTOR ? vector_word(addr[1:0]) : 16'd0;
 always @(posedge clk_sys) begin
  cpu_release<=0;
  if(reset) begin state<=CLEAR;addr<=0;end
  else case(state)
   CLEAR: if(ack) state<=CLEAR_GAP;
   CLEAR_GAP: begin
    if(addr==18'h3ffff) begin addr<=0;state<=VECTOR;end
    else begin addr<=addr+1'b1;state<=CLEAR;end
   end
   VECTOR: if(ack) state<=VECTOR_GAP;
   VECTOR_GAP: begin
    if(addr==18'd3) begin addr<=0;state<=RELEASE;end
    else begin addr<=addr+1'b1;state<=VECTOR;end
   end
   RELEASE: begin cpu_release<=1;state<=DONE;end
   DONE: ;
   default: state<=DONE;
  endcase
 end
endmodule
