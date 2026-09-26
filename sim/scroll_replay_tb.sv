// Equivalence test: incremental scroll replay (INC_REPLAY=1) vs the original
// full replay (INC_REPLAY=0). Both renderers see identical stimuli; at the end
// of every line's replay (SCROLL_LAST) their scroll/ROZ state must match.
// MODE 0: scroll writes and ROZ register changes only while both are idle ->
//         any mismatch is a bug.
// MODE 1: writes also land mid-replay -> mismatches allowed only on the line
//         being rendered when the write landed; the next line must agree.
//
// Run (Icarus Verilog), from the repository root:
//   iverilog -g2012 -Preplay_tb.MODE=0 -o replay0 sim/scroll_replay_tb.sv \
//       rtl/na1/na1_renderer.sv rtl/na1/na1_char_prefetch.sv && vvp -n replay0
// and the same with MODE=1. Expected: "errors 0" in both modes.
`timescale 1ns/1ps
module replay_tb;
 parameter integer MODE=0, FRAMES=6, SEED=1, LINE_CLKS=4000;
 reg clk=0; always #5 clk=~clk;
 reg reset=1;
 reg line_event=0; reg [7:0] event_line=0;
 reg pixel_ce=0; reg [8:0] beam_x=0; reg [7:0] beam_y=0;
 reg [15:0] scroll_mem[0:2047];
 reg [2047:0] vreg=0;
 reg wr_ev=0; reg [7:0] wr_line=0;
 integer seed=SEED;

 // per-instance ports
 wire sa_en,sb_en; wire [10:0] sa_addr,sb_addr; reg [15:0] sa_q=0,sb_q=0;
 always @(posedge clk) begin if(sa_en) sa_q<=scroll_mem[sa_addr]; if(sb_en) sb_q<=scroll_mem[sb_addr]; end
 wire a_busy,b_busy;
 wire [15:0] a_ovr,b_ovr;

 `define INST(N,INC,EN,ADDR,Q,BUSY,OVR) \
 na1_renderer #(.DEPTH(4),.INC_REPLAY(INC),.VREG_QUIET(16),.VREG_MAXWAIT(64)) N( \
  .clk_sys(clk),.reset(reset),.pixel_ce(pixel_ce),.beam_x(beam_x),.beam_y(beam_y), \
  .beam_visible(1'b0),.line_event(line_event),.event_line(event_line),.flip_native(1'b0), \
  .video_enable(),.video_word_addr(),.video_rdata(16'd0), \
  .scroll_enable(EN),.scroll_word_addr(ADDR),.scroll_rdata(Q), \
  .palette_enable(),.palette_word_addr(),.palette_rdata(16'd0), \
  .shape_enable(),.shape_word_addr(),.shape_rdata(16'd0), \
  .sprite_enable(),.sprite_word_addr(),.sprite_rdata(16'd0), \
  .vreg(vreg),.scroll_wr_event(wr_ev),.scroll_wr_line(wr_line), \
  .prefetch_req(),.prefetch_row(),.prefetch_ack(1'b0),.prefetch_data(64'd0), \
  .out_valid(),.out_visible(),.out_x(),.out_y(),.out_index(),.out_rgb555(),.out_rgb(),.out_shadow(), \
  .busy(BUSY),.overrun_count(OVR),.lines_rendered());
 `INST(ra,1,sa_en,sa_addr,sa_q,a_busy,a_ovr)
 `INST(rb,0,sb_en,sb_addr,sb_q,b_busy,b_ovr)

 // snapshot at SCROLL_LAST (state 3) of each instance
 function [255:0] snap_a; input dummy;
  snap_a={ra.scrollx[0],ra.scrollx[1],ra.scrollx[2],ra.scrollx[3],
          7'd0,ra.scrolly[0],7'd0,ra.scrolly[1],7'd0,ra.scrolly[2],7'd0,ra.scrolly[3],
          ra.z_linex,ra.z_liney,ra.pix_mode,ra.pix_ydata[0][11:0],ra.pix_ydata[3][15:0]};
 endfunction
 function [255:0] snap_b; input dummy;
  snap_b={rb.scrollx[0],rb.scrollx[1],rb.scrollx[2],rb.scrollx[3],
          7'd0,rb.scrolly[0],7'd0,rb.scrolly[1],7'd0,rb.scrolly[2],7'd0,rb.scrolly[3],
          rb.z_linex,rb.z_liney,rb.pix_mode,rb.pix_ydata[0][11:0],rb.pix_ydata[3][15:0]};
 endfunction
 // SCROLL_LAST applies the final Y word; the state is complete one clock later (FILL, fill_x==0)
 reg [255:0] sa_snap[0:255], sb_snap[0:255];
 reg [255:0] a_done=0, b_done=0;   // bit per target
 always @(posedge clk) begin
  if(ra.state==5 && ra.fill_x==0) begin sa_snap[ra.target]<=snap_a(0); a_done[ra.target]<=1; end
  if(rb.state==5 && rb.fill_x==0) begin sb_snap[rb.target]<=snap_b(0); b_done[rb.target]<=1; end
 end

 integer frame,line,k,c,errors=0,compared=0,inc_used=0,allowed=0;
 reg [255:0] tainted=0;  // MODE 1: lines where a write landed mid-render
 task rand_vreg_roz; begin
  vreg[16*7'h60+:16]=$random(seed); vreg[16*7'h61+:16]=$random(seed);
  vreg[16*7'h62+:16]=$random(seed); vreg[16*7'h63+:16]=$random(seed);
  vreg[16*7'h64+:16]=$random(seed); vreg[16*7'h65+:16]=$random(seed);
  vreg[16*7'h40+:16]=16'h48+($random(seed)&255);
 end endtask
 task scroll_write(input [10:0] a, input [15:0] d); begin
  @(negedge clk); scroll_mem[a]=d; wr_ev=1; wr_line=a[7:0]; @(negedge clk); wr_ev=0;
 end endtask
 function [15:0] rand_entry; input integer dummy; integer r; begin
  r=$random(seed)&15;
  if(r<6) rand_entry=0; else if(r<9) rand_entry=16'h4000|($random(seed)&16'h1ff);
  else if(r<10) rand_entry=16'hc001; else rand_entry=$random(seed)&16'h01ff;
 end endfunction

 initial begin
  for(k=0;k<2048;k=k+1) scroll_mem[k]=rand_entry(0);
  vreg[16*7'h41+:16]=16'h48+303; vreg[16*7'h42+:16]=32; vreg[16*7'h43+:16]=256; vreg[16*7'h47+:16]=1;
  rand_vreg_roz;
  repeat(10) @(posedge clk); reset=0;
  for(frame=0;frame<FRAMES;frame=frame+1) begin
   a_done=0;b_done=0;tainted=0;
   if(frame%2==1) rand_vreg_roz;          // ROZ context change between frames
   for(line=0;line<256;line=line+1) begin
    @(negedge clk); line_event=1; event_line=line; @(negedge clk); line_event=0;
    // mid-line stimuli
    for(c=0;c<LINE_CLKS;c=c+1) begin
     @(negedge clk);
     if(MODE==1 && ($random(seed)%700)==0) begin
      k=$random(seed)&2047; scroll_mem[k]=rand_entry(0); wr_ev=1; wr_line=k[7:0];
      if(a_busy) tainted[line+1]=1;
     end else wr_ev=0;
     if(MODE==1 && ($random(seed)%5000)==0) begin rand_vreg_roz; if(a_busy) tainted[line+1]=1; end
    end
    wr_ev=0;
    // idle-time stimuli (both renderers are idle here)
    if(a_busy||b_busy) begin $display("ERROR: renderer still busy at line end (line %0d)",line); errors=errors+1; end
    if(MODE==0) begin
     if(($random(seed)%4)==0) for(k=0;k<1+($random(seed)&3);k=k+1) scroll_write($random(seed)&2047,rand_entry(0));
     if(($random(seed)%40)==0) rand_vreg_roz;
    end
   end
   for(k=32;k<256;k=k+1) if(a_done[k] && b_done[k]) begin
    compared=compared+1;
    if(sa_snap[k]!==sb_snap[k]) begin
     if(MODE==1 && tainted[k]) allowed=allowed+1;
     else begin errors=errors+1; if(errors<10) $display("MISMATCH frame %0d target %0d\n inc =%h\n full=%h",frame,k,sa_snap[k],sb_snap[k]); end
    end
   end
  end
  $display("MODE %0d: compared %0d lines, errors %0d, allowed(tainted) %0d, overruns a=%0d b=%0d, incremental %0d",MODE,compared,errors,allowed,a_ovr,b_ovr,inc_used);
  $finish;
 end
 // count incremental decisions
 always @(posedge clk) if(ra.state==11 && ra.inc_valid && !ra.scroll_dirty && ra.zctx==ra.zctx_prev && ra.target>ra.inc_line) inc_used=inc_used+1;

endmodule
