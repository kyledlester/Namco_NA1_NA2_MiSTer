// Namco NA-1/NA-2 MiSTer core -- DDR3 fast ROM loading.
// Ported from the NB-2 core (nb2_fastload.sv); same Main_MiSTer protocol.
//
// With `address="0x30000000"` on the MRA's index-0 <rom>, Main_MiSTer (support/arcade/mra_loader.cpp rom_finish)
// does not stream the ROM through ioctl: it starts the download with the stream length in ioctl_addr
// (user_io_set_download(1, len)), copies the whole assembled stream into DDR3 at that address (shmem_put), and
// ends the download -- no ioctl_wr in between. Older firmware ignores the attribute and streams as before; both
// paths deliver the same bytes.
//
// This block sits between hps_io and the core. Normal downloads pass straight through. A fast download (index
// INDEX starting with ioctl_addr != 0) passes through as an empty download; when it ends, the block replays the
// whole stream from DDR3 into the core's ioctl inputs exactly as hps_io would deliver it (WIDE = 1: dout[7:0] =
// byte 2k, dout[15:8] = byte 2k+1, one word per write, never two in consecutive clocks, the next only while
// c_wait is low), keeping c_download high without a gap so the machine stays in reset. The SDRAM ROM bridge, the
// C69/C70 BIOS capture ($A00000-$A03FFF) and the ROM cache flush therefore work unchanged.
// While the replay runs, h_wait is held high, so a download Main starts meanwhile (the saved NVRAM, index 1)
// waits and then passes through normally instead of being lost.
//
// DDR3: the only other master is screen_rotate (framebuffer 0x24000000-0x25FFFFFF, writes only). The block
// takes the port only while screen_rotate has no request up (others_idle), presents BUSY to it while it owns
// the port, and gives the port back whenever its line FIFO is full and no read is outstanding.
module na1_fastload #(
    parameter [15:0] INDEX  = 16'd0,
    parameter [28:0] BASE_W = 29'h6000000,      // DDR3 64-bit word of stream offset 0 (byte 0x30000000)
    parameter int    DEPTH  = 8                 // 8-byte lines in flight + buffered
) (
    input  wire        clk,
    input  wire        init,

    // hps_io side
    input  wire        h_download,
    input  wire [15:0] h_index,
    input  wire        h_wr,
    input  wire [26:0] h_addr,
    input  wire [15:0] h_dout,
    output wire        h_wait,

    // core side (what the core's ioctl consumers see)
    output wire        c_download,
    output wire [15:0] c_index,
    output wire        c_wr,
    output wire [26:0] c_addr,
    output wire [15:0] c_dout,
    input  wire        c_wait,

    // DDR3 command port while own = 1 (BURSTCNT 1, read only)
    input  wire        others_idle,
    output reg         own = 1'b0,
    output reg         d_rd = 1'b0,
    output reg  [28:0] d_addr = '0,
    input  wire        d_busy,
    input  wire [63:0] d_dout,
    input  wire        d_dout_ready,

    output wire        active,                  // a fast download or its replay is in progress
    output reg  [15:0] loads = '0               // fast loads completed (diagnostics)
);
    // ------------------------------------------------------------------ detect
    reg        dl_q = 1'b0;
    reg        fast = 1'b0;                     // the current index-INDEX download is a fast one
    reg [26:0] len = '0;                        // stream bytes
    reg        replay = 1'b0;
    always @(posedge clk) dl_q <= h_download;
    wire dl_rise = h_download && !dl_q;
    wire dl_fall = !h_download && dl_q;
    wire detect  = dl_rise && h_index == INDEX && h_addr != 27'd0;

    // ------------------------------------------------------------------ fetch (DDR3 -> line FIFO)
    localparam int CW = $clog2(DEPTH + 1);
    (* ramstyle = "logic" *) reg [63:0] fifo [0:DEPTH-1];
    reg [$clog2(DEPTH)-1:0] f_wr = '0, f_rd = '0;
    reg [CW-1:0] f_cnt = '0;                    // lines buffered
    reg [CW-1:0] f_out = '0;                    // reads issued, data not yet returned
    reg [26:0]   fetch_a = '0;                  // next line to fetch (byte offset, 8-aligned)
    wire fetch_more = fetch_a < len;
    wire room  = (f_cnt + f_out) < DEPTH;
    wire issue = replay && own && !d_rd && fetch_more && room;
    wire got   = d_dout_ready && own && f_out != 0;
    wire pop;

    always @(posedge clk) begin
        if (d_rd && !d_busy) d_rd <= 1'b0;
        if (issue) begin
            d_rd    <= 1'b1;
            d_addr  <= BASE_W + {5'd0, fetch_a[26:3]};
            fetch_a <= fetch_a + 27'd8;
        end
        if (got) begin
            fifo[f_wr] <= d_dout;
            f_wr <= f_wr + 1'd1;
        end
        f_out <= f_out + (issue ? 1'd1 : 1'd0) - (got ? 1'd1 : 1'd0);
        f_cnt <= f_cnt + (got ? 1'd1 : 1'd0) - (pop ? 1'd1 : 1'd0);
        if (pop) f_rd <= f_rd + 1'd1;
        // Port ownership: take it when screen_rotate is idle and there is room; give it back when nothing is
        // outstanding and either the FIFO is full or every line has been fetched.
        if (!own) begin
            if (replay && fetch_more && room && others_idle) own <= 1'b1;
        end else if (f_out == 0 && !d_rd && !issue && (!room || !fetch_more || !replay)) own <= 1'b0;
        if (dl_fall && fast) begin
            fetch_a <= '0; f_wr <= '0; f_rd <= '0; f_cnt <= '0; f_out <= '0;
        end
        if (init) begin own <= 1'b0; d_rd <= 1'b0; f_out <= '0; f_cnt <= '0; end
    end

    // ------------------------------------------------------------------ replay (line FIFO -> core ioctl)
    reg  [26:0] rp_a = '0;                      // next word to replay
    reg  [1:0]  rp_j = '0;                      // word within the head line
    reg         wr = 1'b0;
    reg  [26:0] wr_a = '0;
    reg  [15:0] wr_d = '0;
    wire [63:0] head = fifo[f_rd];
    wire        can  = replay && (f_cnt != 0) && !wr && !c_wait;
    wire        last_word = rp_a + 27'd2 >= len;
    assign pop = can && (rp_j == 2'd3 || last_word);

    always @(posedge clk) begin
        wr <= 1'b0;
        if (can) begin
            wr   <= 1'b1;
            wr_a <= rp_a;
            wr_d <= head[16*rp_j +: 16];
            rp_a <= rp_a + 27'd2;
            rp_j <= rp_j + 2'd1;
            if (last_word) begin replay <= 1'b0; loads <= loads + 16'd1; end
        end
        if (detect) begin fast <= 1'b1; len <= h_addr; end
        if (dl_fall && fast) begin
            replay <= 1'b1; rp_a <= '0; rp_j <= '0;
            fast <= 1'b0;
        end
        if (init) begin fast <= 1'b0; replay <= 1'b0; end
    end

    // The core stays in download until the last replayed write has been answered.
    reg tail_wait = 1'b0;
    always @(posedge clk) tail_wait <= !init && (replay || wr || (tail_wait && c_wait));
    wire replaying = replay || wr || tail_wait;
    assign active = fast || detect || replaying;

    assign c_download = h_download || dl_q || replaying;
    assign c_index    = replaying ? INDEX : h_index;
    assign c_wr       = replaying ? wr    : (fast || detect) ? 1'b0  : h_wr;
    assign c_addr     = replaying ? wr_a  : (fast || detect) ? 27'd0 : h_addr;
    assign c_dout     = replaying ? wr_d  : h_dout;
    assign h_wait     = replaying ? 1'b1  : (fast || detect) ? 1'b0  : c_wait;
endmodule
