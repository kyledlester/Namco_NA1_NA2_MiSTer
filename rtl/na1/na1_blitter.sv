// M13 MAME-compatible sequential u16 copy. Addresses remain 32-bit until
// validation; there is no CPU-aperture wrap, decompression, busy register or IRQ.
//
// M29.1 `[HW-CONFIRMED defect, fixed]`. The original M13 policy was that an
// unqualified format or an out-of-range source/destination held FAULT *without*
// ACK. That is not what the hardware does, and it is not what MAME models:
// `transfer_dword()` logs "bad blt src/dest" and returns -1, and `blit()` then
// simply `return`s -- the transfer is ABANDONED and the 68000 carries on. Our
// held-request bus turns "no ACK" into a permanent stall of the CPU write to
// $EFFF18, i.e. the 68000 hangs forever while the C69/C219 keep playing music.
//
// Super World Court does exactly this: 24 times in a 31-second MAME run it
// issues a blit with source base $000000 and a NON-zero length (e.g.
// bank=$0003 src1=$00F1 n=$0080 from PC $C007B4). MAME abandons those; we hung.
// That is the observed "boots, sound plays, black/blue screen after Start".
//
// Two changes, both making us match MAME exactly:
//  1. A bad source or destination address ABANDONS the blit and completes the
//     CPU request. `fault` becomes a sticky diagnostic only -- it no longer
//     gates ACK.
//  2. `setup()` no longer has an unqualified case. MAME's default arms compute
//     `(64 - (format >> n)) << k`, which is <= 0 for large formats; its loop
//     then advances a row per word, because `offset(2) >= bytes_per_row` is
//     immediately true. A bytes_per_row of 2 reproduces that exactly, so every
//     format is now qualified and the format FAULT path is gone.
module na1_blitter(
 input wire clk_sys,reset,req,input wire [191:0] registers,
 output wire ack,output wire fault,
 output wire source_req,output wire [31:0] source_addr,
 input wire source_ack,input wire [15:0] source_data,
 output wire destination_req,output wire [31:0] destination_addr,
 output wire [15:0] destination_data,input wire destination_ack,
 output reg source_event=0,destination_event=0,complete_event=0,
 output wire [2:0] debug_state
);
 localparam IDLE=0,READ_WORD=1,READ_GAP=2,WRITE_WORD=3,WRITE_GAP=4,DONE=5;
 reg [2:0] state=IDLE;
 // Sticky for the duration of one request: this blit hit an address MAME would
 // have logged as bad and abandoned. Diagnostic only -- never gates ACK.
 reg fault_r=0;
 reg [31:0] src=0,dst=0,so=0,doff=0,swidth=0,dwidth=0,spitch=0,dpitch=0;
 reg [16:0] remaining=0;
 reg [15:0] data=0;
 wire [15:0] sf=registers[1*16+:16],df=registers[4*16+:16],bank=registers[6*16+:16];
 wire [15:0] length=registers[11*16+:16];
 wire [31:0] encoded_src={8'd0,registers[7*16+:8],registers[8*16+:16]};
 wire [31:0] encoded_dst={8'd0,registers[9*16+:8],registers[10*16+:16]};
 wire [31:0] initial_dst=encoded_dst<<1;
 // high 32 bits width, low 32 bits pitch; width zero is unqualified.
 function [63:0] setup;
  input [15:0] format,gfxbank;
  reg [31:0] b,p;
  begin
   b=0;p=0;
   if(gfxbank==3) begin
    case(format)
     16'h0001: begin b='h1000;p='h1000;end
     16'h0081: begin b='h20;p='h120;end
     // MAME: (64 - (format>>2)) << 3. When that is <= 0 its loop advances one
     // row per word, which bytes_per_row = 2 reproduces exactly.
     default: begin b=((format>>2)<64) ? (32'd64-{16'd0,format>>2})*8 : 32'd2;p='h200;end
    endcase
   end else case(format)
    16'h00bd: begin b=4;p='h120;end
    16'h008d: begin b=8;p='h120;end
    16'h0000: begin b='h10;p=0;end
    16'h0001: begin b='h1000;p='h1000;end
    16'h0401: begin b='h100;p='h900;end
    // MAME: (64 - (format>>5)) << 6, with the same <= 0 degeneracy.
    default: begin b=((format>>5)<64) ? (32'd64-{16'd0,format>>5})*64 : 32'd2;p='h1000;end
   endcase
   setup={b,p};
  end
 endfunction
 wire [63:0] source_format=setup(sf,bank),destination_format=setup(df,bank);
 assign source_addr=src+so;
 wire source_valid=(source_addr>=32'h400000 && source_addr<32'he00000) ||
                   (source_addr>=32'h1000 && source_addr<32'h80000);
 // Destination address and its range test are registers maintained alongside
 // dst/doff (written only in IDLE and WRITE_GAP, mirrored below), so they equal
 // dst+doff and its test on every cycle without the adder and compares sitting
 // in front of the fabric decode and the SDRAM backend's same-cycle grant
 // (M20C timing: that path was the last clk_sys failure). Simulation checks the
 // invariant every cycle (translate_off block at the end of the module).
 function dest_ok(input [31:0] a);
  dest_ok=(a>=32'hf00000 && a<32'hf02000) || (a>=32'hf40000 && a<32'hf80000) ||
          (a>=32'hff0000 && a<32'hffc000) || (a>=32'hfff000 && a<32'h1000000);
 endfunction
 reg [31:0] daddr_r=0;reg dvalid_r=0;
 wire [31:0] dst_init=initial_dst<32'hf00000 ? initial_dst+32'hf40000 : initial_dst;
 wire [31:0] daddr_line=dst+dpitch;      // next line: dst+dpitch, doff 0
 wire [31:0] daddr_step=daddr_r+32'd2;   // same line: dst+doff+2
 assign destination_addr=daddr_r;
 wire destination_valid=dvalid_r;
 assign source_req=!reset && req && state==READ_WORD && source_valid;
 assign destination_req=!reset && req && state==WRITE_WORD && destination_valid;
 assign destination_data=data;
 // M29.1: ACK on completion whether or not the blit was abandoned, exactly as
 // MAME's blit() returns to the CPU either way.
 assign ack=!reset && req && state==DONE;
 assign fault=!reset && req && fault_r;
 assign debug_state=state;
 always @(posedge clk_sys) begin
  source_event<=0;destination_event<=0;complete_event<=0;
  if(reset || !req) begin state<=IDLE;remaining<=0;fault_r<=0;end
  else case(state)
   IDLE: begin
    src<=encoded_src<<1;dst<=dst_init;daddr_r<=dst_init;dvalid_r<=dest_ok(dst_init);
    so<=0;doff<=0;remaining<={1'b0,length}+{16'd0,length[0]};
    swidth<=source_format[63:32];spitch<=source_format[31:0];
    dwidth<=destination_format[63:32];dpitch<=destination_format[31:0];
    fault_r<=0;
    // setup() always yields a non-zero width now, so the only way to abandon a
    // blit is a bad address, handled in READ_WORD/WRITE_WORD below.
    if(length==0) begin state<=DONE;complete_event<=1;end
    else state<=READ_WORD;
   end
   // MAME "bad blt src": abandon the transfer, complete the request.
   READ_WORD: if(!source_valid) begin fault_r<=1;state<=DONE;complete_event<=1;end
              else if(source_ack) begin data<=source_data;source_event<=1;state<=READ_GAP;end
   READ_GAP: state<=WRITE_WORD;
   // MAME "bad blit dest": abandon the transfer, complete the request.
   WRITE_WORD: if(!destination_valid) begin fault_r<=1;state<=DONE;complete_event<=1;end
               else if(destination_ack) begin destination_event<=1;state<=WRITE_GAP;end
   WRITE_GAP: begin
    if(remaining==2) begin state<=DONE;complete_event<=1;end
    else begin
     remaining<=remaining-17'd2;
     if(so+2>=swidth) begin src<=src+spitch;so<=0;end else so<=so+2;
     if(doff+2>=dwidth) begin dst<=daddr_line;doff<=0;daddr_r<=daddr_line;dvalid_r<=dest_ok(daddr_line);end
     else begin doff<=doff+2;daddr_r<=daddr_step;dvalid_r<=dest_ok(daddr_step);end
     state<=READ_WORD;
    end
   end
   DONE: ;
   default: state<=IDLE;
  endcase
 end
// synthesis translate_off
`ifndef SYNTHESIS
 // Invariant behind the registered destination: equal to the former
 // combinational dst+doff and its range predicate on every cycle.
 wire [31:0] dest_sum_chk=dst+doff;
 always @(posedge clk_sys) begin
  if(daddr_r!==dest_sum_chk || dvalid_r!==dest_ok(dest_sum_chk))
   $fatal(1,"na1_blitter: registered destination %08x/%0d differs from dst+doff %08x/%0d (state %0d)",
          daddr_r,dvalid_r,dest_sum_chk,dest_ok(dest_sum_chk),state);
 end
`endif
// synthesis translate_on
endmodule
