// M20B Namco C69: M37702 core + on-chip peripherals + internal ROM/RAM + the
// NA-1 board glue, behind three external client ports (shared work RAM,
// mailbox, C219) that use the project's held-request / level-ACK contract.
//
// MCU address map [MAME-CONFIRMED] (m37702m2_device::map + namcona1_mcu_map):
//   $000000-$00007F SFRs            $000800-$000FFF mailbox (slot = addr[3:1])
//   $000080-$00027F internal RAM    $001000-$001FFF C219 (byte offset & $1FF, reg = offset ^ 1)
//   $003000-$00AFFF local RAM 32K   $002000-$002FFF shared RAM page-0 mirror
//   $00C000-$00FFFF internal ROM    $200000-$27FFFF shared work RAM (512 KiB)
//   anything else reads 0, writes are ignored (MAME unmapped).
// Shared RAM is presented in 68000 word/lane form: MCU lane 0 (even byte,
// bits 7:0) <-> 68000 upper byte (byte_en[1], rdata[15:8]) and lane 1 <-> the
// lower byte, i.e. na1mcu_shared_r/w's swapendian with byte-offset
// correspondence. Mailbox numeric words are not swapped (MCU lane 1 = bits
// 15:8). A 16-bit MCU access to the C219 becomes two 8-bit register accesses,
// lane 0 first, as MAME's memory system splits it onto c219_le_w.
// Board glue [MAME-CONFIRMED] namcona1.cpp: P4 bit 3 rising edge releases the
// 68000 (maincpu_release pulse); P5 reads back its written bits with bit 0 :=
// bit 1; P6 input 0; P7 = {P4, DSW, P1, P2}[P6[7:5]] while P6 bit 7 = 0 else
// $FF; P8 reads back; ports P0-P3 are unbound in MAME (read $FF); A-D inputs
// are $FFFF (portana_r of F/A's unused P3; physical values [UNKNOWN]).
// IRQ0 = canonical mailbox slot-4 write (transport pulse), IRQ1 = frame event
// at line 224 (scanline_interrupt), IRQ2 unused.
module na1_c69 #(parameter ROM_INIT_FILE="")(
 input wire clk_sys,reset,ce_mcu,
 // internal ROM write port (M20C: MRA stream words $600000-$603FFF)
 input wire rom_we,input wire [12:0] rom_waddr,input wire [15:0] rom_wdata,
 // shared work RAM client (68000 word/lane form, na1_shared_arbiter MCU port)
 output wire sh_req,sh_write,output wire [17:0] sh_word_addr,
 output wire [15:0] sh_wdata,output wire [1:0] sh_byte_en,
 input wire sh_ack,input wire [15:0] sh_rdata,
 // mailbox client (na1_m3_transport mcu_mailbox port)
 output wire mb_req,mb_write,output wire [2:0] mb_slot,
 output wire [15:0] mb_wdata,output wire [1:0] mb_byte_en,
 input wire mb_ack,input wire [15:0] mb_rdata,
 // C219 register port (na1_c219)
 output reg c219_req=0,output reg c219_write=0,output reg [8:0] c219_addr=0,output reg [7:0] c219_wdata=0,
 input wire c219_ack,input wire [7:0] c219_rdata,
 // board
 output reg maincpu_release=0,
 input wire irq0_in,irq1_in,
 input wire [7:0] in_p1,in_p2,in_p3,in_p4,in_dsw,
 // bench injection / observation
 input wire sim_force_valid,input wire [4:0] sim_force_line,input wire sim_inject_only,
 output wire instr_start,output wire [31:0] instr_count,cycle_count,output wire [15:0] overrun_count,
 output wire cpu_stopped,
 output wire bus_req,bus_we,output wire [23:0] bus_addr,output wire [1:0] bus_be,
 output wire [15:0] bus_wdata,output wire bus_ack,output wire [15:0] bus_rdata
);
 // ------------------------------------------------------------ core
 wire irq_take;wire [4:0] irq_line;wire [2:0] irq_pri;wire irq_ack;wire [4:0] irq_ack_line;
 wire flag_i;wire [2:0] ipl;wire instr_commit;
 na1_m37702 cpu(.clk_sys(clk_sys),.reset(reset),.ce_mcu(ce_mcu),
  .bus_req(bus_req),.bus_we(bus_we),.bus_addr(bus_addr),.bus_be(bus_be),.bus_wdata(bus_wdata),
  .bus_ack(bus_ack),.bus_rdata(bus_rdata),
  .irq_take(irq_take),.irq_line(irq_line),.irq_pri(irq_pri),.irq_ack(irq_ack),.irq_ack_line(irq_ack_line),
  .flag_i_out(flag_i),.ipl_out(ipl),.instr_commit(instr_commit),
  .instr_start(instr_start),.instr_count(instr_count),.cycle_count(cycle_count),.overrun_count(overrun_count),.stopped(cpu_stopped));
 // ------------------------------------------------------------ address decode
 wire sel_sfr  = bus_addr[23:7]==17'd0;
 wire sel_iram = bus_addr>=24'h000080 && bus_addr<=24'h00027f;
 wire sel_mbox = bus_addr[23:11]==13'h001;                 // $0800-$0FFF
 wire sel_c219 = bus_addr[23:12]==12'h001;                 // $1000-$1FFF
 wire sel_shm  = bus_addr[23:12]==12'h002;                 // $2000-$2FFF mirror
 wire sel_lram = bus_addr>=24'h003000 && bus_addr<=24'h00afff;
 wire sel_rom  = bus_addr[23:14]==10'h003;                 // $C000-$FFFF
 wire sel_shr  = bus_addr[23:19]==5'b00100;                // $200000-$27FFFF
 wire sel_none = !(sel_sfr|sel_iram|sel_mbox|sel_c219|sel_shm|sel_lram|sel_rom|sel_shr);
 // ------------------------------------------------------------ on-chip memories
 // internal RAM 256 x 16 (byte lanes), local RAM 16384 x 16, ROM 8192 x 16
 (* ramstyle = "M10K, no_rw_check" *) reg [1:0][7:0] iram[0:255];
 (* ramstyle = "M10K, no_rw_check" *) reg [1:0][7:0] lram[0:16383];
 (* ramstyle = "M10K, no_rw_check" *) reg [15:0] rom[0:8191];
 reg [15:0] iram_q=0,lram_q=0,rom_q=0;
