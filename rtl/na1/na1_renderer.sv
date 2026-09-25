// M15B/M19 production F/A renderer: normal 8-bpp tile layers 0..3 and the
// M19 sprite subset, with MAME's executed NA-1 semantics (docs/M14_RESEARCH.md,
// docs/M19_IMPLEMENTATION.md), rendered one line ahead of the M15A
// MAME_COMPAT beam into a double line buffer.
//
// Per line L (rendered while the beam displays line L-1):
//  1. snapshot the video registers;
//  2. replay the per-layer scroll commands of lines 0..L from the current
//     scroll RAM (MAME re-evaluates the whole command list at every partial
//     update; evaluating at raster time from line 0 reproduces that for any
//     store state and needs no write snooping), eight reads per line;
//  3. fill x=0..303 with palette index ($EFFFBA[3:0] << 8), clear the
//     per-pixel layer-priority map, the sprite-claimed map and the shadow line.
//     CRTC display window: fill pixels outside the $EFFF80-$86 window (or
//     every pixel while no valid window is programmed) are marked blank and
//     output black. MAME fills its whole bitmap with the backdrop pen, which
//     shows as a coloured border (F/A maroon, Exvania light blue; windows
//     x 9..294 / 8..294). A CRTC drives no video outside its display area,
//     and every layer, sprite and pixel line is already clipped to the
//     window. Inside the window the backdrop still shows, also with
//     $EFFF8E = 0, as in MAME;
//  4. if $EFFF8E != 0 and the window is valid, draw layers in MAME order
//     (priority 0..7, and layer 3 down to 0 inside one priority; a later
//     layer overwrites and records its priority in the priority map): for
//     each 8-pixel tile row the walker reads the map word (video RAM port B),
//     the shape byte (shape RAM port B) and, unless the row is fully
//     transparent, issues one row command to na1_char_prefetch; the writer
//     consumes each 64-bit row exactly once and writes the visible,
//     window-clipped pixels;
//  5. M19 sprite pass (MAME draw_sprites/pdraw_tile): scan the 256 entries
//     of the bank selected by $EFFF22[0] in index order; for every entry
//     whose 1..8 tile rows cover line L, every visible 1..4 tile column is
//     fetched like a layer row (tile = code + 64*row + col, flip X/Y applied)
//     and written with the sprite rule: a masked-opaque pixel claims the pixel
//     if not yet claimed (even when it then loses), and is drawn only if
//     layer_priority <= sprite_priority (tie -> sprite). Shadow sprites
//     (shadow bit with colour $FF 4-bpp or $0F 8-bpp) claim and set the
//     shadow bit instead of a colour.
// The output side reads the line buffer on pixel_ce, looks the 12-bit index
// up in palette port B, expands RGB555 to RGB888 and darkens shadowed pixels
// by MAME's 0.6 shadow factor ((c*615)>>10 is exact for RGB555 expansions),
// three clocks behind the beam.
//
// M29 completes the MAME screen_update feature set, generically (no game
// identity anywhere -- every one of these is selected by NA-1 register state
// the software writes):
//  * 4-BPP NORMAL TILE LAYERS ($EFFFBC bits 0..3, and bit 4 for ROZ). The
//    pixel is the low nibble of the same character byte and the map word's
//    bits 14..12 select one of eight 16-entry sub-banks inside the layer's
//    $EFFFB0+2n palette bank. Transparency still comes from the shape mask.
//  * 4-BPP SPRITES (sprite word 2 bit 3). The palette base becomes the 8-bit
//    {colour[7:4], colour[11:8]} and the pixel is again the low nibble. Only
//    the special shadow colour ($FF 4-bpp / $0F 8-bpp) is a shadow.
//  * THE ALTERNATE "+$1000" PALETTE. A shadow-flagged sprite whose colour is
//    NOT the special pen is drawn through MAME's second palette
//    interpretation of the same RAM word (RRRGGGBB | RRRGGGBB averaged 1:2),
//    not through RGB555. The line buffer carries one extra bit for it.
//  * THE ROZ LAYER 4 ($EFFFC0..$EFFFCA, map page $FF8000, palette bank
//    $EFFFBA). Drawn per pixel with MAME's 16.16 incxx/incxy/incyx/incyy
//    transform and draw_roz_core's cliprect pre-advance, clipped to the
//    512x512 map (wraparound is off), first within its priority.
// M30 adds, equally generically:
//  * DIRECT-PIXEL LINES. A normal layer whose x-scroll word for the line is
//    exactly $C001 is not drawn from its tilemap on that line: MAME
//    draw_pixel_line (namcona1_v.cpp) takes 152 video-RAM words starting at
//    word ydata+25 (ydata = the layer's line-select word for the line) as 304
//    8-bit pens, high byte first, in palette bank 0, every pixel opaque and
//    window-clipped, and writes priority $FF across the whole line -- so no
//    sprite can appear over it unless a later layer redraws the pixel. Only
//    Numan Athletics is known to use it (bottom 40 lines, 4,740-10,496 visible
//    px per gameplay frame, docs/M30_IMPLEMENTATION.md section 6). MAME itself
//    calls the $C001 trigger a simplification; this reproduces MAME exactly.
// M33 GAME FLIP ($EFFF98, the operator FLIP setting; MAME does not implement
// it). With FLIP on the game itself rewrites every layer's line-select table
// to run backwards (vertical half, M27 accumulate rule) and every layer's
// scroll-X to 806 - normal, and leaves sprite RAM untouched [FA-TRACE,
// docs/M27_RESEARCH.md]. The owner's hardware reference is an exact 180-degree
// rotation of the unflipped screen [HW-CONFIRMED expected result, 2026-09-24],
// which fixes the hardware's half: each composed line is mirrored at readout
// (x -> 303-x, window mirrored to match), a layer's X origin becomes
// 410 - 4*layer - scroll (mod 512: the game's negated scroll plus the mirrored
// per-layer stagger), and sprites are evaluated on the mirrored line 287-y.
// Latched once per frame; combined with the M24 presentation flip by XOR.
// Not changed: the ROZ layer and direct-pixel lines (no flipped evidence).
//
// M31 REGISTER COMMIT: the per-line SNAP no longer reads the live video
// registers. It reads a shadow that follows them only after the registers the
// renderer uses have been unchanged for VREG_QUIET clocks (bounded: a shadow
// that has disagreed with the live values for VREG_MAXWAIT clocks is updated
// regardless). Games rewrite the register block in their IRQ handlers with
// longword stores that straddle register pairs, so for ~1-2 us a register can
// hold a transient half-written value ([MAME-CONFIRMED] Exvania's IRQ4 handler
// at line 225: $EFFF82 = 0000 then 016F, $EFFF86 = 0000 then 0100). MAME only
// samples the registers at its screen-update points, never mid-burst; a SNAP
// that caught the transient invalidated the window for one whole line and drew
// it as fill (the hardware-observed Exvania blue line). Settled register
// changes, including posirq raster effects, still apply at the next line.
module na1_renderer #(parameter DEPTH=4,parameter integer VREG_QUIET=1024,parameter integer VREG_MAXWAIT=6000)(
 input wire clk_sys,reset,
 // M15A beam contract
 input wire pixel_ce,input wire [8:0] beam_x,input wire [7:0] beam_y,
 input wire beam_visible,line_event,input wire [7:0] event_line,
 // M24 presentation-only 180-degree flip (MiSTer OSD feature, NOT F/A's own
 // service-menu FLIP, which stays unimplemented and unwired). Selects which
 // source line/pixel is fetched for a given display coordinate; the beam,
 // line/frame events, IRQ timing and the M23 transport raster are untouched.
 // Sampled once per frame (see flip_l) so a mid-frame OSD change cannot tear.
 input wire flip_native,
 // Authoritative stores, renderer read ports (registered one-cycle reads)
 output wire video_enable,output wire [14:0] video_word_addr,input wire [15:0] video_rdata,
 output wire scroll_enable,output wire [10:0] scroll_word_addr,input wire [15:0] scroll_rdata,
 output wire palette_enable,output wire [11:0] palette_word_addr,input wire [15:0] palette_rdata,
 output wire shape_enable,output wire [13:0] shape_word_addr,input wire [15:0] shape_rdata,
 output wire sprite_enable,output wire [10:0] sprite_word_addr,input wire [15:0] sprite_rdata,
 input wire [2047:0] vreg,
 // M15D character prefetch memory side (authoritative character SDRAM)
 output wire prefetch_req,output wire [14:0] prefetch_row,
 input wire prefetch_ack,input wire [63:0] prefetch_data,
 // Pixel stream: valid three clocks after the beam's pixel_ce
 output reg out_valid=0,output reg out_visible=0,
 output reg [8:0] out_x=0,output reg [7:0] out_y=0,
 output reg [11:0] out_index=0,output reg [14:0] out_rgb555=0,output reg [23:0] out_rgb=0,
 output reg out_shadow=0,
 // Diagnostics
 output reg busy=0,output reg [15:0] overrun_count=0,output reg [15:0] lines_rendered=0
);
 localparam SPR=3'd4;                  // prefetch slot used by the sprite pass
 localparam [3:0] PMAP_TOP=4'd8;       // MAME priority $FF: above every sprite
 // ---- register snapshot (indices are CPU byte offset / 2) ------------------
 reg [15:0] r80=0,r82=0,r84=0,r86=0,r8e=0,rba=0,r22=0,rbc=0,raa=0;
 // M31 register commit (see header): only the registers SNAP consumes.
 localparam integer VRW=15*16+4*3+4*4;
 wire [VRW-1:0] vr_live={vreg[16*7'h40+:16],vreg[16*7'h41+:16],vreg[16*7'h42+:16],vreg[16*7'h43+:16],
   vreg[16*7'h47+:16],vreg[16*7'h5d+:16],vreg[16*7'h11+:16],vreg[16*7'h5e+:16],vreg[16*7'h55+:16],
   vreg[16*7'h60+:16],vreg[16*7'h61+:16],vreg[16*7'h62+:16],vreg[16*7'h63+:16],vreg[16*7'h64+:16],vreg[16*7'h65+:16],
   vreg[16*7'h50+:3],vreg[16*7'h51+:3],vreg[16*7'h52+:3],vreg[16*7'h53+:3],
   vreg[16*7'h58+:4],vreg[16*7'h59+:4],vreg[16*7'h5a+:4],vreg[16*7'h5b+:4]};
 reg [VRW-1:0] vr_last=0,vr_shadow=0;
 reg [10:0] vr_quiet=0;reg [12:0] vr_wait=0;
 always @(posedge clk_sys) begin
  vr_last<=vr_live;
  if(vr_live!=vr_last) vr_quiet<=0;
  else if(vr_quiet!=VREG_QUIET[10:0]) vr_quiet<=vr_quiet+1'b1;
  // settled = unchanged for VREG_QUIET clocks AND not changing this cycle
  if((vr_quiet==VREG_QUIET[10:0] && vr_live==vr_last) || vr_wait==VREG_MAXWAIT[12:0]) begin vr_shadow<=vr_live;vr_wait<=0;end
  else if(vr_shadow!=vr_live) vr_wait<=vr_wait+1'b1;
  else vr_wait<=0;
 end
 // ROZ transform registers, snapshotted with the rest ($EFFFC0..$EFFFCA).
 reg [15:0] rc0=0,rc2=0,rc4=0,rc6=0,rc8=0,rca=0;
 reg [2:0] prio[0:3];reg [3:0] bank[0:3];
 reg [8:0] win_min_x=0,win_max_x=0;reg [7:0] win_min_y=0,win_max_y=0;reg win_valid=0;
 reg disp_valid=0;                     // CRTC window programmed and non-empty (MAME screen_enabled)
 wire [16:0] mx=r80-17'h48,xx=r82-17'h49;
 wire [8:0] c_min_x=(mx[16] ? 9'd0 : (mx>17'd303 ? 9'd303 : mx[8:0]));
 wire [8:0] c_max_x=(xx[16] ? 9'd0 : (xx>17'd303 ? 9'd303 : xx[8:0]));
 wire [7:0] c_min_y=(r84<16'd32 ? 8'd32 : (r84>16'd255 ? 8'd255 : r84[7:0]));
 wire [16:0] yy=r86-17'd1;
 wire [7:0] c_max_y=(yy[16] ? 8'd0 : (yy>17'd255 ? 8'd255 : yy[7:0]));

 // ---- line buffers: two lines of 320 x {bank[3:0],pixel[7:0]} + shadow bit --
 // Addressed as {half, x}: half 1 lives at 512..815, so the arrays span the
 // full 10-bit address space (M15E).
 // M29: 13 bits. [11:0] is the palette index as before; [12] selects MAME's
 // alternate "+$1000" palette interpretation for that pixel.
 // [13] = CRTC blank: a fill pixel outside the $EFFF80-$86 display window,
 // output as black (see "CRTC display window" above).
 (* ramstyle = "M10K" *) reg [13:0] linebuf[0:1023];
 (* ramstyle = "M10K" *) reg shadowbuf[0:1023];
 reg lb_we=0;reg [9:0] lb_waddr=0;reg [13:0] lb_wdata=0;
 reg sb_we=0;reg [9:0] sb_waddr=0;reg sb_wdata=0;
 reg [13:0] lb_rdata=0;reg sb_rdata=0;
 // Per-frame sample of flip_native. Latched at logical line 0, which is inside
 // vertical blanking and before both the first rendered line (event_line 31 ->
 // target 32) and the first displayed line (32), so a frame is never rendered
 // half-flipped and readout always agrees with what was rendered.
 reg flip_l=0;
 reg gflip=0;                          // M33: $EFFF98 game FLIP, latched per frame
 // M24 flipped presentation: read the line backwards inside the 304-pixel
 // visible image only. Outside it (beam_x 304..455 under the M23 transport
 // raster) the address is left as-is: those pixels are blanked by
 // na1_video_transport, so the data is never displayed either way.
 wire [8:0] rd_x=((flip_l ^ gflip) && beam_x<9'd304) ? (9'd303-beam_x) : beam_x;
 always @(posedge clk_sys) begin
  if(lb_we) linebuf[lb_waddr]<=lb_wdata;
  if(sb_we) shadowbuf[sb_waddr]<=sb_wdata;
  lb_rdata<=linebuf[{beam_y[0],rd_x}];
  sb_rdata<=shadowbuf[{beam_y[0],rd_x}];
 end
 // Per-line composition state for the line being rendered (not double
 // buffered: only the renderer uses it, and only inside one line).
 // M30: 4 bits so the direct-pixel line's MAME priority $FF (PMAP_TOP) can
 // outrank every sprite priority 0..7; every other writer zero-extends.
 reg [3:0] pmap[0:303];                // priority of the layer owning the pixel (fill = 0)
 reg [303:0] claimed=0;                // sprite already claimed the pixel

 // ---- output pipeline -------------------------------------------------------
 reg s1_valid=0,s1_visible=0,s2_valid=0,s2_visible=0,s2_shadow=0,s1_alt=0,s2_alt=0,s2_blank=0;
 reg [8:0] s1_x=0,s2_x=0;reg [7:0] s1_y=0,s2_y=0;reg [11:0] s2_index=0;
 assign palette_enable=s1_valid;
 assign palette_word_addr=lb_rdata[11:0];
 function [7:0] expand5(input [4:0] c); expand5={c,c[4:2]}; endfunction
 function [7:0] shade(input [7:0] c); reg [17:0] t; begin t=c*18'd615; shade=t[17:10]; end endfunction
 // MAME's alternate palette pens ($1000..$1FFF) reinterpret the SAME RAM word
 // as two RRRGGGBB bytes and average them 1:2, scaling to 0..255:
 //   r = ((w>>5 & 7) + 2*(w>>13 & 7)) * 255 / 21   (g likewise from bits 4..2)
 //   b = ((w    & 3) + 2*(w>>8  & 3)) * 255 /  9
 // Both are small exact tables rather than a divider.
 function [7:0] alt21(input [4:0] v); // v = a + 2b, 0..21 -> v*255/21
  begin case(v)
   5'd0:alt21=8'd0;    5'd1:alt21=8'd12;   5'd2:alt21=8'd24;   5'd3:alt21=8'd36;
   5'd4:alt21=8'd48;   5'd5:alt21=8'd60;   5'd6:alt21=8'd72;   5'd7:alt21=8'd85;
   5'd8:alt21=8'd97;   5'd9:alt21=8'd109;  5'd10:alt21=8'd121; 5'd11:alt21=8'd133;
   5'd12:alt21=8'd145; 5'd13:alt21=8'd157; 5'd14:alt21=8'd170; 5'd15:alt21=8'd182;
   5'd16:alt21=8'd194; 5'd17:alt21=8'd206; 5'd18:alt21=8'd218; 5'd19:alt21=8'd230;
   5'd20:alt21=8'd242; default:alt21=8'd255;
  endcase end
 endfunction
 function [7:0] alt9(input [3:0] v);  // v = a + 2b, 0..9 -> v*255/9
  begin case(v)
   4'd0:alt9=8'd0;   4'd1:alt9=8'd28;  4'd2:alt9=8'd56;  4'd3:alt9=8'd85;
   4'd4:alt9=8'd113; 4'd5:alt9=8'd141; 4'd6:alt9=8'd170; 4'd7:alt9=8'd198;
   4'd8:alt9=8'd226; default:alt9=8'd255;
  endcase end
 endfunction
 wire [4:0] a_rv={2'd0,palette_rdata[7:5]}+{1'd0,palette_rdata[15:13],1'b0};
 wire [4:0] a_gv={2'd0,palette_rdata[4:2]}+{1'd0,palette_rdata[12:10],1'b0};
 wire [3:0] a_bv={2'd0,palette_rdata[1:0]}+{1'd0,palette_rdata[9:8],1'b0};
 wire [7:0] n_r=expand5(palette_rdata[14:10]),n_g=expand5(palette_rdata[9:5]),n_b=expand5(palette_rdata[4:0]);
 wire [7:0] p_r=s2_alt ? alt21(a_rv) : n_r;
 wire [7:0] p_g=s2_alt ? alt21(a_gv) : n_g;
 wire [7:0] p_b=s2_alt ? alt9(a_bv)  : n_b;
 always @(posedge clk_sys) begin
  s1_valid<=pixel_ce && !reset;s1_visible<=beam_visible;s1_x<=beam_x;s1_y<=beam_y;
  s2_valid<=s1_valid;s2_visible<=s1_visible;s2_x<=s1_x;s2_y<=s1_y;
  s2_index<=lb_rdata[11:0];s2_alt<=lb_rdata[12];s2_shadow<=sb_rdata;s2_blank<=lb_rdata[13];
  out_valid<=s2_valid;out_visible<=s2_visible;out_x<=s2_x;out_y<=s2_y;out_index<=s2_index;out_shadow<=s2_shadow;
  out_rgb555<=palette_rdata[14:0];
  out_rgb<=s2_blank ? 24'd0 : s2_shadow ? {shade(p_r),shade(p_g),shade(p_b)} : {p_r,p_g,p_b};
 end

 // ---- character prefetch (layers 0..3 + sprite slot) ------------------------
 reg [4:0] fetch_req=0,row_pop=0;reg [14:0] fetch_row_word=0;
 wire [4:0] fetch_accept,row_valid;wire [319:0] row_data;
 na1_char_prefetch #(.LAYERS(5),.DEPTH(DEPTH),.CMDQ(2)) prefetch(.clk_sys(clk_sys),.reset(reset),
  .fetch_req(fetch_req),.fetch_row({5{fetch_row_word}}),.fetch_accept(fetch_accept),
  .row_valid(row_valid),.row_data(row_data),.row_pop(row_pop),
  .mem_req(prefetch_req),.mem_row(prefetch_row),.mem_ack(prefetch_ack),.mem_data(prefetch_data));

 // ---- line engine -----------------------------------------------------------
 localparam IDLE=0,SNAP=1,SCROLL=2,SCROLL_LAST=3,ROZ=4,FILL=5,
            SELECT=6,LAYER=7,SPRITES=8,DONE=9,PIXLINE=10;
 reg [3:0] state=IDLE;
 reg [7:0] target=0,scroll_line=0;reg buf_sel=0;
 reg [15:0] scrollx[0:3];reg [8:0] scrolly[0:3];
 reg [2:0] sl=0;                       // producer slot being rendered: layer 0..3 or SPR
 reg [2:0] sidx=0;                     // scroll read sequence: {layer,isY}
 reg d_valid=0,d_isy=0;reg [1:0] d_layer=0;reg [7:0] d_line=0; // read data phase
 reg [15:0] xword=0;
 // M30 direct-pixel lines: the target line's x/line-select words per layer,
 // captured on the last replayed scroll line, and the line walker state.
 reg [3:0] pix_mode=0;reg [15:0] pix_ydata[0:3];
 localparam P_RD=0,P_HI=1,P_LO=2;
 reg [1:0] pstate=P_RD;reg [8:0] px_x=0;reg [14:0] px_addr=0;reg [7:0] px_lo=0;
 wire px_last=(px_x==9'd302);
 wire px_hi_in=px_x>=win_min_x && px_x<=win_max_x;
 wire [8:0] px_x1=px_x+9'd1;
 wire px_lo_in=px_x1>=win_min_x && px_x1<=win_max_x;
 reg [8:0] fill_x=0;
 reg [2:0] sel_p=0;reg [2:0] sel_l=0;  // MAME draw order iteration (4 = ROZ)
 // layer walker
 localparam W_IDLE=0,W_MAP=1,W_MAP_WAIT=2,W_SHAPE_WAIT=3,W_FETCH=4,W_DONE=5;
 reg [2:0] wstate=W_IDLE;
 reg [5:0] tile_x=0,tile_y=0,tile_i=0,tile_n=0;reg [2:0] py=0;
 reg [9:0] base_x=0;                   // signed: min_x - px0
 reg [11:0] tile_code=0;reg tile_opaque=0;reg [2:0] tile_sub=0;
 // sprite scan/walker
 localparam S_IDLE=0,S_SCAN=1,S_W1=2,S_W2=3,S_W3=4,S_COL=5,S_SHAPE=6,S_SHAPE_WAIT=7,S_FETCH=8,S_NEXT=9,S_DONE=10;
 reg [3:0] sstate=S_IDLE;
 reg [8:0] scan_n=0;                   // next entry to issue (0..255, 256 = past the end)
 reg eval_valid=0;reg [7:0] scan_eval_n=0; // a word-0 read was issued last cycle for scan_eval_n
 reg [7:0] sp_n=0;                     // entry being processed
 reg [15:0] sp_w0=0,sp_w1=0,sp_w2=0,sp_w3=0;
 reg [2:0] sp_k=0;                     // screen row block within the sprite
 reg [2:0] sp_py=0;                    // pixel row within the tile (pre-flip)
 reg [1:0] sp_s=0;                     // screen column slot
 reg [11:0] sp_code=0;reg [9:0] sp_sx=0;reg [2:0] sp_pyf=0;
 wire sp_flipy=sp_w0[15],sp_flipx=sp_w2[15],sp_opaque=sp_w1[15],sp_bpp4=sp_w2[3];
 wire [2:0] sp_h1=sp_w0[14:12];        // height-1
 wire [1:0] sp_w1w=sp_w2[13:12];       // width-1
 wire [2:0] sp_pri=sp_w2[2:0];
 // MAME palbase: 4-bpp = {colour[7:4], colour[11:8]} (8 bits, x16 entries),
 // 8-bpp = colour[7:4] (x256). "Special" (the shadow pen) is $FF / $0F.
 wire sp_special=sp_bpp4 ? (sp_w2[11:4]==8'hff) : (sp_w2[7:4]==4'hf);
 wire sp_shadow=sp_w2[14] && sp_special;
 // M29: a shadow-flagged sprite whose colour is NOT the special pen draws
 // through the alternate +$1000 palette instead of being a shadow.
 wire sp_altpal=sp_w2[14] && !sp_special;
 wire [7:0] sp_ibase=sp_bpp4 ? {sp_w2[7:4],sp_w2[11:8]} : {4'd0,sp_w2[7:4]};
 wire [2:0] sp_row=sp_flipy ? (sp_h1-sp_k) : sp_k;             // tile row inside the sprite
 wire [1:0] sp_col=sp_flipx ? (sp_w1w-sp_s) : sp_s;             // tile column inside the sprite
 wire [11:0] sp_code_w=sp_w1[11:0]+{sp_row,6'd0}+{10'd0,sp_col};
 wire [8:0] sp_t=sp_w3[8:0]+9'd6+{4'd0,sp_s,3'd0};              // (X-10+8s+16) & 511
 wire [9:0] sp_sx_w={1'b0,sp_t}-10'd8;                          // -8..503 (signed 10-bit)
 wire signed [10:0] sp_sxs={sp_sx_w[9],sp_sx_w};
 wire sp_col_visible=(sp_sxs<=$signed({2'b0,win_max_x})) && (sp_sxs+11'sd7>=$signed({2'b0,win_min_x}));
 wire [2:0] sp_pyf_w=sp_flipy ? 3'd7-sp_py : sp_py;              // pixel row inside the tile
 // scan evaluation of word 0 (registered read data valid one cycle after the address)
 // M33: with game FLIP a line shows the sprites of the mirrored line 287-y.
 wire [8:0] spr_line9=9'd287-{1'b0,target};
 wire [7:0] spr_line=gflip ? spr_line9[7:0] : target;
 wire [8:0] scan_d=({1'b0,spr_line}-sprite_rdata[8:0]-9'd2);   // (line - Y - 2) & 511
 wire scan_hit=scan_d<{2'b0,sprite_rdata[14:12],3'b000}+9'd8;  // d < 8*height
 // metadata FIFO between walkers and the writer. M29 widened it with the
 // 4-bpp flag, the alternate-palette flag and an 8-bit palette base that
 // covers both depths:
 //   8-bpp pixel -> index = {ibase[3:0], pixel[7:0]}
 //   4-bpp pixel -> index = {ibase[7:0], pixel[3:0]}
 // {opaque, altpal, four, shape[7:0], sx[9:0], flipx, shadow, pri[2:0], ibase[7:0]}
 reg [33:0] meta[0:7];reg [2:0] meta_rd=0,meta_wr=0;reg [3:0] meta_count=0;
 // writer
 reg writer_active=0;reg [2:0] wk=0;
 wire [33:0] mhead=meta[meta_rd];
 wire [7:0] m_ibase=mhead[7:0];wire [2:0] m_pri=mhead[10:8];wire m_shadow=mhead[11],m_flipx=mhead[12];
 wire [9:0] m_sx=mhead[22:13];wire [7:0] m_shape=mhead[30:23];
 wire m_four=mhead[31],m_altpal=mhead[32],m_opaque=mhead[33];
 wire [63:0] row=row_data[sl*64+:64];
 wire [2:0] wc=m_flipx ? 3'd7-wk : wk;                          // source column
 // Setup-timing fix: wx used to be combinational (m_sx+wk) with claimed[wx]
 // read and written in the same cycle it was computed, chaining an adder in
 // series with two 304-wide dynamic decodes of `claimed` (clk_sys setup
 // violation, na1_renderer|meta->Add14->Mux156->claimed). wx_p/claimed_p
 // hold the same values one cycle earlier: wx_p is an accumulator seeded
 // with m_sx and incremented by 1 each committed pixel (always numerically
 // equal to the old m_sx+wk for the pixel currently being committed), and
 // claimed_p is claimed[]'s value at that address, prefetched the previous
 // cycle (never stale: within a burst wx_p is strictly increasing so no
 // pixel ever revisits an address written earlier in the same burst, and
 // priming happens on the pre-existing row_pop settle cycle between bursts,
 // after the prior burst's last claimed[] write has already committed).
 // Pure retiming: no new cycle is introduced, no value changes.
 reg [9:0] wx_p=0;reg claimed_p=0;
 wire [9:0] wx_p_next=wx_p+10'd1;
 wire [7:0] wpix=wc[0] ? row[{wc[2:1],4'd0}+:8] : row[{wc[2:1],4'd0}+8+:8];
 // One composition rule for both depths (MAME tile_pixel: the 4-bpp planes are
 // bit offsets 4..7, i.e. the low nibble of the same byte).
 wire [11:0] widx=m_four ? {m_ibase,wpix[3:0]} : {m_ibase[3:0],wpix};
 wire wvis=m_opaque || m_shape[3'd7-wc];
 wire w_in_window=!wx_p[9] && wx_p[8:0]>=win_min_x && wx_p[8:0]<=win_max_x;
 wire w_sprite=sl==SPR;
 wire layer_done=wstate==W_DONE && meta_count==0 && !writer_active;
 wire sprites_done=sstate==S_DONE && meta_count==0 && !writer_active;

 // ---- ROZ layer 4 -----------------------------------------------------------
 // MAME draw_roz_core with wraparound off. Per line:
 //   startx = (xoff<<12) + incxx*(46+minx) + incyx*(line-8)
 //   starty = (yoff<<12) + incxy*(46+minx) + incyy*(line-8)
 // and per pixel startx += incxx / starty += incxy. The incyx*(line-8) term is
 // accumulated once per replayed scroll line rather than multiplied, so the
 // whole transform costs two 32xN multipliers, evaluated once per line.
 localparam Z_IDLE=0,Z_PIX=1,Z_MAP=2,Z_MAPW=3,Z_SHAPEW=4,Z_FETCH=5,Z_ROW=6,Z_WRITE=7,Z_DONE=8;
 reg [3:0] zstate=Z_IDLE;
 wire [2:0] roz_pri=raa[2:0];
 wire roz_four=rbc[4];
 wire signed [31:0] z_incxx={{8{rc0[15]}},rc0,8'd0};
 wire signed [31:0] z_incxy={{8{rc2[15]}},rc2,8'd0};
 wire signed [31:0] z_incyx={{8{rc4[15]}},rc4,8'd0};
 wire signed [31:0] z_incyy={{8{rc6[15]}},rc6,8'd0};
 wire signed [31:0] z_xoff={{4{rc8[15]}},rc8,12'd0};
 wire signed [31:0] z_yoff={{4{rca[15]}},rca,12'd0};
 // 46 + minx, using the same clamped window the layers use.
 // Narrow on purpose: 46+minx never exceeds 349, so this is a 32x10 signed
 // multiply (a couple of DSP blocks), not a 32x32 one.
 wire signed [9:0] z_dx=$signed({1'b0,c_min_x+9'd46});
 wire signed [31:0] z_basex=z_xoff + z_incxx*z_dx - {z_incyx[28:0],3'd0};
 wire signed [31:0] z_basey=z_yoff + z_incxy*z_dx - {z_incyy[28:0],3'd0};
 reg signed [31:0] z_linex=0,z_liney=0;   // line start, accumulated over the replay
 reg signed [31:0] zcx=0,zcy=0;           // running pixel coordinate
 reg [8:0] zx=0;
 reg [11:0] ztile=0;reg [2:0] zpy=0,zpx=0,zsub=0;reg zopaque=0;
 reg [7:0] zshape=0;reg [63:0] zrow=0;
 reg [14:0] zkey=0;reg zcache_ok=0;
 wire [15:0] z_xi=zcx[31:16],z_yi=zcy[31:16];
 wire z_off_map=(|z_xi[15:9]) || (|z_yi[15:9]);
 wire [5:0] z_c=z_xi[8:3],z_r=z_yi[8:3];
 // Map page $FF8000 = video word $4000, i.e. bit 14 -- plus (r>>2)*64 + (c>>2).
 wire [14:0] z_mapaddr={1'b1,4'd0,z_r[5:2],2'b00,z_c[5:2]};
 wire [14:0] z_newkey={z_c,z_r,z_yi[2:0]};
 wire [11:0] z_tile_w=(video_rdata[11:0] & 12'hfbf)+{4'd0,z_r[1:0],6'd0}+{10'd0,z_c[1:0]};
 wire [7:0] zpix=zpx[0] ? zrow[{zpx[2:1],4'd0}+:8] : zrow[{zpx[2:1],4'd0}+8+:8];
 wire [11:0] zidx=roz_four ? {rba[3:0],1'b0,zsub,zpix[3:0]} : {rba[3:0],zpix};
 wire z_last=(zx==win_max_x);
 wire roz_done=zstate==Z_DONE;

 wire px_read=state==PIXLINE && (pstate==P_RD || (pstate==P_LO && !px_last));
 assign video_enable=(wstate==W_MAP) || (zstate==Z_MAP) || px_read;
 assign video_word_addr=(zstate==Z_MAP) ? z_mapaddr : px_read ? px_addr : {1'b0,sl[1:0],tile_y,tile_x};
 assign shape_enable=(wstate==W_MAP_WAIT) || (sstate==S_SHAPE) || (zstate==Z_MAPW);
 // The map word is live in W_MAP_WAIT / Z_MAPW, so the shape address is formed
 // combinationally from it in the same cycle.
 assign shape_word_addr=(sstate==S_SHAPE) ? {sp_code_w,sp_pyf_w[2:1]} :
                        (zstate==Z_MAPW)  ? {z_tile_w,z_yi[2:1]} :
                                            {video_rdata[11:0],py[2:1]};
 assign scroll_enable=state==SCROLL;
 assign scroll_word_addr={sidx[2:1],sidx[0],scroll_line};
 assign sprite_enable=(sstate==S_SCAN && scan_n!=9'd256) || sstate==S_W1 || sstate==S_W2 || sstate==S_W3;
 assign sprite_word_addr=(sstate==S_SCAN) ? {r22[0],scan_n[7:0],2'd0} :
                         (sstate==S_W1)   ? {r22[0],sp_n,2'd1} :
                         (sstate==S_W2)   ? {r22[0],sp_n,2'd2} : {r22[0],sp_n,2'd3};


 wire start=line_event && (event_line>=8'd31 && event_line<=8'd254);
 // M33: game FLIP negates the layer X origin (410 - 4*layer - scroll, mod 512).
 wire [8:0] lx_org=gflip ? (9'd410-{5'd0,sel_l[1:0],2'b00}-scrollx[sel_l][8:0]) : scrollx[sel_l][8:0];
 wire [8:0] sx0=win_min_x+lx_org;
 wire [8:0] sy0={1'b0,target}+scrolly[sel_l];
 wire [9:0] span=win_max_x-(win_min_x-{7'd0,sx0[2:0]})+10'd8; // pixels+px0+7
 // $EFFFBC bit n selects 4 bpp for normal layer n (bit 4 is the ROZ layer).
 wire layer_four=rbc[sl[1:0]];
 wire line_in_window=win_valid && target>=win_min_y && target<=win_max_y;
 // CRTC blank: outside the display window (or with no window programmed) the
 // board outputs black, not the backdrop pen MAME fills its whole bitmap with.
 wire fill_blank=!disp_valid || fill_x<win_min_x || fill_x>win_max_x
                 || target<win_min_y || target>win_max_y;

 integer i;
 initial begin
  for(i=0;i<4;i=i+1) begin scrollx[i]=0;scrolly[i]=0;prio[i]=0;bank[i]=0;pix_ydata[i]=0;end
  for(i=0;i<8;i=i+1) meta[i]=0;
  for(i=0;i<304;i=i+1) pmap[i]=0;
 end

 always @(posedge clk_sys) begin
  lb_we<=0;sb_we<=0;row_pop<=0;
  if(reset) begin
   state<=IDLE;wstate<=W_IDLE;sstate<=S_IDLE;zstate<=Z_IDLE;busy<=0;overrun_count<=0;lines_rendered<=0;
   fetch_req<=0;meta_rd<=0;meta_wr<=0;meta_count<=0;writer_active<=0;wk<=0;claimed<=0;
   flip_l<=flip_native;gflip<=vreg[16*7'h4c+:16]!=16'd0;
  end else begin
   if(line_event && event_line==8'd0) begin flip_l<=flip_native;gflip<=vreg[16*7'h4c+:16]!=16'd0;end
   if(start) begin
    if(busy) overrun_count<=overrun_count+1'b1;
    else begin
     // M24: flipped presentation fetches the mirrored source line. Display
     // line D is rendered at event_line D-1, so the flipped source is
     // 287-D == 286-event_line; event_line 31..254 maps onto targets
     // 255..32, exactly the same set of lines as normal order. buf_sel stays
     // keyed to the DISPLAY line (~event_line[0] == D[0], matching the
     // beam_y[0] readout), never to the mirrored source line.
     busy<=1;target<=flip_l ? (8'd286-event_line) : (event_line+1'b1);
     buf_sel<=~event_line[0];
     scroll_line<=0;sidx<=0;state<=SNAP;
    end
   end
   case(state)
    IDLE: ;
    SNAP: begin
     // M31: from the committed shadow (field order as vr_live, MSB first).
     {r80,r82,r84,r86,r8e,rba,r22,rbc,raa,rc0,rc2,rc4,rc6,rc8,rca,
      prio[0],prio[1],prio[2],prio[3],bank[0],bank[1],bank[2],bank[3]}<=vr_shadow;
     for(i=0;i<4;i=i+1) begin scrollx[i]<=16'h3a-2*i;scrolly[i]<=0;end
     state<=SCROLL;
    end
    // Scroll command replay, MAME order: lines 0..target ascending, layers
    // 0..3, X then Y. One read per cycle; data is applied one cycle later.
    SCROLL: begin
     // ROZ line start: seeded on the first replay cycle (the snapshot regs are
     // valid by then) and advanced by incyx/incyy once per replayed line, so
     // it lands on exactly MAME's startx/starty for `target` with no per-line
     // multiply by the line number.
     if(scroll_line==0 && sidx==0) begin z_linex<=z_basex;z_liney<=z_basey;end
     if(sidx==3'd7) begin
      sidx<=0;
      if(scroll_line==target) state<=SCROLL_LAST;
      else begin
       scroll_line<=scroll_line+1'b1;
       z_linex<=z_linex+z_incyx;z_liney<=z_liney+z_incyy;
      end
     end else sidx<=sidx+1'b1;
    end
    SCROLL_LAST: begin                          // final Y word applied this cycle
     // M33: game FLIP mirrors the window with the line (readout x -> 303-x).
     win_min_x<=gflip ? 9'd303-c_max_x : c_min_x;win_max_x<=gflip ? 9'd303-c_min_x : c_max_x;
     win_min_y<=c_min_y;win_max_y<=c_max_y;
     win_valid<=(c_min_x<=c_max_x) && (c_min_y<=c_max_y) && r8e!=0;
     disp_valid<=!mx[16] && !xx[16] && (c_min_x<=c_max_x) && (c_min_y<=c_max_y);
     fill_x<=0;claimed<=0;state<=FILL;
    end
    FILL: begin
     lb_we<=1;lb_waddr<={buf_sel,fill_x};lb_wdata<={fill_blank,1'b0,rba[3:0],8'd0};
     sb_we<=1;sb_waddr<={buf_sel,fill_x};sb_wdata<=0;
     pmap[fill_x]<=4'd0;
     if(fill_x==9'd303) begin sel_p<=0;sel_l<=3'd4;state<=SELECT;end
     else fill_x<=fill_x+1'b1;
    end
    // MAME draw order: priority 0..7, and within one priority ROZ(4) first,
    // then layers 3..0 (a later draw overwrites and owns the priority map).
    SELECT: begin
     if(line_in_window && sel_l==3'd4 && roz_pri==sel_p) begin
      sl<=SPR;                                  // ROZ borrows the spare fetch slot
      zx<=win_min_x;zcx<=z_linex;zcy<=z_liney;zcache_ok<=0;
      zstate<=Z_PIX;state<=ROZ;
     end else if(line_in_window && sel_l!=3'd4 && prio[sel_l[1:0]]==sel_p && pix_mode[sel_l[1:0]]) begin
      px_x<=0;px_addr<=pix_ydata[sel_l[1:0]][14:0]+15'd25;pstate<=P_RD;state<=PIXLINE;
     end else if(line_in_window && sel_l!=3'd4 && prio[sel_l[1:0]]==sel_p) begin
      sl<={1'b0,sel_l[1:0]};
      tile_x<=sx0[8:3];base_x<={1'b0,win_min_x}-{7'd0,sx0[2:0]};
      tile_n<=span[8:3];tile_i<=0;tile_y<=sy0[8:3];py<=sy0[2:0];
      wstate<=W_MAP;state<=LAYER;
     end else if(sel_l!=0) sel_l<=sel_l-1'b1;
     else if(sel_p!=7) begin sel_p<=sel_p+1'b1;sel_l<=3'd4;end
     else begin sl<=SPR;sstate<=line_in_window ? S_SCAN : S_DONE;scan_n<=0;eval_valid<=0;state<=SPRITES;end
    end
    LAYER: if(layer_done) begin
     wstate<=W_IDLE;
     if(sel_l!=0) begin sel_l<=sel_l-1'b1;state<=SELECT;end
     else if(sel_p!=7) begin sel_p<=sel_p+1'b1;sel_l<=3'd4;state<=SELECT;end
     else begin sl<=SPR;sstate<=line_in_window ? S_SCAN : S_DONE;scan_n<=0;eval_valid<=0;state<=SPRITES;end
    end
    ROZ: if(roz_done) begin
     zstate<=Z_IDLE;
     if(sel_l!=0) begin sel_l<=sel_l-1'b1;state<=SELECT;end
     else if(sel_p!=7) begin sel_p<=sel_p+1'b1;sel_l<=3'd4;state<=SELECT;end
     else begin sl<=SPR;sstate<=line_in_window ? S_SCAN : S_DONE;scan_n<=0;eval_valid<=0;state<=SPRITES;end
    end
    // M30 direct-pixel line: read one video word, write its high pen, then its
    // low pen while the next word's read is issued (2 clocks per word).
    PIXLINE: case(pstate)
     P_RD: pstate<=P_HI;                            // first word's read issued
     P_HI: begin                                     // word valid: high byte = pixel px_x
      px_lo<=video_rdata[7:0];pmap[px_x]<=PMAP_TOP;px_addr<=px_addr+1'b1;
      if(px_hi_in) begin lb_we<=1;lb_waddr<={buf_sel,px_x};lb_wdata<={5'd0,video_rdata[15:8]};end
      pstate<=P_LO;
     end
     default: begin                                  // P_LO: pixel px_x+1; next read issued
      pmap[px_x1]<=PMAP_TOP;
      if(px_lo_in) begin lb_we<=1;lb_waddr<={buf_sel,px_x1};lb_wdata<={5'd0,px_lo};end
      px_x<=px_x+9'd2;pstate<=P_HI;
      if(px_last) begin
       pstate<=P_RD;
       if(sel_l!=0) begin sel_l<=sel_l-1'b1;state<=SELECT;end
       else if(sel_p!=7) begin sel_p<=sel_p+1'b1;sel_l<=3'd4;state<=SELECT;end
       else begin sl<=SPR;sstate<=line_in_window ? S_SCAN : S_DONE;scan_n<=0;eval_valid<=0;state<=SPRITES;end
      end
     end
    endcase
    SPRITES: if(sprites_done) begin sstate<=S_IDLE;state<=DONE;end
    DONE: begin busy<=0;lines_rendered<=lines_rendered+1'b1;state<=IDLE;end
    default: state<=IDLE;
   endcase

   // ---- scroll read data phase --------------------------------------------
   d_valid<=state==SCROLL;d_isy<=sidx[0];d_layer<=sidx[2:1];d_line<=scroll_line;
   if(d_valid) begin
    if(!d_isy) xword<=scroll_rdata;
    else begin
     // M30: the target line's own words decide direct-pixel mode (MAME tests
     // xdata == $C001 on the line being drawn, after applying its scroll).
     if(d_line==target) begin pix_mode[d_layer]<=(xword==16'hc001);pix_ydata[d_layer]<=scroll_rdata;end
     if(xword!=0) scrollx[d_layer]<=xword[14] ? (16'h3a-2*d_layer+xword) : scrollx[d_layer]+{7'd0,xword[8:0]};
     // M27: the line-select table is a row POINTER with the same load/accumulate
     // structure as the X table above -- bit 14 loads, otherwise the entry is a
     // signed-mod-512 per-line delta. We previously implemented only the load
     // half (inherited from MAME's namcona1_v.cpp:491-495, which implements
     // accumulate for X but not for Y), so F/A's service-menu FLIP rendered as
     // corruption: with FLIP on the table is 42ff followed by 255 entries of
     // 3fff, none of which set bit 14, so the pointer froze and every scanline
     // fetched row L+255 instead of 255-L. See docs/M27_RESEARCH.md items 11/14.
     //
     // `scrolly` is an offset added to the beam line (sy0 = target + scrolly),
     // so advancing the pointer by `delta` per line means scrolly += delta-1:
     //   delta=+1  (0001) -> scrolly unchanged  -> row = L-32   (FLIP off)
     //   delta=-1  (01ff) -> scrolly -= 2       -> row = 255-L  (FLIP on)
     // A zero entry means "no change", matching the `xword!=0` guard above.
     // This is a strict extension: across every M19 golden capture the only
     // values F/A ever writes are 0001 and the bit-14 load entries, both of
     // which behave exactly as before, so the pixel-exact M19 result is unmoved.
     if(scroll_rdata[14]) scrolly[d_layer]<=scroll_rdata[8:0]-{1'b0,d_line};
     else if(scroll_rdata!=0) scrolly[d_layer]<=scrolly[d_layer]+scroll_rdata[8:0]-9'd1;
    end
   end

   // ---- layer walker: map word -> shape byte -> row command ----------------
   case(wstate)
    W_MAP: wstate<=W_MAP_WAIT;                       // video read issued
    W_MAP_WAIT: begin                                 // map word valid; shape read issued
     tile_code<=video_rdata[11:0];tile_opaque<=video_rdata[15];
     tile_sub<=video_rdata[14:12];wstate<=W_SHAPE_WAIT;
    end
    W_SHAPE_WAIT: begin : shape_phase                 // shape word valid
     reg [7:0] sb;
     sb=py[0] ? shape_rdata[7:0] : shape_rdata[15:8];
     if(!tile_opaque && sb==8'd0) begin              // fully transparent row: nothing to fetch
      tile_x<=tile_x+1'b1;
      if(tile_i+1'b1==tile_n) wstate<=W_DONE;
      else begin tile_i<=tile_i+1'b1;wstate<=W_MAP;end
     end else begin
      meta[meta_wr]<={tile_opaque,1'b0,layer_four,sb,base_x+{1'b0,tile_i,3'b000},
                      1'b0,1'b0,prio[sl[1:0]],
                      layer_four ? {bank[sl[1:0]],1'b0,tile_sub} : {4'd0,bank[sl[1:0]]}};
      fetch_row_word<={tile_code,py};fetch_req[sl]<=1;wstate<=W_FETCH;
     end
    end
    W_FETCH: if(fetch_accept[sl]) begin
     fetch_req[sl]<=0;meta_wr<=meta_wr+1'b1;
     tile_x<=tile_x+1'b1;
     if(tile_i+1'b1==tile_n) wstate<=W_DONE;
     else begin tile_i<=tile_i+1'b1;wstate<=W_MAP;end
    end
    default: ;
   endcase

   // ---- sprite scan/walker ---------------------------------------------------
   case(sstate)
    S_SCAN: begin
     // One word-0 read per cycle (entry scan_n), evaluating the entry read the
     // cycle before. On a hit the scan stops and resumes at hit+1 afterwards.
     eval_valid<=scan_n!=9'd256;scan_eval_n<=scan_n[7:0];
     if(scan_n!=9'd256) scan_n<=scan_n+1'b1;
     if(eval_valid && scan_hit) begin
      sp_n<=scan_eval_n;sp_w0<=sprite_rdata;sp_k<=scan_d[5:3];sp_py<=scan_d[2:0];
      scan_n<={1'b0,scan_eval_n}+9'd1;eval_valid<=0;sstate<=S_W1;
     end else if(scan_n==9'd256 && !eval_valid) sstate<=S_DONE;
    end
    S_W1: sstate<=S_W2;                               // word 1 read issued
    S_W2: begin sp_w1<=sprite_rdata;sstate<=S_W3;end  // word 1 valid, word 2 issued
    S_W3: begin sp_w2<=sprite_rdata;sp_s<=0;sstate<=S_COL;end // word 2 valid, word 3 issued
    S_COL: begin                                      // word 3 valid on the first pass
     if(sp_s==0) sp_w3<=sprite_rdata;
     sstate<=S_SHAPE;
    end
    S_SHAPE: begin                                    // sx/code/py settled: shape read issued
     sp_code<=sp_code_w;sp_sx<=sp_sx_w;sp_pyf<=sp_pyf_w;
     if(!sp_col_visible) sstate<=S_NEXT;
     else sstate<=S_SHAPE_WAIT;
    end
    S_SHAPE_WAIT: begin : sprite_shape_phase          // shape word valid
     reg [7:0] sb;
     sb=sp_pyf[0] ? shape_rdata[7:0] : shape_rdata[15:8];
     if(!sp_opaque && sb==8'd0) sstate<=S_NEXT;
     else begin
      meta[meta_wr]<={sp_opaque,sp_altpal,sp_bpp4,sb,sp_sx,sp_flipx,sp_shadow,sp_pri,sp_ibase};
      fetch_row_word<={sp_code,sp_pyf};fetch_req[SPR]<=1;sstate<=S_FETCH;
     end
    end
    S_FETCH: if(fetch_accept[SPR]) begin fetch_req[SPR]<=0;meta_wr<=meta_wr+1'b1;sstate<=S_NEXT;end
    S_NEXT: begin
     if(sp_s==sp_w1w) sstate<=S_SCAN;               // resume the scan at the next entry
     else begin sp_s<=sp_s+1'b1;sstate<=S_COL;end
    end
    default: ;
   endcase
   // ---- ROZ walker: one pixel at a time, with a one-tile-row cache ---------
   // Each pixel needs a map word, a shape byte and a character row; consecutive
   // pixels almost always land in the same tile row, so a single-entry cache
   // keyed on {map column, map row, pixel row} collapses the common case to one
   // write cycle per pixel.
   case(zstate)
    Z_PIX: begin
     zpx<=z_xi[2:0];zpy<=z_yi[2:0];
     if(z_off_map) begin                        // wraparound off: outside the map, skip
      zx<=zx+1'b1;zcx<=zcx+z_incxx;zcy<=zcy+z_incxy;
      if(z_last) zstate<=Z_DONE;
     end else if(zcache_ok && zkey==z_newkey) zstate<=Z_WRITE;
     else zstate<=Z_MAP;
    end
    Z_MAP: zstate<=Z_MAPW;                      // video read issued
    Z_MAPW: begin                                // map word valid; shape read issued
     ztile<=z_tile_w;zopaque<=video_rdata[15];zsub<=video_rdata[14:12];
     zstate<=Z_SHAPEW;
    end
    Z_SHAPEW: begin : roz_shape_phase            // shape word valid
     reg [7:0] sb;
     sb=zpy[0] ? shape_rdata[7:0] : shape_rdata[15:8];
     zshape<=sb;zkey<=z_newkey;zcache_ok<=1;
     if(!zopaque && sb==8'd0) zstate<=Z_WRITE;   // fully transparent row: no fetch
     else begin fetch_row_word<={ztile,zpy};fetch_req[SPR]<=1;zstate<=Z_FETCH;end
    end
    Z_FETCH: if(fetch_accept[SPR]) begin fetch_req[SPR]<=0;zstate<=Z_ROW;end
    Z_ROW: if(row_valid[SPR] && !row_pop[SPR]) begin
     zrow<=row_data[SPR*64+:64];row_pop[SPR]<=1;zstate<=Z_WRITE;
    end
    Z_WRITE: begin
     if(zopaque || zshape[3'd7-zpx]) begin
      lb_we<=1;lb_waddr<={buf_sel,zx};lb_wdata<={1'b0,zidx};pmap[zx]<={1'b0,roz_pri};
     end
     zx<=zx+1'b1;zcx<=zcx+z_incxx;zcy<=zcy+z_incxy;
     zstate<=z_last ? Z_DONE : Z_PIX;
    end
    default: ;
   endcase

   // ---- writer: one row consumed once, up to eight pixels ------------------
   if(!writer_active) begin
    // A pop is applied one edge after it is raised; never restart on that edge.
    // This settle cycle already exists purely to let row_pop clear; reuse it
    // to prime pixel 0's address/claimed bit one cycle ahead of first use.
    // mhead already reflects the new meta entry here (meta_rd advanced when
    // the previous burst's last pixel committed), so m_sx is valid now.
    if((state==LAYER || state==SPRITES) && meta_count!=0 && row_valid[sl] && !row_pop[sl]) begin
     writer_active<=1;wk<=0;wx_p<=m_sx;claimed_p<=claimed[m_sx[8:0]];
    end
   end else begin
    if(w_in_window && wvis) begin
     if(!w_sprite) begin
      lb_we<=1;lb_waddr<={buf_sel,wx_p[8:0]};lb_wdata<={1'b0,widx};pmap[wx_p[8:0]]<={1'b0,m_pri};
     end else if(!claimed_p) begin
      claimed[wx_p[8:0]]<=1;
      if(pmap[wx_p[8:0]]<={1'b0,m_pri}) begin
       if(m_shadow) begin sb_we<=1;sb_waddr<={buf_sel,wx_p[8:0]};sb_wdata<=1;end
       else begin lb_we<=1;lb_waddr<={buf_sel,wx_p[8:0]};lb_wdata<={m_altpal,widx};end
      end
     end
    end
    // Prefetch the next pixel's address/claimed bit one cycle ahead; skipped
    // on the last pixel (wk==7), which instead re-primes at the next arm.
    if(wk!=3'd7) begin wx_p<=wx_p_next;claimed_p<=claimed[wx_p_next[8:0]];end
    if(wk==3'd7) begin writer_active<=0;row_pop[sl]<=1;meta_rd<=meta_rd+1'b1;end
    wk<=wk+1'b1;
   end
   // metadata FIFO occupancy (push on accept, pop at the last pixel)
   meta_count<=meta_count+(((wstate==W_FETCH && fetch_accept[sl]) || (sstate==S_FETCH && fetch_accept[SPR])) ? 4'd1 : 4'd0)
                         -((writer_active && wk==3'd7) ? 4'd1 : 4'd0);
  end
 end
endmodule
