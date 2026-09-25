// M15D production SDRAM memory: every external-SDRAM client of the NA-1
// machine above one physical controller channel.
//
// Physical word map (byte address / 2). M29 widened the mask-ROM backing from
// 4 MiB to the full 8 MiB of the 68000 window and MAME's `maskrom` region, and
// relocated the writable regions above it (docs/M28A_RESEARCH.md section 3.2):
//   $000000-$0FFFFF  program ROM   (bytes $000000-$1FFFFF)  immutable
//   $100000-$4FFFFF  mask ROM      (bytes $200000-$9FFFFF)  immutable
//   $500000-$53FFFF  work/shared   (bytes $A00000-$A7FFFF)  writable, lanes
//   $540000-$55FFFF  character RAM (bytes $A80000-$ABFFFF)  writable, lanes
//   $560000-$57FFFF  reserved      (bytes $AC0000-$AFFFFF)
// The MCU BIOS rides the same index-0 stream at bytes $A00000-$A03FFF but is
// routed to the C69/C70 internal ROM port in NA1.sv, never stored in SDRAM.
// Work and character SDRAM are the only authoritative copies. The character
// prefetch client reads aligned four-word rows from the same character words.
// M20A: the C219 audio client reads aligned four-word rows of the work/shared
// words (its sample space is the 512 KiB work RAM, 68000 byte order) as an
// ordinary round-robin client behind the prefetch priority.
module na1_sdram_memory(
 input wire clk_sys,reset_runtime,reset_controller,
 // Immutable ROM (existing M13 CPU/blitter arbiter output) and IOCTL download.
 input wire rom_req,rom_image,input wire [21:0] rom_word_addr,
 output wire rom_ack,output wire [15:0] rom_rdata,
 input wire download_active,download_wr,input wire [15:0] download_index,
 input wire [26:0] download_addr,input wire [15:0] download_data,
 output wire download_wait,
 // Work/shared RAM: 262,144 x16, from the existing shared arbiter.
 input wire work_req,work_write,input wire [17:0] work_word_addr,
 input wire [15:0] work_wdata,input wire [1:0] work_byte_en,
 output wire work_ack,output wire [15:0] work_rdata,
 // Character RAM: 131,072 x16, from na1_gfx selector 2.
 input wire char_req,char_write,input wire [16:0] char_word_addr,
 input wire [15:0] char_wdata,input wire [1:0] char_byte_en,
 output wire char_ack,output wire [15:0] char_rdata,
 // Character prefetch: aligned four-word row read, highest runtime priority.
 input wire prefetch_req,input wire [14:0] prefetch_row,
 output wire prefetch_ack,output wire [63:0] prefetch_data,
 // M20A audio: aligned four-word row read of work RAM (row = word addr [17:2]).
 input wire audio_req,input wire [15:0] audio_row,
 output wire audio_ack,output wire [63:0] audio_data,
 // Physical controller channel.
 output wire phy_req,phy_rnw,output wire [25:0] phy_word_addr,
 output wire [15:0] phy_wdata,output wire [1:0] phy_byte_en,
 input wire phy_ready,input wire [63:0] phy_rdata,
 output wire phy_busy
);
 localparam ROM=0,WORK=1,CHAR=2,PREFETCH=3,AUDIO=4;
 localparam [25:0] WORK_BASE=26'h500000,CHAR_BASE=26'h540000;
 wire rom_mem_req,rom_mem_write,rom_mem_ack;
 wire [25:0] rom_mem_word_addr;wire [15:0] rom_mem_wdata,rom_mem_rdata;
 wire [1:0] rom_mem_byte_en;
 na1_rom_sdram_bridge rom_adapter(.clk_sys(clk_sys),.reset_runtime(reset_runtime),
  .rom_req(rom_req),.rom_image(rom_image),.rom_word_addr(rom_word_addr),
  .rom_ack(rom_ack),.rom_rdata(rom_rdata),.download_active(download_active),
  .download_wr(download_wr),.download_index(download_index),
  .download_addr(download_addr),.download_data(download_data),
  .download_wait(download_wait),.mem_req(rom_mem_req),.mem_write(rom_mem_write),
  .mem_word_addr(rom_mem_word_addr),.mem_wdata(rom_mem_wdata),
  .mem_byte_en(rom_mem_byte_en),.mem_ack(rom_mem_ack),.mem_rdata(rom_mem_rdata));
 wire [4:0] req={audio_req,prefetch_req,char_req,work_req,rom_mem_req};
 wire [4:0] write={1'b0,1'b0,char_write,work_write,rom_mem_write};
 wire [5*26-1:0] word_addr={WORK_BASE | {8'd0,audio_row,2'b00},
                            CHAR_BASE | {9'd0,prefetch_row,2'b00},
                            CHAR_BASE | {9'd0,char_word_addr},
                            WORK_BASE | {8'd0,work_word_addr},
                            rom_mem_word_addr};
 wire [5*16-1:0] wdata={16'd0,16'd0,char_wdata,work_wdata,rom_mem_wdata};
 wire [5*2-1:0] byte_en={2'b11,2'b11,char_byte_en,work_byte_en,rom_mem_byte_en};
 wire [4:0] ack;wire [5*16-1:0] rdata;
 assign rom_mem_ack=ack[ROM];assign rom_mem_rdata=rdata[ROM*16+:16];
 assign work_ack=ack[WORK];assign work_rdata=rdata[WORK*16+:16];
 assign char_ack=ack[CHAR];assign char_rdata=rdata[CHAR*16+:16];
 assign prefetch_ack=ack[PREFETCH];
 wire [63:0] burst_rdata,burst_rdata2;
 assign prefetch_data=prefetch_ack ? burst_rdata : 64'd0;
 assign audio_ack=ack[AUDIO];
 assign audio_data=audio_ack ? burst_rdata2 : 64'd0;
 // Download proceeds under machine reset; the backend is not reset then.
 na1_sdram_backend #(.CLIENTS(5),.PRIORITY(PREFETCH),.DOWNLOAD(ROM),.BURST2(AUDIO)) backend(
  .clk_sys(clk_sys),.reset(reset_runtime && !download_active),
  .reset_controller(reset_controller),.download_active(download_active),
  .req(req),.write(write),.word_addr(word_addr),.wdata(wdata),.byte_en(byte_en),
  .ack(ack),.rdata(rdata),.burst_rdata(burst_rdata),.burst_rdata2(burst_rdata2),
  .phy_req(phy_req),.phy_rnw(phy_rnw),.phy_word_addr(phy_word_addr),
  .phy_wdata(phy_wdata),.phy_byte_en(phy_byte_en),.phy_ready(phy_ready),
  .phy_rdata(phy_rdata),.phy_busy(phy_busy));
endmodule
