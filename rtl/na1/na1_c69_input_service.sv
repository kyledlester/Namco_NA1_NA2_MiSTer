// M18 production C69 input-service compatibility model: what the executed C69
// firmware leaves in the shared-RAM input block once per service period, as a
// bounded model behind the replaceable MCU boundary. It is NOT an M37702/C69
// emulator, models no P6/P7 port multiplexing and executes no firmware.
//
// Evidence (docs/M18_IMPLEMENTATION.md): MAME 0.289 executing the real C69
// firmware with F/A, Lua memory/port taps and input injection, plus ablation.
// [MAME-CONFIRMED] Once per ~16.7 ms the firmware rewrites, in 68000 view:
//   $FC0.hi <- $80 (update-in-progress flag) ... $FC0.hi <- $00 at the end
//   $FD2 <- 0000; $FD0/$FCE/$FCC/$FCA <- FFFF (unconnected analog/encoder)
//   $FC8/$FC6/$FC4/$FC2 <- {level, edge} for P4/P3/P2/P1 (active-high level =
//       ~raw; edge = level & ~previous level; P3 is not multiplexed -> 0000)
//   $FC0.lo <- processed DSW byte (b1 test, b5 service-mode switch, b6
//       service-1 level, b7 one-period pulse after debounced service-1 release)
//   $FDC/$FDE/$FE0/$FE2 <- 0000; byte $FBF <- FF; $F86 <- 000D; $F88 <- 2000
//   then $FFE <- {P1 raw, P2 raw}; $FFC <- {P4 raw, DSW raw} (raw active-low)
//   The processed words lag the raw words by one period (they are built from
//   the previous period's sample). Coin lanes: 2-sample debounce on both
//   edges; the 8-bit counters $FD4={coin1,coin2} / $FD6={coin3,coin4} increment
//   on the debounced release; $FD8 pulses 0100 (coin1) / 0001 (coin2) for one
//   period. F/A consumes $FFE (controls) and $FD4 (credits); the rest is
//   reproduced as observed. Meaning of $F86/$F88, $FDC-$FE2, $FBF and the
//   $FC0.lo bits 2-4 is [UNKNOWN]; counter wrap and coin-3/4 pulses were not
//   observed (none are generated). DSW bit 0 (freeze) -> $FC0 bit 0 is
//   [INFERRED] from the test-bit behaviour, not observed.
// [IMPLEMENTATION] The firmware runs free on its own timer (~60 Hz, drifting
//   against the raster); this model services once per `tick` (the video frame
//   event), which F/A cannot distinguish because it copies the block once per
//   frame. Counters/pulses are written in the period of the debounced release.
//   All writes use the arbiter's MCU master port with the held-request /
//   level-ACK contract (request held until ack, withdrawn for >= 1 edge).
module na1_c69_input_service(
 input wire clk_sys,reset,
 input wire enable,             // service permitted (startup sequencer done)
 input wire tick,               // one clock per service period (frame)
 input wire [7:0] p1_raw,p2_raw,p4_raw,dsw_raw,   // active-low, as the C69 reads P7
 // Logical shared-RAM master (68000-visible words/lanes), MCU side of the arbiter
 output wire req,output wire write,output wire [17:0] word_addr,
 output wire [15:0] wdata,output wire [1:0] byte_en,
 input wire ack,
 output wire active,            // a service pass is in progress
 output reg [15:0] periods=0    // observation: completed service passes
);
 // Sample history: s0 = this period's raw sample, s1/s2 = previous two.
 reg [7:0] p1_s0=8'hff,p1_s1=8'hff,p1_s2=8'hff;
 reg [7:0] p2_s0=8'hff,p2_s1=8'hff,p2_s2=8'hff;
 reg [7:0] p4_s0=8'hff,p4_s1=8'hff,p4_s2=8'hff;
 reg [7:0] dsw_s0=8'hff,dsw_s1=8'hff;
 // Debounced lanes: coin1..4 = dsw bits 5,4,3,2; service-1 = dsw bit 7.
 reg [4:0] db_pressed=0,db_cnt=0;
 reg [7:0] coin_count[0:3];
 reg [3:0] coin_event=0;        // debounced release this period (coin1..4)
 reg svc_event=0;               // debounced service-1 release (shown next period)
 reg fd8_written=0;             // $FD8 holds a nonzero pulse from last period
 integer k;
 initial for(k=0;k<4;k=k+1) coin_count[k]=0;

 function [7:0] level(input [7:0] raw); level=~raw; endfunction
 wire [7:0] p1_level=level(p1_s1),p2_level=level(p2_s1),p4_level=level(p4_s1);
 wire [7:0] p1_edge=p1_level & ~level(p1_s2);
 wire [7:0] p2_edge=p2_level & ~level(p2_s2);
 wire [7:0] p4_edge=p4_level & ~level(p4_s2);
 wire [7:0] dsw_proc={svc_event,~dsw_s1[7],~dsw_s1[6],3'b000,~dsw_s1[1],~dsw_s1[0]};
 wire coin_pulse=coin_event[0] | coin_event[1];
 wire [15:0] fd8_word={7'd0,coin_event[0],7'd0,coin_event[1]};

 // Fixed write program, one transaction per step (68000 word address = byte/2).
 localparam STEPS=25;
 reg [4:0] step=0;
 reg busy=0,gap=0;
 reg [17:0] op_addr;reg [15:0] op_data;reg [1:0] op_be;reg op_skip;
 always @* begin
  op_addr=0;op_data=0;op_be=2'b11;op_skip=0;
  case(step)
   5'd0:  begin op_addr=18'h7e0;op_data=16'h8000;op_be=2'b10;end   // $FC0.hi <- 80
   5'd1:  begin op_addr=18'h7e9;op_data=16'h0000;end               // $FD2
   5'd2:  begin op_addr=18'h7e8;op_data=16'hffff;end               // $FD0
   5'd3:  begin op_addr=18'h7e7;op_data=16'hffff;end               // $FCE
   5'd4:  begin op_addr=18'h7e6;op_data=16'hffff;end               // $FCC
   5'd5:  begin op_addr=18'h7e5;op_data=16'hffff;end               // $FCA
   5'd6:  begin op_addr=18'h7e4;op_data={p4_level,p4_edge};end     // $FC8 P4
   5'd7:  begin op_addr=18'h7e3;op_data=16'h0000;end               // $FC6 P3
   5'd8:  begin op_addr=18'h7e2;op_data={p2_level,p2_edge};end     // $FC4 P2
   5'd9:  begin op_addr=18'h7e1;op_data={p1_level,p1_edge};end     // $FC2 P1
   5'd10: begin op_addr=18'h7e0;op_data={8'h00,dsw_proc};op_be=2'b01;end // $FC0.lo
   5'd11: begin op_addr=18'h7ee;op_data=16'h0000;end               // $FDC
   5'd12: begin op_addr=18'h7ef;op_data=16'h0000;end               // $FDE
   5'd13: begin op_addr=18'h7f0;op_data=16'h0000;end               // $FE0
   5'd14: begin op_addr=18'h7f1;op_data=16'h0000;end               // $FE2
   5'd15: begin op_addr=18'h7df;op_data=16'h00ff;op_be=2'b01;end   // byte $FBF <- FF
   5'd16: begin op_addr=18'h7e0;op_data=16'h0000;op_be=2'b10;end   // $FC0.hi <- 00
   5'd17: begin op_addr=18'h7c3;op_data=16'h000d;end               // $F86
   5'd18: begin op_addr=18'h7c4;op_data=16'h2000;end               // $F88
   5'd19: begin op_addr=18'h7ff;op_data={p1_s0,p2_s0};end          // $FFE raw P1/P2
   5'd20: begin op_addr=18'h7fe;op_data={p4_s0,dsw_s0};end         // $FFC raw P4/DSW
   5'd21: begin op_addr=18'h7ea;op_data={coin_count[0],coin_count[1]};op_skip=!(coin_event[0]|coin_event[1]);end // $FD4
   5'd22: begin op_addr=18'h7eb;op_data={coin_count[2],coin_count[3]};op_skip=!(coin_event[2]|coin_event[3]);end // $FD6
   5'd23: begin op_addr=18'h7ec;op_data=fd8_word;op_skip=!coin_pulse;end                 // $FD8 pulse
   5'd24: begin op_addr=18'h7ec;op_data=16'h0000;op_skip=coin_pulse || !fd8_written;end  // $FD8 clear
   default: op_skip=1;
  endcase
 end
 assign active=busy;
 assign req=!reset && busy && !gap && !op_skip;
 assign write=1'b1;
 assign word_addr=op_addr;
 assign wdata=op_data;
 assign byte_en=op_be;

 // Debounced lanes 0..3 = coin1..4 (dsw bits 5,4,3,2), lane 4 = service-1 (bit 7).
 wire [4:0] lane_pressed={~dsw_raw[7],~dsw_raw[2],~dsw_raw[3],~dsw_raw[4],~dsw_raw[5]};
 // A lane changes state after two consecutive samples of the new level; a
 // press->release change of the debounced state is the countable event.
 wire [4:0] lane_change=(lane_pressed^db_pressed) & db_cnt;
 wire [4:0] lane_release=lane_change & ~lane_pressed;

 always @(posedge clk_sys) begin
  if(reset) begin
   busy<=0;gap<=0;step<=0;periods<=0;
   p1_s0<=8'hff;p1_s1<=8'hff;p1_s2<=8'hff;p2_s0<=8'hff;p2_s1<=8'hff;p2_s2<=8'hff;
   p4_s0<=8'hff;p4_s1<=8'hff;p4_s2<=8'hff;dsw_s0<=8'hff;dsw_s1<=8'hff;
   db_pressed<=0;db_cnt<=0;coin_event<=0;svc_event<=0;fd8_written<=0;
   for(k=0;k<4;k=k+1) coin_count[k]<=0;
  end else if(!busy) begin
   if(tick && enable) begin
    // New period: sample, shift history, debounce, then run the write program.
    p1_s0<=p1_raw;p1_s1<=p1_s0;p1_s2<=p1_s1;
    p2_s0<=p2_raw;p2_s1<=p2_s0;p2_s2<=p2_s1;
    p4_s0<=p4_raw;p4_s1<=p4_s0;p4_s2<=p4_s1;
    dsw_s0<=dsw_raw;dsw_s1<=dsw_s0;
    db_pressed<=db_pressed ^ lane_change;
    db_cnt<=(lane_pressed^db_pressed) & ~db_cnt;
    coin_event<=lane_release[3:0];
    svc_event<=lane_release[4];
    for(k=0;k<4;k=k+1) if(lane_release[k]) coin_count[k]<=coin_count[k]+8'd1;
    busy<=1;step<=0;gap<=0;
   end
  end else begin
   if(gap || op_skip) begin
    gap<=0;
    if(step==STEPS-1) begin
     busy<=0;step<=0;periods<=periods+1'b1;
     fd8_written<=coin_pulse;
    end else step<=step+1'b1;
   end else if(ack) gap<=1;   // withdraw the request for one edge before the next
  end
 end
endmodule
