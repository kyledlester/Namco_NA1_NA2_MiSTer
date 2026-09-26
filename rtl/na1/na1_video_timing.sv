// M15A timing/profile boundary, M23 CRT transport envelope.
//
// Two rasters live in this one counter:
//
//  * the LOGICAL raster the game sees: 256 numbered lines per frame
//    (0..255, visible 32..255), 304 visible pixels per line (x 0..303),
//    one `line_event`/`event_line` per numbered line in order, IRQ3 at the
//    programmed line, IRQ4 at line 224, `frame_event` once per frame. This
//    is MAME's logical screen and is unchanged from M15A: the renderer and
//    na1_interrupts consume only this contract.
//
//  * the PHYSICAL transport raster that reaches the CRT/HDMI: the complete
//    envelope of the PS6406B video chip as implemented by the working
//    Arcade-PsikyoSH2_MiSTer core (rtl/PSH2/PS6406B.sv, 224-line mode):
//    456 dots per line, 263 lines per frame, 32-dot HSync, 3-line VSync,
//    39-line vertical blanking, 39 dots of blanking before and 64 after
//    HSync around a 320-dot active window. F/A's 304 visible pixels sit
//    centred in that 320-dot window (8 dots each side), which is why HSync
//    starts at x=352 here instead of the chip's 360. [IMPLEMENTATION]
//    borrowed from a proven MiSTer CRT core; NOT Namco NA-1 PCB timing,
//    which remains [UNKNOWN] (M23).
//
// PIXEL ENABLE (docs/VIDEO_CE_FIX.md). `pixel_ce` is an EXACT integer
// division of clk_sys: one single-clock pulse every PIXEL_DIV = 14 clocks,
// never 13 or 15, from a free-running counter with a fixed power-up phase.
// clk_sys is also MiSTer's CLK_VIDEO, and the framework (video_mixer's
// scandoubler, hps_io's vid_pixrep, Direct Video HDMI) requires a constant
// integer number of CLK_VIDEO cycles per pixel; the former fractional
// accumulator (7,159,090 / 100 MHz, 13/14-clock gaps) violated that.
// Production clk_sys = 100.226 MHz (2 x the NA-1 master), so the dot clock is
// 7,159,000 Hz (-13 ppm vs PS6406B's 7,159,090): 15,699.56 Hz / 59.694 Hz.
// The rate follows clk_sys; nothing here may depend on a frequency value.
// Do NOT reintroduce an accumulator: scripts/test-video-ce.ps1 fails on any
// gap other than 14.
//
// The 263-line transport frame holds the 256 logical lines plus V_PAD=7
// unnumbered padding lines inserted after logical line 255, inside vertical
// blanking. Padding lines emit no line_event, so the 8-bit event_line/IRQ
// contract cannot alias.
//
// The raster free-runs from power-up and is never reset: a CRT must keep
// sync through system reset and ROM download (the reference cores keep
// their video timing alive there too). `reset` only suppresses the
// line/frame/IRQ events; the renderer and interrupt unit are in reset
// themselves at that time. NATIVE_NA1 (physical PCB timing) is still
// deliberately unavailable.
module na1_video_timing #(
    parameter [1:0] PROFILE = 2'd0
)(
    input  wire       clk_sys,
    input  wire       reset,
    input  wire [7:0] irq_position,
    output wire [1:0] profile_id,
    output wire       profile_available,
    output wire       pixel_ce,
    output reg  [8:0] beam_x = 9'd0,
    output reg  [7:0] beam_y = 8'd0,
    output wire       visible,
    output wire       hblank,
    output wire       vblank,
    output reg        line_event = 1'b0,
    output reg        frame_event = 1'b0,
    output reg  [7:0] event_line = 8'd0,
    output wire       irq3_event,
    output wire       irq4_event,
    output wire       hsync,
    output wire       vsync,
    output wire       sync_valid
);
    localparam [1:0] PROFILE_MAME_COMPAT = 2'd0;
    localparam [1:0] PROFILE_NATIVE_NA1 = 2'd1;

    // Transport envelope (PS6406B / Arcade-PsikyoSH2_MiSTer, see header).
    localparam integer PIXEL_DIV   = 14;        // clk_sys (= CLK_VIDEO) per pixel, exact
    localparam integer H_TOTAL     = 456;
    localparam integer H_VISIBLE   = 304;       // logical x 0..303
    localparam integer HSYNC_START = 352;       // 32 dots, PS6406B 360 - 8 centring
    localparam integer HSYNC_END   = 383;
    localparam integer V_LOGICAL   = 256;       // logical lines 0..255
    localparam integer V_PAD       = 7;         // unnumbered lines after 255
    localparam integer V_VIS_START = 32;        // logical visible 32..255
    localparam integer VSYNC_START = 6;         // logical lines 6..8 = transport 237..239
    localparam integer VSYNC_END   = 8;

    // Exact divide-by-PIXEL_DIV. Free-running and never reset (M23); the
    // renderer and the rest of the core cannot influence it.
    reg [3:0] pix_div = 4'd0;
    reg pad = 1'b0;
    reg [2:0] pad_cnt = 3'd0;

    assign profile_id = PROFILE;
    assign profile_available = (PROFILE == PROFILE_MAME_COMPAT);
    assign pixel_ce = profile_available && (pix_div == PIXEL_DIV - 1);

    // beam_x/beam_y describe the pixel accepted on the current pixel_ce.
    assign hblank = profile_available && (beam_x >= H_VISIBLE);
    assign vblank = profile_available && (pad || beam_y < V_VIS_START);
    assign visible = profile_available && !hblank && !vblank;
    assign hsync = profile_available && (beam_x >= HSYNC_START) && (beam_x <= HSYNC_END);
    assign vsync = profile_available && !pad && (beam_y >= VSYNC_START) && (beam_y <= VSYNC_END);
    assign sync_valid = profile_available;

    // Events are registered at the closing pixel and observed on the following
    // system edge (M11/M15A phase). Only logical lines produce line_event.
    assign irq3_event = line_event && (event_line == irq_position);
    assign irq4_event = line_event && (event_line == 8'd224);

    always @(posedge clk_sys) begin
        line_event <= 1'b0;
        frame_event <= 1'b0;
        if (!profile_available) begin
            pix_div <= 4'd0;
            beam_x <= 9'd0;
            beam_y <= 8'd0;
            pad <= 1'b0;
            pad_cnt <= 3'd0;
        end else if (pixel_ce) begin
            pix_div <= 4'd0;
            if (beam_x == H_TOTAL - 1) begin
                beam_x <= 9'd0;
                if (pad) begin
                    if (pad_cnt == V_PAD - 1) begin
                        pad <= 1'b0;
                        pad_cnt <= 3'd0;
                        beam_y <= 8'd0;
                        line_event <= !reset;
                        event_line <= 8'd0;
                    end else
                        pad_cnt <= pad_cnt + 1'b1;
                end else if (beam_y == V_LOGICAL - 1) begin
                    pad <= 1'b1;
                    pad_cnt <= 3'd0;
                    beam_y <= 8'd0;
                    frame_event <= !reset;
                end else begin
                    beam_y <= beam_y + 1'b1;
                    line_event <= !reset;
                    event_line <= beam_y + 1'b1;
                end
            end else begin
                beam_x <= beam_x + 1'b1;
            end
        end else begin
            pix_div <= pix_div + 1'b1;
        end
    end
endmodule
