// Namco NA-1/NA-2 "KEYCUS" (C3xx DIP32 custom on the ROM board).
//
// M10 implemented this for F/A's C349 with the ID value and its word offset
// hard-coded. M28B makes those a RUNTIME HARDWARE DESCRIPTION supplied by the
// MRA at ioctl index 2 (docs/M28B_IMPLEMENTATION.md, docs/M28A1_VIDEO_COMPAT.md
// section 7): mode + 16-bit ID + 3-bit ID word offset. There is no game
// identity here -- the record says WHICH PART IS FITTED and on WHICH REGISTER
// it answers, which is a property of the ROM board, not of the software.
//
// cfg_mode semantics (docs/M28A1_VIDEO_COMPAT.md section 7.2):
//   8'h00  no KEYCUS fitted        -- every read returns 0 (MAME: default 0)
//   8'h01  constant ID at cfg_id_offset, changing value at every other offset
//   8'h02  constant ID at cfg_id_offset PLUS the C367 stateful sequence
//            (M29, for Tinkle Pit). Added because a real target needs it, not
//            speculatively. `[MAME-CONFIRMED]` custom_key_r NAMCO_TINKLPIT:
//              offset cfg_id_offset (=7) -> cfg_id
//              offset 4               -> resets the 32-bit state to 0, and
//                                        still answers with the changing value
//              offset 3               -> bitswap<16>(state, 22,26,31,23,18,20,
//                                        16,30,24,21,25,19,17,29,28,27), THEN
//                                        state >>= 1 and state ^= $80000000 if
//                                        the shifted state is 0 or
//                                        popcount(state & $58000C00) is odd
//              anything else          -> the changing value
//            The offsets 3 and 4 and the tap set are fixed properties of the
//            C367 part, so they are implied by the mode and are NOT record
//            fields (docs/M28A1_VIDEO_COMPAT.md section 7.1).
//   other  reserved; treated as 8'h01 with the supplied ID/offset (the
//          documented safe degradation).
//
// The changing value itself is unchanged from M10: a sample of the free-running
// B400 Galois sequence, one step per committed read (including ID reads). That
// is an [IMPLEMENTATION] compatibility profile -- MAME returns host randomness
// and the physical generator of every C3xx part remains [UNKNOWN]. M28A.1
// section 7.1 established this needs no per-part configuration field.
module na1_keycus(
    input wire clk_sys,reset,req,write,
    input wire [23:0] addr,
    input wire [15:0] wdata,
    input wire [1:0] byte_en,
    // Runtime KEYCUS hardware description (ioctl index 2, latched in na1_config).
    input wire [7:0] cfg_mode,
    input wire [15:0] cfg_id,
    input wire [2:0] cfg_id_offset,
    output wire ack,output wire [15:0] rdata
);
    localparam [1:0] IDLE=0,ACCESS=1,RESPONSE=2;
    reg [1:0] state=IDLE;
    reg held_write=0;
    reg [2:0] held_offset=0;
    reg [15:0] response=0;
    // Synthesizable cold-configuration seed; ordinary reset retains this state.
    reg [15:0] sequence_state=16'hace1;
    // C367 (mode 2) stateful register. MAME leaves m_keyval uninitialised;
    // `[MAME-CONFIRMED]` Tinkle Pit reads offset 4 first, which forces it to 0,
    // so the cold value is unobservable in practice. 0 is chosen here because
    // it is what that first read produces anyway (docs/M28A_RESEARCH.md R9).
    // Retained across warm reset, exactly like sequence_state.
    reg [31:0] keyval=32'd0;
    wire [31:0] keyval_shift = keyval >> 1;
    wire [31:0] keyval_next =
        (keyval_shift==32'd0 || ^(keyval_shift & 32'h58000c00)) ?
        (keyval_shift ^ 32'h80000000) : keyval_shift;
    wire [15:0] keyval_out = {keyval[22],keyval[26],keyval[31],keyval[23],
                              keyval[18],keyval[20],keyval[16],keyval[30],
                              keyval[24],keyval[21],keyval[25],keyval[19],
                              keyval[17],keyval[29],keyval[28],keyval[27]};
    wire selected=req && addr>=24'he40000 && addr<=24'he4000f && |byte_en;
    assign ack=!reset && selected && state==RESPONSE;
    assign rdata=ack && !held_write ? response : 16'd0;
    // Mode 0 = no part fitted. Every other mode answers the ID at its offset.
    wire fitted = (cfg_mode != 8'h00);
    wire stateful = (cfg_mode == 8'h02);
    always @(posedge clk_sys) begin
        if(reset) begin
            state<=IDLE;held_write<=0;held_offset<=0;response<=0;
        end else case(state)
            IDLE: if(selected) begin
                held_write<=write;held_offset<=addr[3:1];state<=ACCESS;
            end
            ACCESS: if(selected) begin
                response<=held_write || !fitted ? 16'd0 :
                          held_offset==cfg_id_offset ? cfg_id :
                          (stateful && held_offset==3'd3) ? keyval_out :
                          sequence_state;
                if(!held_write) begin
                    // The changing value advances on EVERY committed read,
                    // including ID reads, exactly as MAME advances m_count at
                    // the top of custom_key_r before dispatching.
                    sequence_state<=(sequence_state>>1) ^
                                    (sequence_state[0] ? 16'hb400 : 16'd0);
                    if(stateful && held_offset!=cfg_id_offset) begin
                        if(held_offset==3'd4) keyval<=32'd0;
                        else if(held_offset==3'd3) keyval<=keyval_next;
                    end
                end
                state<=RESPONSE;
            end else state<=IDLE;
            RESPONSE: if(!selected) state<=IDLE;
            default: state<=IDLE;
        endcase
    end
    // Writes (including partial lanes/nonzero data) deliberately have no effect
    // -- MAME's custom_key_w is empty for every NA-1/NA-2 game [MAME-CONFIRMED].
    // BE selects CPU lanes; return the full word, no byte swapping/latching.
endmodule
