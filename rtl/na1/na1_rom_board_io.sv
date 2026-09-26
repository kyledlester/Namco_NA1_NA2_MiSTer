// M30 optional ROM-board I/O, selected by the runtime board record (byte 6
// bit 0, rtl/na1/na1_config.sv). This is BOARD hardware, not game identity:
// it describes a ROM PCB that fits an MSM6242 real-time clock and a
// printer/battery status port in the program-ROM window instead of a second
// EPROM pair. X-Day 2's M112 ROM board is the one known instance
// ([MAME-CONFIRMED] namcona1.cpp xday2_main_map, 0.289 / master):
//
//   $D00000, $D40000  lamp/flash writes             -> nopw in MAME. Ordinary
//                                                     ROM-region writes are
//                                                     already ignored by
//                                                     na1_memory, so nothing
//                                                     is needed here.
//   $D80001 (byte)    printer_r: returns 3          -> "--11 battery ok, any
//                                                     other setting causes ng";
//                                                     bits 5:4 printer status
//                                                     (0 = no error). Writes
//                                                     are ignored.
//   $DC0000-$DC001F   MSM6242 RTC, umask 0x00ff     -> register n at word n.
//
// Every other address in $C00000-$DFFFFF stays program ROM, exactly as MAME's
// base map declares, and blitter reads never see this module (MAME's blitter
// reads m_prgrom directly).
//
// MSM6242 model = MAME's msm6242_device, not a datasheet superset:
//   * time registers S1..W are READ-ONLY (MAME ignores writes to them) and come
//     from MiSTer's RTC (hps_io `RTC`, MSM6242B layout: BCD sec/min/hour/date/
//     month/year, weekday 0 = Sunday), which Main_MiSTer sends once per 60 s;
//     between updates the seconds/minutes/hours advance locally from clk_sys.
//     A day rollover between two updates is corrected by the next update
//     (<= 60 s) rather than modelled here. [IMPLEMENTATION]
//   * hours follow CF bit 2 (1 = 24-hour); in 12-hour mode MAME returns
//     1..12 with PM in H10 bit 2.
//   * W returns the weekday 0..6 (MAME day_of_week - 1, Sunday = 0).
//   * CD = (data & 9) on write, BUSY/IRQ-flag read 0 (the IRQ output is not
//     connected on this board and X-Day 2 never unmasks it); CE = data & $F;
//     CF follows MAME's RESET 1->0 rule for the 24/12 bit. Power-on/reset
//     values CD=0, CE=6, CF=4 as MAME's device_start.
// Without the record bit the module is fully transparent (no address is
// claimed), so every other board's program ROM is untouched.
module na1_rom_board_io #(parameter integer CLK_HZ=100_226_000)( // NA1.sv passes SYS_HZ
 input wire clk_sys,reset,enable,
 input wire [64:0] rtc,
 // CPU program/mask-ROM read port from na1 (upstream)...
 input wire rom_req,rom_image,input wire [21:0] rom_word_addr,
 output wire rom_ack,output wire [15:0] rom_rdata,
 // ...and towards the ROM backend (same held-request/level-ack contract)
 output wire down_req,input wire down_ack,input wire [15:0] down_rdata,
 // CPU write observation (ROM-region writes are acknowledged by na1_memory)
 input wire cpu_req,cpu_write,input wire [23:0] cpu_addr,input wire [15:0] cpu_wdata,
 input wire [1:0] cpu_byte_en,input wire cpu_ack
);
 // Program-image word address = cpu_addr[20:1] (na1_memory).
 wire status_hit=rom_word_addr==22'h0c0000;          // $D80000/1
 wire rtc_hit=rom_word_addr[21:4]==18'h0e000;         // $DC0000-$DC001F
 wire hit=enable && !rom_image && (status_hit || rtc_hit);
 assign down_req=rom_req && !hit;

 // ---- MSM6242 time base -------------------------------------------------------
 reg [7:0] sec=0,min=0,hour=0,date=0,month=0,year=0;reg [3:0] wday=0;
 reg rtc_tog=0;reg [26:0] tick=0;
 function [7:0] bcd_inc(input [7:0] v);
  bcd_inc=(v[3:0]==4'd9) ? {v[7:4]+4'd1,4'd0} : {v[7:4],v[3:0]+4'd1};
 endfunction
 always @(posedge clk_sys) begin
  rtc_tog<=rtc[64];
  if(rtc[64]!=rtc_tog) begin
   sec<=rtc[7:0];min<=rtc[15:8];hour<=rtc[23:16];date<=rtc[31:24];
   month<=rtc[39:32];year<=rtc[47:40];wday<=rtc[51:48];tick<=0;
  end else if(tick==CLK_HZ-1) begin
   tick<=0;
   if(sec!=8'h59) sec<=bcd_inc(sec);
   else begin
    sec<=0;
    if(min!=8'h59) min<=bcd_inc(min);
    else begin min<=0;hour<=(hour==8'h23) ? 8'h00 : bcd_inc(hour);end
   end
  end else tick<=tick+1'b1;
 end

 // ---- control registers ---------------------------------------------------------
 reg [3:0] cd=0,ce=4'h6,cf=4'h4;
 reg wr_seen=0;
 wire rtc_wr=enable && cpu_req && cpu_write && cpu_ack && cpu_byte_en[0] &&
             cpu_addr[23:5]==19'h6e000;               // $DC0000-$DC001F
 always @(posedge clk_sys) begin
  wr_seen<=rtc_wr;
  if(reset) begin cd<=0;ce<=4'h6;cf<=4'h4;end
  else if(rtc_wr && !wr_seen) case(cpu_addr[4:1])
   4'hd: cd<=cpu_wdata[3:0] & 4'h9;
   4'he: ce<=cpu_wdata[3:0];
   4'hf: if(!cpu_wdata[0] && cf[0]) cf<={cf[3],cpu_wdata[2],cf[1:0]};
         else cf<={cpu_wdata[3],cf[2],cpu_wdata[1:0]};
   default: ;                                       // time registers: read-only
  endcase
 end

 // ---- read side --------------------------------------------------------------------
 // 12-hour conversion exactly as MAME (hour from the BCD register).
 wire [4:0] hbin=hour[7:4]*4'd10+hour[3:0];
 wire pm=hbin>=5'd12;
 wire [4:0] h12m=pm ? hbin-5'd12 : hbin;
 wire [4:0] h12=(h12m==5'd0) ? 5'd12 : h12m;
 wire [4:0] hsel=cf[2] ? hbin : h12;
 wire [3:0] h1=(hsel>=5'd20) ? hsel-5'd20 : (hsel>=5'd10) ? hsel-5'd10 : hsel;
 wire [3:0] h10=((hsel>=5'd20) ? 4'd2 : (hsel>=5'd10) ? 4'd1 : 4'd0) | ((!cf[2] && pm) ? 4'd4 : 4'd0);
 reg [3:0] nib;
 always @* case(rom_word_addr[3:0])
  4'h0: nib=sec[3:0];   4'h1: nib=sec[7:4];
  4'h2: nib=min[3:0];   4'h3: nib=min[7:4];
  4'h4: nib=h1;         4'h5: nib=h10;
  4'h6: nib=date[3:0];  4'h7: nib=date[7:4];
  4'h8: nib=month[3:0]; 4'h9: nib=month[7:4];
  4'ha: nib=year[3:0];  4'hb: nib=year[7:4];
  4'hc: nib=wday;       4'hd: nib=cd;
  4'he: nib=ce;         default: nib=cf;
 endcase
 reg io_ack=0;reg [15:0] io_rdata=0;
 always @(posedge clk_sys) begin
  io_ack<=rom_req && hit && !reset;
  io_rdata<=status_hit ? 16'h0003 : {12'd0,nib};
 end
 assign rom_ack=hit ? (io_ack && rom_req) : down_ack;
 assign rom_rdata=hit ? io_rdata : down_rdata;
endmodule
