// M5 ordinary additional RAM, $FFC000-$FFDFFF. No address-specific behavior.
// Hold the request tuple until ack, then withdraw for >=1 clock edge.
// [IMPLEMENTATION] Capture -> synchronous storage access -> held response.
// Reset cancels pending transport; it does not clear stored words.
module na1_additional_ram(
    input wire clk_sys,reset,req,write,
    input wire [23:0] addr,input wire [15:0] wdata,
    input wire [1:0] byte_en,
    output wire ack,output wire [15:0] rdata
);
    localparam IDLE=0,ACCESS=1,RESPONSE=2;
    reg [1:0] state=IDLE;
    reg held_write=0;
    reg [11:0] held_word_addr=0;
    reg [15:0] held_wdata=0;
    reg [1:0] held_byte_en=0;
    wire selected=req && addr>=24'hffc000 && addr<=24'hffdfff;
    wire storage_enable=!reset && selected && state==ACCESS;
    wire [15:0] storage_rdata;
    assign ack=!reset && selected && state==RESPONSE;
    assign rdata=ack && !held_write ? storage_rdata : 16'd0;
    na1_additional_storage storage(.clk_sys(clk_sys),.enable(storage_enable),
        .write(held_write),.word_addr(held_word_addr),.wdata(held_wdata),
        .byte_en(held_byte_en),.rdata(storage_rdata));
    always @(posedge clk_sys) begin
        if(reset) begin
            state<=IDLE;held_write<=0;held_word_addr<=0;
            held_wdata<=0;held_byte_en<=0;
        end else case(state)
            IDLE: if(selected) begin
                held_write<=write;held_word_addr<=addr[12:1];
                held_wdata<=wdata;held_byte_en<=byte_en;state<=ACCESS;
            end
            ACCESS: if(selected) state<=RESPONSE;else state<=IDLE;
            RESPONSE: if(!selected) state<=IDLE;
            default: state<=IDLE;
        endcase
    end
endmodule
