// M15E/M23 video transport: bridges the beam and the renderer pixel stream to
// the MiSTer arcade_video interface (ce_pix + RGB + HBlank/VBlank/HSync/VSync).
//
// Sync, blanking and the pixel enable come straight from the free-running
// beam (na1_video_timing), delayed by the renderer's fixed three-clock
// pipeline so they line up with the renderer's {out_valid,out_visible,
// out_rgb} sample for the same pixel, then registered once more: every
// framework signal is four clocks behind the beam, all derived from the
// same pixel, so RGB and sync cannot drift apart. arcade_video latches on
// the rising edge of ce_pix, i.e. on the clock where these registers carry
// that pixel.
//
// M23: the raster is emitted continuously -- through system reset, ROM
// download and CPU/renderer inactivity -- because a CRT must stay locked
// while MiSTer shows its loading bar. Only the colour depends on the
// renderer: when it has no valid visible sample (reset, download, blanking)
// the output is black. There is no reset input by design.
module na1_video_transport(
 input wire clk_sys,
 // live beam sample (na1_video_timing)
 input wire pixel_ce,beam_visible,beam_hblank,beam_vblank,beam_hsync,beam_vsync,
 // renderer pixel stream for the same beam pixel, three clocks later
 input wire in_valid,in_visible,
 input wire [23:0] in_rgb,
 // arcade_video-facing stream: one ce_pix pulse per pixel, other signals
 // stable between pulses and sampled by the framework on the ce_pix edge
 output reg ce_pix=0,
 output reg [23:0] rgb=0,
 output reg hblank=1,vblank=1,hsync=0,vsync=0,
 output wire de,
 output reg visible=0
);
 reg [2:0] d_ce=0,d_vis=0,d_hb=3'b111,d_vb=3'b111,d_hs=0,d_vs=0;
 assign de=!(hblank||vblank);

 always @(posedge clk_sys) begin
  d_ce<={d_ce[1:0],pixel_ce};
  d_vis<={d_vis[1:0],beam_visible};
  d_hb<={d_hb[1:0],beam_hblank};
  d_vb<={d_vb[1:0],beam_vblank};
  d_hs<={d_hs[1:0],beam_hsync};
  d_vs<={d_vs[1:0],beam_vsync};
  ce_pix<=d_ce[2];
  if(d_ce[2]) begin
   rgb<=(in_valid && in_visible && d_vis[2]) ? in_rgb : 24'd0;
   hblank<=d_hb[2];
   vblank<=d_vb[2];
   hsync<=d_hs[2];
   vsync<=d_vs[2];
   visible<=d_vis[2];
  end
 end
endmodule
