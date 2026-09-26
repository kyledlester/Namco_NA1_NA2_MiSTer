`timescale 1ns/1ps
// VIDEO_CE_FIX: production pixel-enable / raster contract (docs/VIDEO_CE_FIX.md).
//
// Production na1_video_timing + na1_video_transport + na1_interrupts, plus an
// exact stand-in for the renderer's three-stage output pipeline (colour =
// beam x/y). Everything is counted in clk_sys (= CLK_VIDEO) cycles, so the
// result is independent of the PLL frequency.
//
// Proves (numbers refer to the VIDEO_CE_FIX test list):
//  1  pixel_ce and transport ce_pix are single-cycle pulses
//  2  EVERY pair of pulses is exactly 14 clocks apart (from power-up, through
//     reset, reset release and every line/frame boundary)
//  3  456 ce_pix per line            4  456 x 263 = 119,928 per frame
//  5  every line is exactly 6,384 clocks, 6 every frame 1,678,992 clocks
//  7  transport RGB changes only on the clock ce_pix is high
//  8  HBlank/VBlank/HSync/VSync/DE likewise
//  9  raster identical while reset (ROM download) is held and after release
// 10  renderer workload cannot touch the cadence: a second transport whose
//     renderer input is starved/late (in_valid randomly dropped, colour
//     garbage) produces a bit-identical ce_pix/sync/blank trace, and a second
//     timing instance with a different reset / IRQ-line history produces a
//     bit-identical raster
// plus the M23 geometry (HSync 32 px, VSync 3 lines, DE 304x224, active
// window 104 dots after HSync rise) and the logical 256-line/IRQ contract.
module video_ce_tb;
    reg clk=0; always #5 clk=~clk;
    reg reset=1;
    reg [7:0] irq_position=8'd32;

    localparam integer DIV=14, H_TOTAL=456, V_TOTAL=263, PX_FRAME=H_TOTAL*V_TOTAL; // 119,928
    localparam integer LINE_CLK=DIV*H_TOTAL, FRAME_CLK=DIV*PX_FRAME;              // 6,384 / 1,678,992
    localparam real    SYS_MHZ=100.226;   // for the printed rates only

    wire profile_available,pixel_ce,visible,hblank,vblank,line_event,frame_event;
    wire [8:0] beam_x; wire [7:0] beam_y,event_line;
    wire irq3_event,irq4_event,hsync,vsync,sync_valid; wire [1:0] profile_id;
    na1_video_timing dut(.clk_sys(clk),.reset(reset),.irq_position(irq_position),
        .profile_id(profile_id),.profile_available(profile_available),.pixel_ce(pixel_ce),
        .beam_x(beam_x),.beam_y(beam_y),.visible(visible),.hblank(hblank),.vblank(vblank),
        .line_event(line_event),.frame_event(frame_event),.event_line(event_line),
        .irq3_event(irq3_event),.irq4_event(irq4_event),.hsync(hsync),.vsync(vsync),
        .sync_valid(sync_valid));

    // Twin timing instance with a different reset/IRQ-programming history.
    reg reset_b=0; reg [7:0] irq_b=8'd200;
    wire b_ce,b_vis,b_hb,b_vb,b_hs,b_vs; wire [8:0] b_x; wire [7:0] b_y;
    na1_video_timing twin(.clk_sys(clk),.reset(reset_b),.irq_position(irq_b),
        .profile_id(),.profile_available(),.pixel_ce(b_ce),.beam_x(b_x),.beam_y(b_y),
        .visible(b_vis),.hblank(b_hb),.vblank(b_vb),.line_event(),.frame_event(),.event_line(),
        .irq3_event(),.irq4_event(),.hsync(b_hs),.vsync(b_vs),.sync_valid());

    // Renderer stand-in: identical to na1_renderer's output stages.
    reg s1_v=0,s2_v=0,o_v=0,s1_vis=0,s2_vis=0,o_vis=0;
    reg [8:0] s1_x=0,s2_x=0,o_x=0; reg [7:0] s1_y=0,s2_y=0,o_y=0;
    wire [23:0] o_rgb={o_x[7:0],o_y,8'h5a};
    always @(posedge clk) begin
        s1_v<=pixel_ce&&!reset; s1_vis<=visible; s1_x<=beam_x; s1_y<=beam_y;
        s2_v<=s1_v; s2_vis<=s1_vis; s2_x<=s1_x; s2_y<=s1_y;
        o_v<=s2_v; o_vis<=s2_vis; o_x<=s2_x; o_y<=s2_y;
    end

    wire ce_pix,t_hb,t_vb,t_hs,t_vs,t_de,t_vis; wire [23:0] t_rgb;
    na1_video_transport transport(.clk_sys(clk),
        .pixel_ce(pixel_ce),.beam_visible(visible),.beam_hblank(hblank),.beam_vblank(vblank),
        .beam_hsync(hsync),.beam_vsync(vsync),
        .in_valid(o_v),.in_visible(o_vis),.in_rgb(o_rgb),
        .ce_pix(ce_pix),.rgb(t_rgb),.hblank(t_hb),.vblank(t_vb),.hsync(t_hs),.vsync(t_vs),
        .de(t_de),.visible(t_vis));

    // Starved-renderer twin transport: random in_valid drops, garbage colour.
    reg [31:0] lfsr=32'h1;
    always @(posedge clk) lfsr<={lfsr[30:0],lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
    wire w_ce,w_hb,w_vb,w_hs,w_vs,w_de; wire [23:0] w_rgb;
    na1_video_transport starved(.clk_sys(clk),
        .pixel_ce(pixel_ce),.beam_visible(visible),.beam_hblank(hblank),.beam_vblank(vblank),
        .beam_hsync(hsync),.beam_vsync(vsync),
        .in_valid(o_v&lfsr[3]),.in_visible(o_vis),.in_rgb(lfsr[23:0]),
        .ce_pix(w_ce),.rgb(w_rgb),.hblank(w_hb),.vblank(w_vb),.hsync(w_hs),.vsync(w_vs),
        .de(w_de),.visible());

    wire pending3,pending4,event3,event4; wire [2:0] level;
    na1_interrupts irq(.clk_sys(clk),.reset(reset),.cpu_reset(1'b0),.tick(line_event),
        .line(event_line),.enabled(1'b1),.mask(16'd0),.position(irq_position),
        .iack_service(1'b1),.iack_level(level),.pending3(pending3),.pending4(pending4),
        .level(level),.event3(event3),.event4(event4));

    integer checks=0;
    task check(input cond,input [8*120-1:0] msg);
        begin checks=checks+1; if(!cond) $fatal(1,"VIDEO CE check failed: %0s",msg); end
    endtask

    // ---- cadence: every pixel_ce / ce_pix gap, from power-up ----------------
    integer t=0, last_pce=-1, last_ce=-1, pce_count=0, ce_count=0;
    integer gap_bad=0, ce_gap_bad=0, width_bad=0, twin_bad=0, starve_bad=0, chg_bad=0;
    reg prev_pce=0, prev_ce=0;
    reg [23:0] p_rgb=0; reg p_hb=1,p_vb=1,p_hs=0,p_vs=0,p_de=0;
    always @(posedge clk) begin
        t=t+1;
        if(pixel_ce) begin
            if(last_pce>=0 && t-last_pce!=DIV) gap_bad=gap_bad+1;
            last_pce=t; pce_count=pce_count+1;
        end
        if(ce_pix) begin
            if(last_ce>=0 && t-last_ce!=DIV) ce_gap_bad=ce_gap_bad+1;
            last_ce=t; ce_count=ce_count+1;
        end
        if((pixel_ce&&prev_pce)||(ce_pix&&prev_ce)) width_bad=width_bad+1;
        prev_pce=pixel_ce; prev_ce=ce_pix;
        // twin raster must match cycle for cycle
        if({b_ce,b_x,b_y,b_vis,b_hb,b_vb,b_hs,b_vs}!=={pixel_ce,beam_x,beam_y,visible,hblank,vblank,hsync,vsync})
            twin_bad=twin_bad+1;
        // starved transport: identical cadence/sync/blank/DE (colour may differ)
        if({w_ce,w_hb,w_vb,w_hs,w_vs,w_de}!=={ce_pix,t_hb,t_vb,t_hs,t_vs,t_de}) starve_bad=starve_bad+1;
        // transport outputs change only on the clock where ce_pix is high
        if(!ce_pix && ({t_rgb,t_hb,t_vb,t_hs,t_vs,t_de}!=={p_rgb,p_hb,p_vb,p_hs,p_vs,p_de})) chg_bad=chg_bad+1;
        {p_rgb,p_hb,p_vb,p_hs,p_vs,p_de}={t_rgb,t_hb,t_vb,t_hs,t_vs,t_de};
    end

    // Twin history: pulse its reset and rewrite its IRQ line at odd times.
    initial begin
        #1234567; reset_b=1; irq_b=8'd17;
        #3000001; reset_b=0;
        #7777777; irq_b=8'd100; reset_b=1;
        #1111; reset_b=0;
    end

    // ---- physical raster on the transport outputs ----------------------------
    integer hs_rise=-1,vs_rise=-1,hs_period,vs_period,hs_width;
    integer hs_periods=0,vs_periods=0,hs_bad=0,vs_bad=0,hs_widths_bad=0,vs_widths_bad=0,hs_in_vs=0;
    integer ce_per_line=0,ce_per_frame=0,de_per_line=0,de_lines=0,de_per_frame=0;
    integer hb_per_line=0,vb_lines=0,first_de_x=-1,last_de_x=-1;
    integer bad_lines_ce=0,bad_de=0,bad_rgb=0,bad_hb=0;
    integer ce_x=0,hs_in_frame=0,frames_in_reset=0,frames_after=0;
    reg old_hs=0,old_vs=0,in_vs=0;
    always @(posedge clk) begin
        old_hs<=t_hs; old_vs<=t_vs;
        if(t_hs&&!old_hs) begin
            if(hs_rise>=0) begin
                hs_period=t-hs_rise; hs_periods=hs_periods+1;
                if(hs_period!=LINE_CLK) hs_bad=hs_bad+1;
                if(ce_per_line!=H_TOTAL) bad_lines_ce=bad_lines_ce+1;
                if(hb_per_line!=H_TOTAL-304) bad_hb=bad_hb+1;
                if(de_per_line!=0 && de_per_line!=304) bad_de=bad_de+1;
                if(de_per_line==304) de_lines=de_lines+1;
                if(in_vs) hs_in_vs=hs_in_vs+1;
            end
            hs_rise=t; ce_per_line=0; hb_per_line=0; de_per_line=0; ce_x=0; hs_in_frame=hs_in_frame+1;
        end
        if(!t_hs&&old_hs && hs_rise>=0) begin hs_width=t-hs_rise; if(hs_width!=32*DIV) hs_widths_bad=hs_widths_bad+1; end
        if(t_vs&&!old_vs) begin
            if(vs_rise>=0) begin
                vs_period=t-vs_rise; vs_periods=vs_periods+1;
                if(vs_period!=FRAME_CLK) vs_bad=vs_bad+1;
                if(ce_per_frame!=PX_FRAME) $fatal(1,"ce per frame %0d",ce_per_frame);
                if(de_per_frame!=304*224) $fatal(1,"DE per frame %0d",de_per_frame);
                if(de_lines!=224) $fatal(1,"DE lines %0d",de_lines);
                if(vb_lines!=V_TOTAL-224) $fatal(1,"VBlank lines %0d",vb_lines);
                if(hs_in_frame!=V_TOTAL) $fatal(1,"HSync per frame %0d",hs_in_frame);
                if(reset) frames_in_reset=frames_in_reset+1; else frames_after=frames_after+1;
            end
            vs_rise=t; ce_per_frame=0; de_per_frame=0; de_lines=0; vb_lines=0; hs_in_vs=0; in_vs=1; hs_in_frame=0;
        end
        if(!t_vs&&old_vs) begin in_vs=0; if(hs_in_vs!=3) vs_widths_bad=vs_widths_bad+1; end
        if(ce_pix) begin
            ce_per_line=ce_per_line+1; ce_per_frame=ce_per_frame+1;
            if(t_hb) hb_per_line=hb_per_line+1;
            if(t_de) begin
                de_per_line=de_per_line+1; de_per_frame=de_per_frame+1;
                if(de_per_line==1) first_de_x=ce_x;
                last_de_x=ce_x;
                if(!reset && (t_rgb[23:16]!=((ce_x-104)&255) || t_rgb[7:0]!=8'h5a)) bad_rgb=bad_rgb+1;
                if(reset && t_rgb!=0) bad_rgb=bad_rgb+1;
            end else if(t_rgb!=0) bad_rgb=bad_rgb+1;
            if(t_de && (t_hb||t_vb)) bad_de=bad_de+1;
            if(ce_x==0 && t_vb) vb_lines=vb_lines+1;
            ce_x=ce_x+1;
        end
    end

    // ---- logical event stream -----------------------------------------------
    integer ev_lines=0,ev_irq3=0,ev_irq4=0,ev_frames=0,ev_order_bad=0,ev_lines_frame=0,ev_irq3_frame=0,ev_irq4_frame=0;
    reg [7:0] expect_line=0; reg synced=0,frame_open=0;
    always @(posedge clk) if(!reset) begin
        if(line_event) begin
            if(!synced) begin synced=1; expect_line=event_line; end
            if(event_line!=expect_line) ev_order_bad=ev_order_bad+1;
            expect_line=expect_line+1'b1;
            if(frame_open) begin
                ev_lines_frame=ev_lines_frame+1;
                if(event3) ev_irq3_frame=ev_irq3_frame+1;
                if(event4) ev_irq4_frame=ev_irq4_frame+1;
            end
            check(irq3_event==(event_line==irq_position) && irq4_event==(event_line==8'd224),"IRQ line selection");
        end else check(!irq3_event&&!irq4_event&&!event3&&!event4,"IRQ needs a line event");
        if(frame_event) begin
            check(expect_line==0,"frame_event follows logical line 255");
            if(frame_open) begin
                ev_frames=ev_frames+1; check(ev_lines_frame==256,"256 logical line events per frame");
                ev_lines=ev_lines+ev_lines_frame; ev_irq3=ev_irq3+ev_irq3_frame; ev_irq4=ev_irq4+ev_irq4_frame;
            end
            frame_open=1; ev_lines_frame=0; ev_irq3_frame=0; ev_irq4_frame=0;
        end
    end

    initial begin
        check(profile_available && sync_valid,"transport sync is valid");
        wait(vs_periods==2);                       // reset held = ROM download
        check(reset && frames_in_reset==2 && hs_bad==0 && vs_bad==0,"raster runs, exact periods, during reset/download");
        check(ev_lines==0 && ev_frames==0,"no logical events while in reset");
        @(negedge clk); reset=0;                   // release mid-frame
        wait(vs_periods==6);
        check(gap_bad==0,"every pixel_ce gap is exactly 14 clk (power-up, reset, release, all boundaries)");
        check(ce_gap_bad==0,"every ce_pix gap is exactly 14 clk");
        check(width_bad==0,"pixel_ce / ce_pix are single-cycle pulses");
        check(hs_bad==0,"every line is exactly 6,384 clk (no fractional drift between lines)");
        check(vs_bad==0,"every frame is exactly 1,678,992 clk (no drift between frames)");
        check(frames_after==4,"four locked frames after release");
        check(hs_widths_bad==0,"every HSync is 32 px = 448 clk");
        check(vs_widths_bad==0,"every VSync spans exactly 3 lines");
        check(bad_lines_ce==0 && bad_hb==0 && bad_de==0,"456 ce/line, 152 blank, DE 304 on active lines only");
        check(first_de_x==104 && last_de_x==407,"active 304 px begins 104 dots after HSync rise");
        check(bad_rgb==0,"RGB carries the correct pixel and is black outside DE / during reset");
        check(chg_bad==0,"RGB/HBlank/VBlank/HSync/VSync/DE change only on ce_pix");
        check(twin_bad==0,"raster independent of reset / IRQ-programming history");
        check(starve_bad==0,"ce_pix/sync/blank/DE independent of renderer valid/colour");
        check(ev_frames>=3 && ev_lines==ev_frames*256 && ev_order_bad==0,"256 ordered logical line events per frame");
        check(ev_irq3==ev_frames && ev_irq4==ev_frames,"one IRQ3 (line 32) and one IRQ4 (line 224) per frame");
        $display("VIDEO CE measured: %0d pixel_ce, all gaps %0d clk; line %0d clk; frame %0d clk; HSync %0d clk",
            pce_count,DIV,hs_period,vs_period,hs_width);
        $display("  at clk_sys %0.3f MHz: pixel %0.1f Hz, H %0.3f Hz, V %0.5f Hz",
            SYS_MHZ,SYS_MHZ*1.0e6/DIV,SYS_MHZ*1.0e6/hs_period,SYS_MHZ*1.0e6/vs_period);
        $display("PASS VIDEO CE CONTRACT: %0d checks",checks);
        $finish;
    end
    initial begin #150000000; $fatal(1,"VIDEO CE timeout hs=%0d vs=%0d",hs_periods,vs_periods); end
endmodule
