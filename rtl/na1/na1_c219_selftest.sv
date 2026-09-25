// M20A hardware wiring self-test driver [IMPLEMENTATION, debug builds only].
// Not a production feature: NA1.sv instantiates it only when its compile-time
// AUDIO_SELFTEST parameter is 1, and the released bitstream is built with 0.
// It keys one F/A sound effect from the work-RAM sample set the 68000 uploads
// during the title screen, using the register values observed in the M20
// coin-sound trace [FA-TRACE] (voice 12, group bank $1F5=2, mu-law one-shot,
// start word $B43D, end $C6FD, frequency $18C0), once every ~2 s after `arm`
// rises, alternating full stereo / left-only / right-only volume so the
// AUDIO_L/AUDIO_R wiring and channel order can be heard. It contains no
// sample data; before the upload finishes the voice plays whatever the work
// RAM holds.
module na1_c219_selftest #(parameter PERIOD=200_000_000)( // 2 s at 100 MHz
 input wire clk_sys,reset,
 input wire arm,                 // start the periodic trigger (e.g. after startup)
 output reg reg_req=0,output reg reg_write=1,output reg [8:0] reg_addr=0,output reg [7:0] reg_wdata=0,
 input wire reg_ack
);
 reg [27:0] timer=0;reg [4:0] step=0;reg [1:0] pan=0;reg running=0;
 reg [7:0] vol0,vol1;
 wire [8:0] seq_addr [0:9];wire [7:0] seq_data [0:9];
 // (address, data) key-on sequence; volume bytes patched by pan
 assign seq_addr[0]=9'h1f5;assign seq_data[0]=8'h02;
 assign seq_addr[1]=9'h0c0;assign seq_data[1]=vol0;
 assign seq_addr[2]=9'h0c1;assign seq_data[2]=vol1;
 assign seq_addr[3]=9'h0c2;assign seq_data[3]=8'h18;
 assign seq_addr[4]=9'h0c3;assign seq_data[4]=8'hc0;
 assign seq_addr[5]=9'h0c4;assign seq_data[5]=8'h00;
 assign seq_addr[6]=9'h0c6;assign seq_data[6]=8'hb4;
 assign seq_addr[7]=9'h0c7;assign seq_data[7]=8'h3d;
 assign seq_addr[8]=9'h0c8;assign seq_data[8]=8'hc6;
 assign seq_addr[9]=9'h0c9;assign seq_data[9]=8'hfd;
 always @(posedge clk_sys) begin
  if(reset) begin timer<=0;step<=0;pan<=0;running<=0;reg_req<=0; end
  else if(!running) begin
   if(arm && timer==PERIOD) begin
    timer<=0;running<=1;step<=0;
    vol0<=(pan==2'd2) ? 8'h00 : 8'hf8;vol1<=(pan==2'd1) ? 8'h00 : 8'hf6;
    pan<=(pan==2'd2) ? 2'd0 : pan+1'd1;
   end else if(arm) timer<=timer+1'd1;
  end else begin
   if(!reg_req) begin
    reg_req<=1;
    if(step<5'd10) begin reg_addr<=seq_addr[step];reg_wdata<=seq_data[step]; end
    else begin reg_addr<=9'h0ca;reg_wdata<=8'h00; end // loop 0, then mode
    if(step==5'd11) begin reg_addr<=9'h0cb;reg_wdata<=8'h00; end
    if(step==5'd12) begin reg_addr<=9'h0c5;reg_wdata<=8'h83; end
   end else if(reg_ack) begin
    reg_req<=0;
    if(step==5'd12) running<=0; else step<=step+1'd1;
   end
  end
 end
endmodule
