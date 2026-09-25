// Replaceable backend boundary. Shared RAM ports use 68000-visible word/lane
// representation; a future real C69 backend must adapt its own memory map and
// endian views here, separately from mailbox numeric-word semantics.
// No C69 local RAM, ports, timer, sound or speculative peripheral bus in M4.
// M16: STARTUP_ENABLE=1 adds the production C69-startup compatibility
// sequencer (na1_c69_startup): RAM clear, vector words, one-clock release.
// It owns the MCU shared-RAM port until done; the M4 helper follows.
// M18: INPUT_ENABLE=1 adds the production C69 input-service compatibility
// model (na1_c69_input_service): once per input_tick it rewrites the observed
// shared-RAM input block from the raw active-low P1/P2/P4/DSW bytes. Port
// ownership: startup sequencer > helper transaction in progress > input
// service; ownership only changes between transactions (see owner_helper).
// M20C: GENUINE_ENABLE=1 selects the genuine C69 backend (na1_c69: M37702
// core executing c69.bin, on-chip peripherals, NA-1 glue). It replaces the
// three bounded models above (which must then be disabled by their own
// parameters): the firmware itself owns the MCU shared-RAM port (via its own
// endian adapter), the numeric mailbox port, the C219 register port, the
// main-CPU release (P4 bit 3 -> the existing release path) and the input
// block. The only non-firmware write on the MCU port in this mode is the
// explicit $F60 compatibility shim: [MAME-CONFIRMED] namcona1's
// scanline_interrupt() at line 224 asserts MCU IRQ1 and then simulate_mcu()
// stores 0 into 68000 word $F60 (the "MCU ready" word F/A polls after
// posting its startup handshakes); the physical mechanism is [UNKNOWN]
// (docs/FA_HARDWARE_SPEC.md section 34). The shim takes the MCU port only
// between firmware transactions and returns it with a low request edge, so
// the arbiter always sees the held-request/level-ACK/withdraw contract.
module na1_mcu_interface #(parameter FA_HELPER_ENABLE=1,parameter STARTUP_ENABLE=0,
                           parameter INPUT_ENABLE=0,parameter GENUINE_ENABLE=0,
                           parameter C69_ROM_FILE="")(
 input wire clk_sys,reset,
 input wire irq0_request,input wire [15:0] irq0_wdata,
 input wire [1:0] irq0_byte_en,input wire [127:0] mailbox_state,
 // Explicit launch event, currently supplied only by the simulation fixture.
 // A replacement backend can provide the event after legitimate initialization.
 input wire backend_maincpu_release,output wire maincpu_reset_release,
 input wire cpu_req,cpu_write,input wire [17:0] cpu_word_addr,
 input wire [15:0] cpu_wdata,input wire [1:0] cpu_byte_en,
 output wire cpu_ack,output wire [15:0] cpu_rdata,
 output wire work_req,work_write,output wire [17:0] work_word_addr,
 output wire [15:0] work_wdata,output wire [1:0] work_byte_en,
 input wire work_ack,input wire [15:0] work_rdata,
 // Numeric mailbox-word interface (na1_m3_transport mcu_mailbox port). Driven
 // by the genuine C69 only; inactive for the bounded backends.
 output wire mailbox_req,mailbox_write,output wire [2:0] mailbox_slot,
 output wire [15:0] mailbox_wdata,output wire [1:0] mailbox_byte_en,
 input wire mailbox_ack,input wire [15:0] mailbox_rdata,
 output wire completion_event,output wire [1:0] completion_count,
 output wire helper_busy,
 // Compact observation of the second master's logical shared-memory transport.
 output wire mcu_req,mcu_write,output wire [17:0] mcu_word_addr,
 output wire [15:0] mcu_wdata,output wire [1:0] mcu_byte_en,
 output wire mcu_ack,output wire [15:0] mcu_rdata,
 // M16 startup observation
 output wire startup_active,startup_done,startup_release,
 // M18 raw inputs (active-low, as the C69 reads P7) and service period tick
 input wire input_tick,
 input wire [7:0] input_p1,input_p2,input_p3,input_p4,input_dsw,
 output wire input_active,output wire [15:0] input_periods,
 // M20C genuine C69: MCU clock enable, the line-224 event (IRQ1 + $F60 shim),
 // the c69.bin write port (index-0 MRA stream bytes $600000-$603FFF) and the
 // C219 register port towards na1_c219.
 input wire ce_mcu,
 input wire scanline_event,
 input wire rom_we,input wire [12:0] rom_waddr,input wire [15:0] rom_wdata,
 output wire c219_req,c219_write,output wire [8:0] c219_addr,output wire [7:0] c219_wdata,
 input wire c219_ack,input wire [7:0] c219_rdata,
 output wire genuine_release,   // the firmware's P4 bit-3 release (observation)
 output wire shim_write         // one clock per accepted $F60 shim write (observation)
);
 wire helper_req,helper_write;wire [17:0] helper_word_addr;
 wire [15:0] helper_wdata;wire [1:0] helper_byte_en;
 wire su_req,su_write;wire [17:0] su_word_addr;wire [15:0] su_wdata;wire [1:0] su_byte_en;
 generate if(STARTUP_ENABLE) begin: startup
  na1_c69_startup sequencer(.clk_sys(clk_sys),.reset(reset),
   .req(su_req),.write(su_write),.word_addr(su_word_addr),.wdata(su_wdata),
   .byte_en(su_byte_en),.ack(mcu_ack && startup_active),
   .cpu_release(startup_release),.active(startup_active),.done(startup_done));
 end else begin: no_startup
  assign su_req=0;assign su_write=0;assign su_word_addr=0;assign su_wdata=0;assign su_byte_en=0;
  assign startup_release=0;assign startup_active=0;assign startup_done=1;
 end endgenerate
 assign maincpu_reset_release=(backend_maincpu_release || startup_release || genuine_release) && !reset;
 // M18 input service: runs only after the startup sequencer is done and takes
 // the port whenever the helper is idle. The helper takes the port back only
 // between service transactions (svc_req low), never mid-request, so neither
 // master ever sees its held request cancelled by the mux.
 wire svc_req,svc_write;wire [17:0] svc_word_addr;wire [15:0] svc_wdata;wire [1:0] svc_byte_en;
 reg owner_helper=0;
 generate if(INPUT_ENABLE) begin: inputs
  na1_c69_input_service service(.clk_sys(clk_sys),.reset(reset),
   .enable(startup_done),.tick(input_tick),
   .p1_raw(input_p1),.p2_raw(input_p2),.p4_raw(input_p4),.dsw_raw(input_dsw),
   .req(svc_req),.write(svc_write),.word_addr(svc_word_addr),.wdata(svc_wdata),
   .byte_en(svc_byte_en),.ack(mcu_ack && !startup_active && !owner_helper),
   .active(input_active),.periods(input_periods));
 end else begin: no_inputs
  assign svc_req=0;assign svc_write=0;assign svc_word_addr=0;assign svc_wdata=0;assign svc_byte_en=0;
  assign input_active=0;assign input_periods=0;
 end endgenerate
 always @(posedge clk_sys) begin
  if(reset) owner_helper<=0;
  else if(!owner_helper && helper_req && !svc_req) owner_helper<=1;
  else if(owner_helper && !helper_busy) owner_helper<=0;
 end
 wire helper_owns=owner_helper || !INPUT_ENABLE;
 // Bounded backends' view of the MCU master port: the startup sequencer owns
 // it until done (the helper cannot trigger before the CPU runs); afterwards
 // the helper while it owns the port, otherwise the M18 input service.
 wire b_req=startup_active ? su_req : helper_owns ? helper_req : svc_req;
 wire b_write=startup_active ? su_write : helper_owns ? helper_write : svc_write;
 wire [17:0] b_word_addr=startup_active ? su_word_addr : helper_owns ? helper_word_addr : svc_word_addr;
 wire [15:0] b_wdata=startup_active ? su_wdata : helper_owns ? helper_wdata : svc_wdata;
 wire [1:0] b_byte_en=startup_active ? su_byte_en : helper_owns ? helper_byte_en : svc_byte_en;
 generate if(FA_HELPER_ENABLE) begin: fa
  na1_mcu_fa_helper helper(.clk_sys(clk_sys),.reset(reset),
   .irq0_request(irq0_request),.irq0_wdata(irq0_wdata),
   .irq0_byte_en(irq0_byte_en),.mailbox_state(mailbox_state),
   .req(helper_req),.write(helper_write),.word_addr(helper_word_addr),
   .wdata(helper_wdata),.byte_en(helper_byte_en),.ack(mcu_ack && !startup_active && helper_owns),.rdata(mcu_rdata),
   .completion_event(completion_event),.completion_count(completion_count),
   .busy(helper_busy));
 end else begin: null_backend
  assign helper_req=0;assign helper_write=0;assign helper_word_addr=0;
  assign helper_wdata=0;assign helper_byte_en=0;
  assign completion_event=0;assign completion_count=0;assign helper_busy=0;
 end endgenerate
 // ------------------------------------------------------------ M20C genuine C69
 wire g_req,g_write;wire [17:0] g_word_addr;wire [15:0] g_wdata;wire [1:0] g_byte_en;
 generate if(GENUINE_ENABLE) begin: genuine
  wire c_req,c_write;wire [17:0] c_word_addr;wire [15:0] c_wdata;wire [1:0] c_byte_en;
  wire c_ack;
  // M30 version-info shim ([MAME-COMPAT], not a hardware claim). Every NA-1/NA-2
  // game posts its MCU commands in shared byte $F72 (bit 7 = pending) and rings
  // the slot-4 doorbell; [MAME-CONFIRMED] the BIOS IRQ0 handler only runs its
  // $F72 dispatcher when mailbox slot 2 bits 7:6 are set, which no 68000 code
  // ever writes, so in MAME the dispatcher never runs for any game (the $F60
  // shim above compensates for the unanswered command 3). Knuckle Heads and
  // Numan Athletics additionally issue command 7 and then require the BIOS
  // header ("NSA-BIOS ver1.31") at shared $1000-$100F; MAME papers over this
  // with write_version_info() on a doorbell while $F72's high byte is 7. The
  // physical mechanism is [UNKNOWN] (docs/M30_IMPLEMENTATION.md section 4).
  // This is the same shim keyed on the same BUS STATE -- never on game
  // identity -- and the header is the first 8 words of whatever MCU BIOS the
  // MRA loaded, latched off the ROM write port (no firmware bytes in RTL).
  // Measured inert for every other target: F/A, Bakuretsu, Exvania, Super
  // World Court, Tinkle Pit and X-Day 2 never ring the doorbell with $F72 = 7;
  // Emeraldia does once, and injecting the header there is byte-for-byte
  // harmless in MAME (identical frames/KEYCUS/palette over 40 s).
  reg [15:0] bios_header[0:7];
  always @(posedge clk_sys) if(rom_we && rom_waddr[12:3]==10'd0) bios_header[rom_waddr[2:0]]<=rom_wdata;
  // $F72's high (68000-even) byte as last written by either master.
  reg [7:0] f72_hi=0;
  always @(posedge clk_sys)
   if(reset) f72_hi<=0;
   else if(work_req && work_write && work_ack && work_word_addr==18'h7b9 && work_byte_en[1])
    f72_hi<=work_wdata[15:8];
  // $F60 shim writer and port ownership. shim_pend: a frame write is owed;
  // ver_pend: the eight header words at $1000-$100F are owed (ver_idx next).
  // shim_owner: the shim holds the MCU port; gap: one forced-low request
  // clock around every ownership change and after every shim transaction so
  // the arbiter always observes a withdrawn request between transactions.
  // t_f60/t_idx describe the shim transaction; they only change while no shim
  // request is presented (ownership gap or between words), so a pend flag
  // rising mid-transaction can neither move the address nor be credited.
  reg shim_pend=0,ver_pend=0,shim_owner=0,gap=0,c_req_q=0;
  reg [2:0] ver_idx=0,t_idx=0;
  reg t_f60=0;
  wire any_pend=shim_pend || ver_pend;
  wire s_req=shim_owner && any_pend && !gap;
  assign shim_write=s_req && mcu_ack;
  always @(posedge clk_sys) begin
   gap<=0;c_req_q<=c_req;
   if(!s_req) begin t_f60<=shim_pend;t_idx<=ver_idx;end
   if(reset) begin shim_pend<=0;ver_pend<=0;ver_idx<=0;shim_owner<=0;c_req_q<=0;end
   else begin
    if(scanline_event) shim_pend<=1;
    if(irq0_request && f72_hi==8'h07) begin ver_pend<=1;ver_idx<=0;end
    if(!shim_owner) begin
     if(any_pend && !c_req && !c_req_q) begin shim_owner<=1;gap<=1;end
    end else begin
     if(s_req && mcu_ack) begin
      gap<=1;
      if(t_f60) shim_pend<=0;
      else if(!(irq0_request && f72_hi==8'h07)) begin
       ver_idx<=t_idx+3'd1;
       if(t_idx==3'd7) ver_pend<=0;
      end
     end
     else if(!any_pend) begin shim_owner<=0;gap<=1;end
    end
   end
  end
  assign c_ack=mcu_ack && !shim_owner && !gap;
  assign g_req=gap ? 1'b0 : shim_owner ? s_req : c_req;
  assign g_write=shim_owner ? 1'b1 : c_write;
  assign g_word_addr=!shim_owner ? c_word_addr : t_f60 ? 18'h7b0          // 68000 word $F60/2
                                               : {15'h100,t_idx};        // 68000 word ($1000+2i)/2
  assign g_wdata=!shim_owner ? c_wdata : t_f60 ? 16'd0 : bios_header[t_idx];
  assign g_byte_en=shim_owner ? 2'b11 : c_byte_en;
  na1_c69 #(.ROM_INIT_FILE(C69_ROM_FILE)) c69(.clk_sys(clk_sys),.reset(reset),.ce_mcu(ce_mcu),
   .rom_we(rom_we),.rom_waddr(rom_waddr),.rom_wdata(rom_wdata),
   .sh_req(c_req),.sh_write(c_write),.sh_word_addr(c_word_addr),.sh_wdata(c_wdata),.sh_byte_en(c_byte_en),
   .sh_ack(c_ack),.sh_rdata(mcu_rdata),
   .mb_req(mailbox_req),.mb_write(mailbox_write),.mb_slot(mailbox_slot),.mb_wdata(mailbox_wdata),.mb_byte_en(mailbox_byte_en),
   .mb_ack(mailbox_ack),.mb_rdata(mailbox_rdata),
   .c219_req(c219_req),.c219_write(c219_write),.c219_addr(c219_addr),.c219_wdata(c219_wdata),
   .c219_ack(c219_ack),.c219_rdata(c219_rdata),
   .maincpu_release(genuine_release),.irq0_in(irq0_request),.irq1_in(scanline_event),
   .in_p1(input_p1),.in_p2(input_p2),.in_p3(input_p3),.in_p4(input_p4),.in_dsw(input_dsw),
   .sim_force_valid(1'b0),.sim_force_line(5'd0),.sim_inject_only(1'b0),
   .instr_start(),.instr_count(),.cycle_count(),.overrun_count(),.cpu_stopped(),
   .bus_req(),.bus_we(),.bus_addr(),.bus_be(),.bus_wdata(),.bus_ack(),.bus_rdata());
 end else begin: no_genuine
  assign g_req=0;assign g_write=0;assign g_word_addr=0;assign g_wdata=0;assign g_byte_en=0;
  assign mailbox_req=0;assign mailbox_write=0;assign mailbox_slot=0;
  assign mailbox_wdata=0;assign mailbox_byte_en=0;
  assign c219_req=0;assign c219_write=0;assign c219_addr=0;assign c219_wdata=0;
  assign genuine_release=0;assign shim_write=0;
 end endgenerate
 assign mcu_req=GENUINE_ENABLE ? g_req : b_req;
 assign mcu_write=GENUINE_ENABLE ? g_write : b_write;
 assign mcu_word_addr=GENUINE_ENABLE ? g_word_addr : b_word_addr;
 assign mcu_wdata=GENUINE_ENABLE ? g_wdata : b_wdata;
 assign mcu_byte_en=GENUINE_ENABLE ? g_byte_en : b_byte_en;
 na1_shared_arbiter shared_ram(.*);
endmodule
