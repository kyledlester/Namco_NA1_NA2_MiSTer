// M20A Namco C219 PCM engine (16 voices) — production module.
//
// Behavioural contract [MAME-CONFIRMED] = MAME 0.289 src/devices/sound/c140.cpp
// (c219_device). Everything not marked otherwise reproduces that model exactly;
// physical C219 behaviour is [UNKNOWN] beyond what MAME encodes. See
// docs/M20A_IMPLEMENTATION.md for the arithmetic derivation.
//
// Register port: native C140 byte offsets $000-$1FF (the M37702's little-endian
// offset^1 swap belongs to the MCU bus adapter, not here). A write is accepted
// (reg_ack, same cycle) unless the sequencer is currently processing the
// addressed voice, in which case the held request waits [IMPLEMENTATION].
// A read is acknowledged one cycle after the request and held until the
// request is withdrawn; voice register +5 returns {1'b0,key,reg[5:0]}.
//
// Sample memory: the 512 KiB shared work RAM in 68000 byte order, read as
// aligned four-word rows (mem_row = work-RAM word address [17:2]) through the
// M15D backend held-request/level-ACK client contract; one 8-byte line is
// cached per voice. Byte addresses outside $00000-$7FFFF read as 0 (MAME's
// unmapped sample space).
//
// Cadence: sample_tick (44.1 kHz [IMPLEMENTATION], MAME's C219 clock; physical
// rate [UNKNOWN]) starts one output sample: voices 0..15 are processed in
// order (sample-major; MAME renders voice-major per stream chunk — identical
// except for the shared noise-LFSR sequence), then out_left/out_right update
// with out_valid. A tick arriving while busy is queued (never lost) and
// counted in overruns.
//
// Output routing [MAME-CONFIRMED]: the mix scaled by register +0 (MAME's
// "volume_right") drives the LEFT speaker and +1 ("volume_left") the RIGHT
// (namcona1.cpp add_route(0 -> speaker 1, 1 -> speaker 0)); MAME's stream
// clamp (mix/4096) equals sat16(mix*8) on the wrapped 16-bit mix.
module na1_c219(
 input wire clk_sys,reset,
 input wire sample_tick,
 input wire reg_req,reg_write,input wire [8:0] reg_addr,input wire [7:0] reg_wdata,
 output wire reg_ack,output wire [7:0] reg_rdata,
 output reg mem_req=0,output reg [15:0] mem_row=0,
 input wire mem_ack,input wire [63:0] mem_data,
 output reg signed [15:0] out_left=0,out_right=0,output reg out_valid=0,
 output reg [15:0] overruns=0,output reg [31:0] fetches=0
);
 // ---------------------------------------------------------------- registers
 // Voice register bytes the engine consumes (flops, indexed by the sequencer).
 reg [7:0] r_vol0[0:15],r_vol1[0:15],r_freqh[0:15],r_freql[0:15],r_bank[0:15];
 reg [7:0] r_starth[0:15],r_startl[0:15],r_endh[0:15],r_endl[0:15],r_looph[0:15],r_loopl[0:15];
 reg [1:0] r_group[0:3]; // $1F7 -> [0] (voices 0-3), $1F1 -> [1], $1F3 -> [2], $1F5 -> [3]
 // Latched-at-key-on voice state and playback position.
 reg v_key[0:15];reg [7:0] v_mode[0:15],v_bank[0:15];
 reg [16:0] v_start[0:15],v_end[0:15],v_loop[0:15];
 reg [15:0] v_ptoffset[0:15];reg signed [19:0] v_pos[0:15];
 reg signed [15:0] v_lastdt[0:15],v_prevdt[0:15];
 reg c_valid[0:15];reg [15:0] c_tag[0:15];reg [63:0] c_data[0:15];
 reg [15:0] lfsr=16'h1234;
 // Full 512-byte mirror for readback (M10K).
 reg [7:0] mirror[0:511];
 reg [7:0] mirror_q=0;
 // Mirror-adjusted write offset: odd $1F8+ writes land 8 lower [MAME-CONFIRMED].
 wire [8:0] waddr=(reg_addr>=9'h1f8 && reg_addr[0]) ? reg_addr-9'd8 : reg_addr;
 wire [3:0] wvoice=waddr[7:4];
 // ---------------------------------------------------------------- sequencer
 localparam IDLE=0,LOAD=1,STEP=2,BOUND=3,ADDR=4,FETCH=5,DECODE=6,INTERP=7,VOL=8,MIX=9,ACC=10,NEXT=11,OUT=12;
 reg [3:0] state=IDLE;
 reg [3:0] v=0;
 reg busy=0,tick_pending=0;
 // Working copies of the current voice.
 reg key;reg [7:0] mode,bank;reg [15:0] freq;reg [16:0] vstart,vend,vloop;
 reg [15:0] ptoffset;reg signed [19:0] pos;reg signed [15:0] lastdt,prevdt;reg signed [16:0] dltdt;
 reg [1:0] cnt;reg [15:0] frac;reg signed [19:0] pos_new;
 reg [8:0] lvol0=0,lvol1=0;   // volume scales of the current voice, taken at LOAD
 reg [24:0] addr;reg [7:0] sbyte;
 reg signed [17:0] dt;reg signed [27:0] p0,p1;
 reg signed [15:0] acc0,acc1; // 16-bit wrapping mixers [MAME-CONFIRMED s16 buffers]
 wire noise=mode[2],looped=mode[4],inv_sign=mode[6],inv_lout=mode[3],mulaw=mode[0];
 // Register write acceptance: never while the sequencer holds the same voice.
 wire write_blocked=busy && !waddr[8] && wvoice==v;
 reg read_done=0;
 assign reg_ack=reg_req && (reg_write ? !write_blocked : read_done);
 wire [3:0] rvoice=reg_addr[7:4];
 assign reg_rdata=(!reg_addr[8] && reg_addr[3:0]==4'h5) ? {1'b0,v_key[rvoice],mirror_q[5:0]} : mirror_q;
 // ---------------------------------------------------------------- tables
 // Volume scaling (vol*32)/24 [MAME-CONFIRMED]; 0..340 fits 9 bits. Computed as
 // (x*683)>>9, which equals floor(x*32/24) for every x in 0..255 (exhaustively
 // checked by sim/m20c_timing_tb.sv): a 5-term shift-add instead of the variable
 // lpm_divide the "/24" form synthesised into (17 ns of carry chains, M20C timing).
 function [8:0] volscale(input [7:0] x);
  reg [17:0] t;
  begin t={10'd0,x}*18'd683;volscale=t[17:9]; end
 endfunction
 // mu-law decode = MAME pcmtbl[i] >> 5 [MAME-CONFIRMED]: cumulative step table
 // (steps 1/2/4/8/16 over 0-15/16-23/24-47/48-99/100-127); the negative half
 // (~pcmtbl[i-128] & $FFE0) >> 5 equals -j-1.
 function signed [15:0] mulaw_dec(input [7:0] i);
  reg [6:0] k;reg [10:0] j;
  begin
   k=i[6:0];
   if(k<7'd16) j={4'd0,k};
   else if(k<7'd24) j=11'd16+{3'd0,k-7'd16,1'b0};
   else if(k<7'd48) j=11'd32+{2'd0,k-7'd24,2'b0};
   else if(k<7'd100) j=11'd128+{1'b0,k-7'd48,3'b0};
   else j=11'd544+{k-7'd100,4'b0};
   mulaw_dec=i[7] ? (-$signed({5'd0,j})-16'sd1) : $signed({5'd0,j});
  end
 endfunction
 // Byte select from a cached row: byte k = word k[2:1], even byte in [15:8].
 function [7:0] rowbyte(input [63:0] d,input [2:0] k);
  reg [15:0] w;
  begin
   case(k[2:1]) 2'd0: w=d[15:0]; 2'd1: w=d[31:16]; 2'd2: w=d[47:32]; default: w=d[63:48]; endcase
   rowbyte=k[0] ? w[7:0] : w[15:8];
  end
 endfunction
 function signed [15:0] sat16(input signed [19:0] x);
  sat16=(x>20'sd32767) ? 16'sh7fff : (x<-20'sd32768) ? 16'sh8000 : x[15:0];
 endfunction
 integer i;
 initial begin
  for(i=0;i<512;i=i+1) mirror[i]=0;
  for(i=0;i<16;i=i+1) begin
   r_vol0[i]=0;r_vol1[i]=0;r_freqh[i]=0;r_freql[i]=0;r_bank[i]=0;
   r_starth[i]=0;r_startl[i]=0;r_endh[i]=0;r_endl[i]=0;r_looph[i]=0;r_loopl[i]=0;
   v_key[i]=0;v_mode[i]=0;v_bank[i]=0;v_start[i]=0;v_end[i]=0;v_loop[i]=0;
   v_ptoffset[i]=0;v_pos[i]=0;v_lastdt[i]=0;v_prevdt[i]=0;
   c_valid[i]=0;c_tag[i]=0;c_data[i]=0;
  end
  for(i=0;i<4;i=i+1) r_group[i]=0;
 end
 wire [15:0] row_of_addr=addr[18:3];
 wire signed [19:0] sz=$signed({3'd0,vend})-$signed({3'd0,vstart});
 wire signed [19:0] pos_step=pos+$signed({18'd0,cnt});
 wire signed [19:0] pos_loop=$signed({3'd0,vloop})-$signed({3'd0,vstart});
 reg signed [19:0] sz_r=0,pos_loop_r=0;
 wire signed [33:0] prod=dltdt*$signed({1'b0,frac});
 wire [15:0] lfsr_next=(lfsr>>1)^((-{15'd0,lfsr[0]})&16'hfff6);
 wire signed [15:0] dec_lin=$signed({{5{sbyte[7]}},sbyte,3'b000});
 wire signed [15:0] dec_mul=mulaw_dec(sbyte);
 wire signed [15:0] dec_val=noise ? $signed(lfsr_next) : mulaw ? dec_mul : dec_lin;
 wire signed [27:0] p1s=inv_lout ? -p1 : p1;
 wire signed [27:0] sh0w=noise ? (p0>>>13) : (p0>>>8);   // arithmetic >> (5+shift), shift = noise ? 8 : 3
 wire signed [27:0] sh1w=noise ? (p1s>>>13) : (p1s>>>8);
 wire signed [19:0] acc0x8={acc0[15],acc0,3'b000},acc1x8={acc1[15],acc1,3'b000}; // mix*8 (sign-extended)

 always @(posedge clk_sys) begin
  out_valid<=0;
  // Mirror RAM (readback) and read handshake.
  if(reg_req && reg_write && !write_blocked) mirror[waddr]<=reg_wdata;
  mirror_q<=mirror[reg_addr];
  if(!reg_req) read_done<=0; else if(!reg_write) read_done<=1;
  if(reset) begin
   state<=IDLE;v<=0;busy<=0;tick_pending<=0;mem_req<=0;overruns<=0;fetches<=0;lfsr<=16'h1234;
   for(i=0;i<16;i=i+1) begin v_key[i]<=0;c_valid[i]<=0; end
   for(i=0;i<4;i=i+1) r_group[i]<=0;
   out_left<=0;out_right<=0;read_done<=0;
  end else begin
   // ---------------- register writes (accepted this cycle)
   if(reg_req && reg_write && !write_blocked) begin
    if(!waddr[8]) begin
     case(waddr[3:0])
      4'h0: r_vol0[wvoice]<=reg_wdata;
      4'h1: r_vol1[wvoice]<=reg_wdata;
      4'h2: r_freqh[wvoice]<=reg_wdata;
      4'h3: r_freql[wvoice]<=reg_wdata;
      4'h4: r_bank[wvoice]<=reg_wdata;
      4'h5: begin
       if(reg_wdata[7]) begin
        v_key[wvoice]<=1;v_mode[wvoice]<=reg_wdata;v_bank[wvoice]<=r_bank[wvoice];
        v_start[wvoice]<={r_starth[wvoice],r_startl[wvoice],1'b0};
        v_end[wvoice]<={r_endh[wvoice],r_endl[wvoice],1'b0};
        v_loop[wvoice]<={r_looph[wvoice],r_loopl[wvoice],1'b0};
        v_ptoffset[wvoice]<=0;v_pos[wvoice]<=0;v_lastdt[wvoice]<=0;v_prevdt[wvoice]<=0;
       end else v_key[wvoice]<=0;
      end
      4'h6: r_starth[wvoice]<=reg_wdata;
      4'h7: r_startl[wvoice]<=reg_wdata;
      4'h8: r_endh[wvoice]<=reg_wdata;
      4'h9: r_endl[wvoice]<=reg_wdata;
      4'ha: r_looph[wvoice]<=reg_wdata;
      4'hb: r_loopl[wvoice]<=reg_wdata;
      default: ;
     endcase
    end else case(waddr)
     9'h1f7: r_group[0]<=reg_wdata[1:0];
     9'h1f1: r_group[1]<=reg_wdata[1:0];
     9'h1f3: r_group[2]<=reg_wdata[1:0];
     9'h1f5: r_group[3]<=reg_wdata[1:0];
     default: ;
    endcase
   end
   // ---------------- sample cadence
   if(sample_tick) begin
    if(busy || tick_pending) overruns<=overruns+1'd1;
    tick_pending<=1;
   end
   // ---------------- voice sequencer
   case(state)
    IDLE: if(tick_pending) begin
     tick_pending<=0;busy<=1;v<=0;acc0<=0;acc1<=0;state<=LOAD;
    end
    LOAD: begin
     key<=v_key[v];mode<=v_mode[v];bank<=v_bank[v];freq<={r_freqh[v],r_freql[v]};
     // r_vol0/1[v] cannot change between LOAD and MIX (writes to voice v are
     // blocked while busy), so scaling them here equals scaling them at MIX.
     lvol0<=volscale(r_vol0[v]);lvol1<=volscale(r_vol1[v]);
     vstart<=v_start[v];vend<=v_end[v];vloop<=v_loop[v];
     ptoffset<=v_ptoffset[v];pos<=v_pos[v];lastdt<=v_lastdt[v];prevdt<=v_prevdt[v];
     state<=STEP;
    end
    STEP: begin
     // Setup-timing fix: the sample length and loop offset are registered
     // here so BOUND no longer chains the vend/vstart subtractors into its
     // compare and the v_pos write (-0.58 ns at 100 MHz).
     sz_r<=sz;pos_loop_r<=pos_loop;
     // A voice without key or with frequency 0 contributes nothing and does not advance.
     if(!key || freq==16'd0) state<=NEXT;
     else begin
      {cnt,frac}<={2'b00,ptoffset}+{1'b0,freq,1'b0}; // offset += frequency*2 (16.16)
      state<=BOUND;
     end
    end
    BOUND: begin
     // pos += cnt; end test before the fetch; loop (or noise) rewinds, else key-off
     v_ptoffset[v]<=frac;
     if(pos_step>=sz_r) begin
      if(looped || noise) begin
       pos_new<=pos_loop_r;v_pos[v]<=pos_loop_r;
       state<=(cnt==2'd0) ? INTERP : noise ? DECODE : ADDR;
      end else begin
       v_key[v]<=0;v_pos[v]<=pos_step;
       state<=NEXT;
      end
     end else begin
      pos_new<=pos_step;v_pos[v]<=pos_step;
      state<=(cnt==2'd0) ? INTERP : noise ? DECODE : ADDR;
     end
    end
    ADDR: begin
     // byte address = group*$20000 + bank<<16 + start + pos [MAME-CONFIRMED find_sample]
     addr<={6'd0,r_group[v[3:2]],17'd0}+{1'b0,bank,16'd0}+{8'd0,vstart}+{{5{pos_new[19]}},pos_new};
     state<=FETCH;
    end
    FETCH: begin
     if(addr[24:19]!=6'd0) begin sbyte<=8'd0;mem_req<=0;state<=DECODE; end
     else if(c_valid[v] && c_tag[v]==row_of_addr) begin
      sbyte<=rowbyte(c_data[v],addr[2:0]);mem_req<=0;state<=DECODE;
     end else if(!mem_req) begin
      mem_req<=1;mem_row<=row_of_addr;
     end else if(mem_ack) begin
      mem_req<=0;fetches<=fetches+1'd1;
      c_valid[v]<=1;c_tag[v]<=row_of_addr;c_data[v]<=mem_data;
      sbyte<=rowbyte(mem_data,addr[2:0]);state<=DECODE;
     end
    end
    DECODE: begin
     // new sample: prevdt = lastdt; lastdt = decoded (sign-flipped if mode[6])
     prevdt<=lastdt;
     lastdt<=inv_sign ? -dec_val : dec_val;
     if(noise) lfsr<=lfsr_next;
     state<=INTERP;
    end
    INTERP: begin
     dltdt<=$signed({lastdt[15],lastdt})-$signed({prevdt[15],prevdt});
     state<=VOL;
    end
    VOL: begin
     dt<=$signed(prod[33:16])+$signed({{2{prevdt[15]}},prevdt}); // (dltdt*offset)>>16 + prevdt
     state<=MIX;
    end
    MIX: begin
     p0<=dt*$signed({1'b0,lvol0});p1<=dt*$signed({1'b0,lvol1});
     state<=ACC;
    end
    ACC: begin
     acc0<=acc0+sh0w[15:0];acc1<=acc1+sh1w[15:0]; // s16 += int (wrapping)
     state<=NEXT;
    end
    NEXT: begin
     v_lastdt[v]<=lastdt;v_prevdt[v]<=prevdt;
     state<=(v==4'd15) ? OUT : LOAD;v<=v+1'd1;
    end
    OUT: begin
     out_left<=sat16(acc0x8);out_right<=sat16(acc1x8);out_valid<=1;busy<=0;state<=IDLE;
    end
    default: state<=IDLE;
   endcase
  end
 end
endmodule
