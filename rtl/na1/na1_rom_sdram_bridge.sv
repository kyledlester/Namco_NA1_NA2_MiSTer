// M15C/M15D logical immutable-ROM adapter. Translates held NA-1 ROM requests
// and IOCTL index-0 download words into one backend client transaction each.
//
// M29: the mask-ROM backing grew from 4 MiB to the FULL 8 MiB the 68000 window
// and MAME's own `maskrom` ROM_REGION16_BE declare, because Tinkle Pit really
// reads past 4 MiB (M28A.1: 252,836 accesses at or above +$400000, max
// $600A3E). The old `populated` clamp -- which answered $0000 for
// rom_word_addr[21] -- is therefore gone: every mask word is now backed by
// SDRAM and the MRA guarantees its contents, padding the unpopulated tail with
// 00 exactly as MAME's region does. Download words accordingly extend to the
// new MCU-BIOS window at stream $A00000 (docs/M28A_RESEARCH.md section 3.2).
// The physical pulse/ready protocol lives in na1_sdram_backend; this adapter
// only uses the backend's held-request/level-ACK client contract.
module na1_rom_sdram_bridge(
 input wire clk_sys,reset_runtime,
 input wire rom_req,rom_image,input wire [21:0] rom_word_addr,
 output wire rom_ack,output wire [15:0] rom_rdata,
 input wire download_active,download_wr,input wire [15:0] download_index,
 input wire [26:0] download_addr,input wire [15:0] download_data,
 output wire download_wait,
 output wire mem_req,mem_write,output wire [25:0] mem_word_addr,
 output wire [15:0] mem_wdata,output wire [1:0] mem_byte_en,
 input wire mem_ack,input wire [15:0] mem_rdata
);
 localparam IDLE=0,WAIT_MEM=1,RESPONSE=2,GAP=3;
 reg [1:0] state=IDLE;
 reg held_write=0;
 reg [25:0] held_word_addr=0;
 reg [15:0] held_wdata=0,response_data=0;
 wire download_selected=download_active && download_index==0;
 wire [25:0] runtime_phys_word=rom_image ?
     (26'h100000 + {4'd0,rom_word_addr}) : {4'd0,rom_word_addr};
 // Runtime cancellation: the backend sees mem_req fall and drains on its own.
 wire runtime_reset=reset_runtime && !download_active;
 assign mem_req=!runtime_reset && state==WAIT_MEM &&
     (download_active ? download_selected : rom_req);
 assign mem_write=held_write;
 assign mem_word_addr=held_word_addr;
 assign mem_wdata=held_wdata;
 assign mem_byte_en=2'b11;
 assign rom_ack=!reset_runtime && rom_req && state==RESPONSE && !download_active;
 assign rom_rdata=rom_ack ? response_data : 16'd0;
 // M22: narrowed from `download_active && (!download_selected || ...)`,
 // which backpressured (ioctl_wait) indefinitely for ANY non-zero
 // download_index -- blocking any other ioctl stream (e.g. M22 NVRAM at
 // index 1) forever. This module only needs to hold back the host while
 // it is itself actively servicing an index-0 (ROM) transfer; for every
 // other index it now never asserts wait, identical behavior for index 0.
 assign download_wait=download_selected &&
     (state!=IDLE || (download_wr && download_addr[0]));

 always @(posedge clk_sys) begin
  if(runtime_reset) begin
   state<=IDLE;response_data<=0;held_write<=0;
  end else case(state)
   IDLE: begin
    if(download_selected && download_wr && !download_addr[0] && download_addr<27'h0A00000) begin
     held_write<=1;held_word_addr<=download_addr[26:1];held_wdata<=download_data;
     state<=WAIT_MEM;
    end else if(!download_active && rom_req) begin
     held_write<=0;held_word_addr<=runtime_phys_word;held_wdata<=0;
     state<=WAIT_MEM;
    end
   end
   WAIT_MEM: if(!mem_req) state<=GAP; // requester withdrew: backend drains
   else if(mem_ack) begin
    response_data<=held_write ? 16'd0 : mem_rdata;
    state<=held_write ? GAP : RESPONSE;
   end
   RESPONSE: if(!rom_req || download_active) begin
    state<=GAP;response_data<=0;
   end
   GAP: state<=IDLE; // one low mem_req edge before the next client request
   default: state<=IDLE;
  endcase
 end
endmodule
