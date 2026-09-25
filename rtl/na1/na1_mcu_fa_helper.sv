// TEMPORARY M4 compatibility helper, NOT a C69 emulator or physical protocol.
// [MAME-CONFIRMED] simulate_mcu clears the whole CPU-visible F60 word at
// scanline 224. [FA-TRACE] firmware does not supply either observed completion;
// Timer A0 works, and IRQ0 reads slot 2 although the 68000 writes slot 4.
// [UNKNOWN] physical mechanism and relevance of missing INT0 level sensing.
// [IMPLEMENTATION] canonical mailbox event -> ordinary RAM validation reads ->
// one completion write. No magic timer. This scheduling differs from MAME.
// Only two ordered cases: table-1 F30=0101, table-2 F30=0301; both F60=0301,
// F72 upper byte=03, slot2=0, slot4=0, full-word zero mailbox write.
module na1_mcu_fa_helper(
 input wire clk_sys,reset,irq0_request,
 input wire [15:0] irq0_wdata,input wire [1:0] irq0_byte_en,
 input wire [127:0] mailbox_state,
 output wire req,output wire write,output wire [17:0] word_addr,
 output wire [15:0] wdata,output wire [1:0] byte_en,
 input wire ack,input wire [15:0] rdata,
 output reg completion_event,output reg [1:0] completion_count,
 output wire busy
);
 localparam IDLE=0,READ_TABLE=1,GAP_TABLE=2,READ_WAIT=3,GAP_WAIT=4,
            READ_COMMAND=5,GAP_COMMAND=6,COMPLETE=7,GAP_COMPLETE=8;
 reg [3:0] state=IDLE;
 reg irq_seen=0;
 wire mailbox_matches=mailbox_state[47:32]==16'd0 &&
                       mailbox_state[79:64]==16'd0;
 assign busy=state!=IDLE;
 assign req=!reset && (state==READ_TABLE || state==READ_WAIT ||
                        state==READ_COMMAND || state==COMPLETE);
 assign write=state==COMPLETE;
 assign word_addr=state==READ_TABLE ? 18'h798 :
                  state==READ_COMMAND ? 18'h7b9 : 18'h7b0;
 assign wdata=16'd0; // resulting 68000-visible F60=0000, both lanes
 assign byte_en=2'b11;
 always @(posedge clk_sys) begin
  completion_event<=0;
  if(reset) begin state<=IDLE;irq_seen<=0;completion_count<=0;end
  else begin
   // Also tolerate a held event input without completing twice.
   irq_seen<=irq0_request;
   case(state)
    IDLE: if(irq0_request && !irq_seen && completion_count<2 &&
             irq0_byte_en==2'b11 && irq0_wdata==0 && mailbox_matches)
              state<=READ_TABLE;
    READ_TABLE: if(ack) begin
     if(rdata==(completion_count==0 ? 16'h0101 : 16'h0301)) state<=GAP_TABLE;
     else state<=IDLE;
    end
    GAP_TABLE: state<=READ_WAIT;
    READ_WAIT: if(ack) begin
     if(rdata==16'h0301) state<=GAP_WAIT;else state<=IDLE;
    end
    GAP_WAIT: state<=READ_COMMAND;
    READ_COMMAND: if(ack) begin
     if(rdata[15:8]==8'h03 && mailbox_matches) state<=GAP_COMMAND;
     else state<=IDLE;
    end
    GAP_COMMAND: state<=COMPLETE;
    COMPLETE: if(ack) begin
     completion_event<=1;completion_count<=completion_count+1'b1;
     state<=GAP_COMPLETE;
    end
    GAP_COMPLETE: state<=IDLE;
    default: state<=IDLE;
   endcase
  end
 end
endmodule
