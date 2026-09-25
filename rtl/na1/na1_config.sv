// M28B runtime hardware-configuration record (ONE RBF / MANY MRAs).
//
// MiSTer precedent: a small dedicated `<rom index="N">` whose bytes are latched
// into a register and describe the BOARD, not the game (Arcade-PsikyoSH2's
// index-2 BOARD_CONF, SYSTEM11_MiSTer's index-1 platform byte). This module is
// that latch for the NA-1 core. It carries no game identity, no GAME_ID, no
// per-game table and no video/input/layout switches -- everything else a game
// needs is either in the index-0 ROM stream or is generic NA-1 hardware
// (docs/M28A_RESEARCH.md section 7.2, docs/M28A1_VIDEO_COMPAT.md section 7).
//
// Transport: ioctl index CONFIG_INDEX, exactly RECORD_BYTES bytes.
// hps_io is instantiated WIDE=1, so ioctl_addr is a BYTE address stepping by 2
// and ioctl_dout carries stream byte 2k in [7:0] and byte 2k+1 in [15:8].
//
//   byte 0  KEYCUS_MODE       (0 = no KEYCUS fitted, 1 = ID + changing value)
//   byte 1  KEYCUS_ID  low
//   byte 2  KEYCUS_ID  high
//   byte 3  KEYCUS_ID_OFFSET  in [2:0]; [7:3] must be written 0 (ignored here)
//   byte 4  VIDEO_BASE_FLIP   [0] 1 = the board's correct presentation is the
//                             180-degree one (MAME ROT90 cabinets, e.g. F/A);
//                             0 = unrotated (MAME ROT0, e.g. Bakuretsu).
//                             [7:1] reserved, write 0.
//   byte 5  CONTROL_PANEL     0 = joystick + 3 buttons + start (namcona1_joy
//                             cabinets); 1 = 4-button quiz panel + start
//                             (namcona1_quiz cabinets). Unknown values degrade
//                             to 0.
//   byte 6  ROM_BOARD_IO      [0] 1 = the ROM board fits an MSM6242 RTC at
//                             $DC0000-$DC001F and a printer/battery status
//                             byte at $D80001 in the program-ROM window
//                             (X-Day 2's M112 ROM PCB, rtl/na1/na1_rom_board_io.sv);
//                             0 = plain EPROM board. [7:1] reserved, write 0.
//                             OPTIONAL (M30): a 6-byte record leaves it 0, so
//                             every pre-M30 MRA is unchanged.
//
// Bytes 4-5 were added in M28B.1 after hardware testing (see
// docs/M28B_IMPLEMENTATION.md section 11). They describe the CABINET -- how the
// monitor is mounted and which control panel is wired -- which is board
// hardware, not game identity. They explicitly supersede two bullets of
// docs/M28A_RESEARCH.md section 7.2 ("no orientation/rotation field", "no
// INPUT_HW_TYPE"); see the implementation document for why the hardware
// evidence overrode that reasoning.
//
// Lifecycle:
//  * Power-up/configuration value = the DEFAULT_* parameters, so a bitstream
//    loaded by a config-less MRA behaves exactly as the pre-M28B core did.
//  * The record is NOT cleared by reset_system. NA1.sv holds the machine in
//    reset for the whole of every ioctl download (`download_active` feeds
//    `reset_async`), so a reset-sensitive latch would be wiped by the very
//    transfer that fills it. Configuration must therefore survive reset and
//    only ever change on an index-CONFIG_INDEX write.
//  * Writing byte 0 (the first word of a record) re-arms the trailing fields to
//    their defaults, so a short/truncated record can never leave a previous
//    game's ID high byte, offset, base orientation or panel behind. A complete
//    record overwrites every field unconditionally.
//  * Bytes at or beyond RECORD_BYTES are ignored (bounded record).
//  * Every other ioctl index (0 = ROM stream, 1 = NVRAM) is ignored entirely.
module na1_config #(
    parameter [15:0] CONFIG_INDEX = 16'd2,
    parameter integer RECORD_BYTES = 7,
    // Compiled-in default = F/A's board, i.e. `01 5D 01 02 01 00`.
    parameter [7:0]  DEFAULT_KEYCUS_MODE = 8'h01,
    parameter [15:0] DEFAULT_KEYCUS_ID = 16'h015d,
    parameter [2:0]  DEFAULT_KEYCUS_ID_OFFSET = 3'd2,
    parameter        DEFAULT_VIDEO_BASE_FLIP = 1'b1,
    parameter [7:0]  DEFAULT_CONTROL_PANEL = 8'h00,
    parameter        DEFAULT_ROM_BOARD_IO = 1'b0
)(
    input  wire        clk_sys,
    input  wire        download_active,
    input  wire        download_wr,
    input  wire [15:0] download_index,
    input  wire [26:0] download_addr,
    input  wire [15:0] download_data,
    output wire [7:0]  keycus_mode,
    output wire [15:0] keycus_id,
    output wire [2:0]  keycus_id_offset,
    output wire        video_base_flip,
    output wire [7:0]  control_panel,
    output wire        rom_board_io
);
    reg [7:0]  mode      = DEFAULT_KEYCUS_MODE;
    reg [7:0]  id_lo     = DEFAULT_KEYCUS_ID[7:0];
    reg [7:0]  id_hi     = DEFAULT_KEYCUS_ID[15:8];
    reg [2:0]  id_offset = DEFAULT_KEYCUS_ID_OFFSET;
    reg        base_flip = DEFAULT_VIDEO_BASE_FLIP;
    reg [7:0]  panel     = DEFAULT_CONTROL_PANEL;
    reg        board_io  = DEFAULT_ROM_BOARD_IO;

    wire selected = download_active && download_wr &&
                    download_index == CONFIG_INDEX &&
                    download_addr < RECORD_BYTES[26:0];

    always @(posedge clk_sys) begin
        if(selected) begin
            case(download_addr[26:1])
                26'd0: begin
                    mode      <= download_data[7:0];    // byte 0
                    id_lo     <= download_data[15:8];   // byte 1
                    // Re-arm the trailing fields: a truncated record degrades
                    // to the compiled-in default, never to the previous game's.
                    id_hi     <= DEFAULT_KEYCUS_ID[15:8];
                    id_offset <= DEFAULT_KEYCUS_ID_OFFSET;
                    base_flip <= DEFAULT_VIDEO_BASE_FLIP;
                    panel     <= DEFAULT_CONTROL_PANEL;
                    board_io  <= DEFAULT_ROM_BOARD_IO;
                end
                26'd1: begin
                    id_hi     <= download_data[7:0];    // byte 2
                    id_offset <= download_data[10:8];   // byte 3 [2:0]
                end
                26'd2: begin
                    base_flip <= download_data[0];      // byte 4 [0]
                    panel     <= download_data[15:8];   // byte 5
                end
                // byte 6 [0]; byte 7 does not exist (bounded by RECORD_BYTES).
                26'd3: board_io <= download_data[0];
                default: ;
            endcase
        end
    end

    assign keycus_mode      = mode;
    assign keycus_id        = {id_hi, id_lo};
    assign keycus_id_offset = id_offset;
    assign video_base_flip  = base_flip;
    assign control_panel    = panel;
    assign rom_board_io     = board_io;
endmodule
