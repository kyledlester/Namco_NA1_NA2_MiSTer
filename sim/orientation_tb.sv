`timescale 1ns/1ps
// VIDEO_CE_FIX orientation truth table (docs/VIDEO_CE_FIX.md, tests 19-23).
//
// The production decode (na1_board_presentation: flip_native, hdmi_rotate,
// hdmi_rotate_ccw) drives the REAL framework screen_rotate (sys/arcade_video.v)
// exactly as NA1.sv wires it (no_rotate = !hdmi_rotate, rotate_ccw =
// hdmi_rotate_ccw, flip = 0). A small W x H test card whose pixels carry their
// raw-raster coordinates is presented natively with the renderer's flip (a
// true 180, proven on the real renderer by the M24 bench) and fed to
// screen_rotate; its DDR writes are captured and the framebuffer read back.
//
// For base_flip 0 and 1 and all four OSD modes it checks, against
//   H          = the board's Horizontal picture (raw, or raw rotated 180 if base_flip)
//   rotCW(img) = image turned 90 degrees clockwise (TOP edge -> right side)
// that:
//   native (analog/Direct Video) == H in Horizontal / Vertical CCW / Vertical CW,
//                                   == H rotated 180 in Flipped          (22, 23)
//   HDMI == H, rotCCW(H), rotCW(H), H rotated 180 respectively           (19-21)
// and, for base_flip 1 (F/A), that both Vertical HDMI pictures are identical to
// the pre-fix HW-confirmed ones (orient 01 = rotCW(raw), 10 = rotCCW(raw)).
module orientation_tb;
    reg clk=0; always #5 clk=~clk;
    localparam integer W=6, H=4, LT=10, FT=7;   // active W x H in an LT x FT raster

    reg [1:0] orient=0; reg base=0;
    wire flip_native, hdmi_rotate, hdmi_rotate_ccw;
    na1_board_presentation bp(.orient(orient),.cfg_base_flip(base),.cfg_panel(8'd0),
        .joystick_0(32'd0),.joystick_1(32'd0),.joystick_2(32'd0),.joystick_3(32'd0),
        .flip_native(flip_native),.hdmi_rotate(hdmi_rotate),.hdmi_rotate_ccw(hdmi_rotate_ccw),
        .input_p1(),.input_p2(),.input_p3(),.input_p4(),.coin_1(),.coin_2(),.coin_3(),.coin_4());

    // ---- native raster: CE every 2 clk, colour = raw coordinates ------------
    reg ce=0; reg [7:0] hx=0, vy=0;
    reg [7:0] R=0,G=0,B=0; reg HS=0,VS=0,DE=0;
    always @(posedge clk) begin
        ce<=!ce;
        if(ce) begin
            if(hx==LT-1) begin hx<=0; vy<=(vy==FT-1)?8'd0:vy+1'b1; end else hx<=hx+1'b1;
            DE<=(hx<W && vy<H);
            HS<=(hx==7||hx==8);
            VS<=(vy==5);
            // renderer flip = true 180 of the raw raster inside the active window
            R<= flip_native ? W-1-hx : hx;
            G<= flip_native ? H-1-vy : vy;
            B<=8'h33;
        end
    end
    wire CE_PIXEL = ce;   // registered outputs above change right after ce; sample on it

    wire no_rotate = !hdmi_rotate;
    wire video_rotated;
    wire FB_EN; wire [4:0] FB_FORMAT; wire [11:0] FB_WIDTH,FB_HEIGHT; wire [31:0] FB_BASE; wire [13:0] FB_STRIDE;
    wire DDRAM_CLK; wire [7:0] DDRAM_BURSTCNT; wire [28:0] DDRAM_ADDR; wire [63:0] DDRAM_DIN; wire [7:0] DDRAM_BE;
    wire DDRAM_WE, DDRAM_RD;
    screen_rotate sr(.CLK_VIDEO(clk),.CE_PIXEL(CE_PIXEL),.VGA_R(R),.VGA_G(G),.VGA_B(B),
        .VGA_HS(HS),.VGA_VS(VS),.VGA_DE(DE),
        .rotate_ccw(hdmi_rotate_ccw),.no_rotate(no_rotate),.flip(1'b0),.video_rotated(video_rotated),
        .FB_EN(FB_EN),.FB_FORMAT(FB_FORMAT),.FB_WIDTH(FB_WIDTH),.FB_HEIGHT(FB_HEIGHT),
        .FB_BASE(FB_BASE),.FB_STRIDE(FB_STRIDE),.FB_VBL(1'b0),.FB_LL(1'b0),
        .DDRAM_CLK(DDRAM_CLK),.DDRAM_BUSY(1'b0),.DDRAM_BURSTCNT(DDRAM_BURSTCNT),.DDRAM_ADDR(DDRAM_ADDR),
        .DDRAM_DIN(DDRAM_DIN),.DDRAM_BE(DDRAM_BE),.DDRAM_WE(DDRAM_WE),.DDRAM_RD(DDRAM_RD));

    // capture framebuffer writes (byte address within the buffer -> RGB0 word)
    reg [31:0] fb[0:1023];
    always @(posedge clk) if(sr.ram_wr) fb[sr.ram_addr[11:2]] <= sr.ram_data;

    // ---- expected pictures (all in raw-raster coordinates) ------------------
    // H(x,y): the board's Horizontal picture
    function automatic [15:0] Hpic(input integer x, input integer y, input bit b);
        Hpic = b ? {8'(H-1-y),8'(W-1-x)} : {8'(y),8'(x)};
    endfunction

    integer checks=0, errors=0;
    task check(input cond,input [8*140-1:0] msg);
        begin checks=checks+1; if(!cond) begin errors=errors+1; $display("FAIL: %0s",msg); end end
    endtask

    integer x,y,f;
    reg [15:0] got, exp;
    task run_mode(input bit b, input [1:0] o);
        begin
            base=b; orient=o;
            // let screen_rotate settle (sizes + fb_en need several frames)
            for(f=0;f<6;f=f+1) begin @(posedge VS); end
            for(x=0;x<1024;x=x+1) fb[x]=32'hxxxxxxxx;
            @(posedge VS); @(posedge VS);
            // native picture, sampled from one full frame of the raster
            // (the R/G the renderer model emits for every active pixel)
            check(flip_native==(b^(o==2'd3)),"flip_native = base ^ (orient==3)");
            for(y=0;y<H;y=y+1) for(x=0;x<W;x=x+1) begin
                got = flip_native ? {8'(H-1-y),8'(W-1-x)} : {8'(y),8'(x)};
                exp = (o==2'd3) ? Hpic(W-1-x,H-1-y,b) : Hpic(x,y,b);
                check(got==exp,"native picture (analog / Direct Video)");
            end
            if(o==2'd0 || o==2'd3) begin
                check(!hdmi_rotate && !FB_EN,"Horizontal/Flipped: no scaler rotation, HDMI = native");
            end else begin
                check(hdmi_rotate && FB_EN,"Vertical: scaler framebuffer rotation active");
                check(FB_WIDTH==H && FB_HEIGHT==W,"rotated framebuffer is H x W");
                for(y=0;y<W;y=y+1) for(x=0;x<H;x=x+1) begin
                    got = {fb[(y*FB_STRIDE+x*4)>>2][15:8], fb[(y*FB_STRIDE+x*4)>>2][7:0]};
                    // label "Vertical CCW" (01) = rotCCW(H); "Vertical CW" (10) = rotCW(H)
                    exp = (o==2'd1) ? Hpic(W-1-y, x, b) : Hpic(y, H-1-x, b);
                    check(got==exp, (o==2'd1) ? "HDMI Vertical CCW == H rotated 90 CCW" : "HDMI Vertical CW == H rotated 90 CW");
                    if(b) begin
                        // F/A: pre-fix HW-confirmed pictures, rotCW(raw) / rotCCW(raw)
                        exp = (o==2'd1) ? {8'(H-1-x),8'(y)} : {8'(x),8'(W-1-y)};
                        check(got==exp,"F/A Vertical HDMI picture unchanged from the HW-confirmed build");
                    end
                end
            end
            $display("  base_flip=%0d orient=%0d: flip_native=%0d hdmi_rotate=%0d rotate_ccw=%0d FB %0dx%0d  errors so far %0d",
                b,o,flip_native,hdmi_rotate,hdmi_rotate_ccw,FB_WIDTH,FB_HEIGHT,errors);
        end
    endtask

    integer bb, oo;
    initial begin
        for(bb=0;bb<2;bb=bb+1) for(oo=0;oo<4;oo=oo+1) run_mode(bb[0],oo[1:0]);
        if(errors) $fatal(1,"ORIENTATION: %0d of %0d checks failed",errors,checks);
        $display("PASS ORIENTATION TRUTH TABLE: %0d checks",checks);
        $finish;
    end
    initial begin #50000000; $fatal(1,"ORIENTATION timeout"); end
endmodule