// synthesis translate_off
`ifndef SYNTHESIS
 integer ii;
 initial begin
  // [IMPLEMENTATION] MAME's RAM is zero-initialised; the physical power-up
  // contents are [UNKNOWN]. Simulation only.
  for(ii=0;ii<256;ii=ii+1) iram[ii]=16'd0;
  for(ii=0;ii<16384;ii=ii+1) lram[ii]=16'd0;
  for(ii=0;ii<8192;ii=ii+1) rom[ii]=16'd0;
  if(ROM_INIT_FILE!="") $readmemh(ROM_INIT_FILE,rom);
 end
`endif
// synthesis translate_on
 wire [7:0] iram_a=bus_addr[8:1]-8'h40;      // ($80..$27F) / 2 - $40
 wire [13:0] lram_a=bus_addr[14:1]-14'h1800; // ($3000..$AFFF) / 2 - $1800
 // internal targets answer one cycle after the request (registered read)
 reg int_ack=0;
 wire int_sel=sel_sfr ? 1'b0 : (sel_iram|sel_lram|sel_rom|sel_none);
 always @(posedge clk_sys) begin
  if(rom_we) rom[rom_waddr]<=rom_wdata;
  rom_q<=rom[bus_addr[13:1]];
  if(bus_req && bus_we && sel_iram && !int_ack) begin
   if(bus_be[1]) iram[iram_a][1]<=bus_wdata[15:8];
   if(bus_be[0]) iram[iram_a][0]<=bus_wdata[7:0];
  end
  iram_q<=iram[iram_a];
  if(bus_req && bus_we && sel_lram && !int_ack) begin
   if(bus_be[1]) lram[lram_a][1]<=bus_wdata[15:8];
   if(bus_be[0]) lram[lram_a][0]<=bus_wdata[7:0];
  end
  lram_q<=lram[lram_a];
  int_ack<=bus_req && int_sel && !int_ack;
 end
 // ------------------------------------------------------------ SFR block + board glue
 wire sfr_ack;wire [15:0] sfr_rdata;
 wire [7:0] port_in [0:8];wire [7:0] port_reg [0:8];wire [7:0] port_dir [0:8];wire [8:0] port_wr;
 // M29: P3 is NOT part of the P7 multiplexer -- the NA-1 board wires the third
 // player's panel to the M37702's A-D converter inputs, one port bit per
 // channel. `[MAME-CONFIRMED]` namcona1.cpp wires an<N>_cb to
 // portana_r<Bit>, which returns $FFFF when the P3 bit is SET (not pressed)
 // and $0000 when it is clear (pressed):
 //   channel 0->bit 6, 1->bit 5, 2->bit 4, 3->bit 0,
 //   channel 4->bit 1, 5->bit 2, 6->bit 3, 7->bit 7
 // in_p3 is already active low, so a pressed button is a 0 bit and the
 // channel reads $0000 -- the same polarity convention as in_p1/in_p2/in_p4.
 // Games with no third player simply drive in_p3 all-ones and every channel
 // reads $FFFF, which is exactly what this module did before M29.
 wire [15:0] an_in [0:7];
 localparam [23:0] AN_BIT = {3'd7,3'd3,3'd2,3'd1,3'd0,3'd4,3'd5,3'd6}; // ch7..ch0
 genvar g;
 generate for(g=0;g<8;g=g+1) begin: an
  assign an_in[g] = in_p3[AN_BIT[3*g+:3]] ? 16'hffff : 16'h0000;
 end endgenerate
 // MAME driver state written by the port callbacks (data & dir)
 reg [7:0] mcu_port4=0,mcu_port5=8'h01,mcu_port6=0,mcu_port8=0;
 wire [7:0] p7_mux= mcu_port6[7] ? 8'hff :
                    (mcu_port6[6:5]==2'd0) ? in_p4 : (mcu_port6[6:5]==2'd1) ? in_dsw :
                    (mcu_port6[6:5]==2'd2) ? in_p1 : in_p2;
 assign port_in[0]=8'hff;assign port_in[1]=8'hff;assign port_in[2]=8'hff;assign port_in[3]=8'hff;
 assign port_in[4]=mcu_port4;assign port_in[5]=mcu_port5;assign port_in[6]=8'h00;
 assign port_in[7]=p7_mux;assign port_in[8]=mcu_port8;
 always @(posedge clk_sys) begin
  maincpu_release<=0;
  if(reset) begin mcu_port4<=0;mcu_port5<=8'h01;mcu_port6<=0;mcu_port8<=0;end
  else begin
   if(port_wr[4]) begin
    if((port_reg[4]&port_dir[4])&8'h08 && !(mcu_port4&8'h08)) maincpu_release<=1;
    mcu_port4<=port_reg[4]&port_dir[4];
   end
   if(port_wr[5]) mcu_port5<=((port_reg[5]&port_dir[5])&8'hfe)|{7'd0,port_reg[5][1]&port_dir[5][1]}; // bit 0 := bit 1
   if(port_wr[6]) mcu_port6<=port_reg[6]&port_dir[6];
   if(port_wr[8]) mcu_port8<=port_reg[8]&port_dir[8];
  end
 end
 na1_c69_sfr sfr(.clk_sys(clk_sys),.reset(reset),.ce_mcu(ce_mcu),
  .req(bus_req && sel_sfr),.we(bus_we),.addr(bus_addr[6:0]),.be(bus_be),.wdata(bus_wdata),
  .ack(sfr_ack),.rdata(sfr_rdata),.instr_commit(instr_commit),
  .port_in(port_in),.port_reg(port_reg),.port_dir(port_dir),.port_wr(port_wr),.an_in(an_in),
  .irq0_in(irq0_in),.irq1_in(irq1_in),.irq2_in(1'b0),
  .flag_i(flag_i),.ipl(ipl),.irq_take(irq_take),.irq_line(irq_line),.irq_pri(irq_pri),
  .irq_ack(irq_ack),.irq_ack_line(irq_ack_line),
  .sim_force_valid(sim_force_valid),.sim_force_line(sim_force_line),.sim_inject_only(sim_inject_only));
 // ------------------------------------------------------------ external clients
 // shared RAM: byte-swapped lanes/data (68000 view), mirror page uses word addr 0..$7FF
 assign sh_req=bus_req && (sel_shm|sel_shr);
 assign sh_write=bus_we;
 assign sh_word_addr=sel_shr ? bus_addr[18:1] : {7'd0,bus_addr[11:1]};
 assign sh_wdata={bus_wdata[7:0],bus_wdata[15:8]};
 assign sh_byte_en={bus_be[0],bus_be[1]};
 // mailbox: numeric words, lanes unswapped
 assign mb_req=bus_req && sel_mbox;
 assign mb_write=bus_we;
 assign mb_slot=bus_addr[3:1];
 assign mb_wdata=bus_wdata;
 assign mb_byte_en=bus_be;
 // C219: one register access per active lane, lane 0 first
 reg c_phase=0,c_done=0;reg [15:0] c_rdata=0;
 wire [8:0] c_off={bus_addr[8:1],1'b0};
 always @(posedge clk_sys) begin
  if(reset || !(bus_req && sel_c219)) begin c219_req<=0;c_phase<=0;c_done<=0;end
  else if(!c_done) begin
   if(!c219_req) begin
    if(!c_phase && bus_be[0]) begin c219_req<=1;c219_write<=bus_we;c219_addr<=c_off^9'd1;c219_wdata<=bus_wdata[7:0];end
    else if(!c_phase) c_phase<=1;
    else if(bus_be[1]) begin c219_req<=1;c219_write<=bus_we;c219_addr<=(c_off+9'd1)^9'd1;c219_wdata<=bus_wdata[15:8];end
    else c_done<=1;
   end else if(c219_ack) begin
    c219_req<=0;
    if(!c_phase) begin c_rdata[7:0]<=c219_rdata;c_phase<=1;end
    else begin c_rdata[15:8]<=c219_rdata;c_done<=1;end
   end
  end
 end
 // ------------------------------------------------------------ response mux
 assign bus_ack= sel_sfr ? sfr_ack : (sel_shm|sel_shr) ? sh_ack : sel_mbox ? mb_ack : sel_c219 ? c_done : int_ack;
 assign bus_rdata= sel_sfr ? sfr_rdata : (sel_shm|sel_shr) ? {sh_rdata[7:0],sh_rdata[15:8]} :
                   sel_mbox ? mb_rdata : sel_c219 ? c_rdata : sel_iram ? iram_q : sel_lram ? lram_q : sel_rom ? rom_q : 16'd0;
endmodule
