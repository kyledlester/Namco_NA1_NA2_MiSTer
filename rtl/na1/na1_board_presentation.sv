// M28B.1 — MiSTer-facing presentation mapping selected by the runtime board
// record (rtl/na1/na1_config.sv, ioctl index 2).
//
// This module holds the two places where the MiSTer *presentation* layer has to
// know something about the physical NA-1 board that neither the ROM stream nor
// any NA-1 register can tell it. Both are board/cabinet properties, not game
// identity: there is no GAME_ID, no game name and no per-game table here or
// anywhere else in the core.
//
// 1. BASE ORIENTATION (`cfg_base_flip`). The NA-1 raster is the same on every
//    board; what differs is how the monitor is mounted in the cabinet, which is
//    exactly what MAME records as ROT90 vs ROT0. F/A needs a 180-degree base
//    presentation (`[HW-CONFIRMED]` since M24/M26); Bakuretsu Quiz Ma-Q needs
//    none (`[HW-CONFIRMED]` 2026-09-22, owner DE10-Nano: the mode the OSD calls
//    "Horizontal" showed it upside down and "Flipped" showed it correctly).
//    The record supplies the base, so the OSD's "Horizontal" is the board's own
//    correct presentation for every game and "Flipped" is its 180-degree
//    opposite. The two Vertical modes are unchanged from M24 and never carry
//    the base flip -- their `[HW-CONFIRMED]` F/A behaviour must not move.
//
// 2. CONTROL PANEL (`cfg_panel`). The NA-1 port BITS are identical for every
//    game (`[MAME-CONFIRMED]`: namcona1_joy and namcona1_quiz differ only in
//    labels), but the CABINET differs -- a joystick panel versus a four-button
//    quiz panel -- and MiSTer maps its own joystick bits to core bits inside
//    the core, not in the MRA. So the record says which panel is fitted and
//    this module routes MiSTer's buttons to the NA-1 port bits that panel
//    actually wires up. The emulated port-bit semantics are untouched: the quiz
//    panel drives exactly the bits MAME's namcona1_quiz declares.
//
// M29 adds players 3 and 4. Every NA-1 board wires four identical 8-bit player
// ports (`[MAME-CONFIRMED]`: :P1/:P2/:P3/:P4 all declare Right/Left/Down/Up +
// Button 1..3 + Start on the same bits), so the panel mapping below is applied
// to all four identically and P3/P4 need no new configuration field. Only
// Super World Court actually reads them; for every other game the extra
// joysticks are simply idle and the ports read all-ones, exactly as before.
//
// MiSTer joystick bit order (J1 in NA1.sv's CONF_STR, six entries):
//   [3:0] Up/Down/Left/Right, [4]..[9] the six J buttons in declaration order.
module na1_board_presentation(
    input  wire [1:0]  orient,          // status[7:6], the M24/M26 selector
    input  wire        cfg_base_flip,   // board record byte 4, bit 0
    input  wire [7:0]  cfg_panel,       // board record byte 5
    input  wire [31:0] joystick_0,
    input  wire [31:0] joystick_1,
    input  wire [31:0] joystick_2,
    input  wire [31:0] joystick_3,
    output wire        flip_native,     // to na1_renderer
    output wire [7:0]  input_p1,        // active low, as the C69 P7 mux reads
    output wire [7:0]  input_p2,
    output wire [7:0]  input_p3,        // read through the C69 A-D channels
    output wire [7:0]  input_p4,
    output wire        coin_1,          // active high; inverted into input_dsw
    output wire        coin_2,
    output wire        coin_3,
    output wire        coin_4
);
    localparam [7:0] PANEL_JOYSTICK = 8'h00; // 8-way + 3 buttons + start
    localparam [7:0] PANEL_QUIZ     = 8'h01; // 4 answer buttons + start

    // Any unknown panel byte degrades to the joystick panel, matching the
    // record's general "unknown value -> the safe default" rule.
    wire quiz = (cfg_panel == PANEL_QUIZ);

    // --- 1. base orientation -------------------------------------------
    // orient 00 "Horizontal" = the board's own correct presentation
    // orient 11 "Flipped"    = its 180-degree opposite
    // orient 01/10 vertical  = unchanged from M24, never base-flipped
    assign flip_native = (orient == 2'd0) ?  cfg_base_flip :
                         (orient == 2'd3) ? ~cfg_base_flip : 1'b0;

    // --- 2. control panel ----------------------------------------------
    // Joystick panel (F/A): bit-for-bit the pre-M28B.1 wiring.
    //   p1[7]=Start p1[6]=Button 3 p1[5]=Bomb p1[4]=Shot
    //   p1[3]=Up    p1[2]=Down     p1[1]=Left p1[0]=Right      coin = J button 5
    // Quiz panel (Bakuretsu): MAME's :P1 declares Button 1..4 on bits 3..0 and
    // Start on bit 7, with bits 6..4 unconnected. `[MAME-CONFIRMED]` port dump.
    // The four answer buttons are therefore J buttons 1..4, in UI order:
    //   J1 Button 1 -> p1[3]   J2 Button 2 -> p1[2]
    //   J3 Button 3 -> p1[1]   J4 Button 4 -> p1[0]
    //   J5 Start    -> p1[7]   J6 Credit   -> coin
    function automatic [7:0] panel_map(input [31:0] joy, input is_quiz);
        panel_map = is_quiz ? {joy[8], 3'b000, joy[4], joy[5], joy[6], joy[7]}
                            :  joy[7:0];
    endfunction

    assign input_p1 = ~panel_map(joystick_0, quiz);
    assign input_p2 = ~panel_map(joystick_1, quiz);
    assign input_p3 = ~panel_map(joystick_2, quiz);
    assign input_p4 = ~panel_map(joystick_3, quiz);
    assign coin_1   = quiz ? joystick_0[9] : joystick_0[8];
    assign coin_2   = quiz ? joystick_1[9] : joystick_1[8];
    assign coin_3   = quiz ? joystick_2[9] : joystick_2[8];
    assign coin_4   = quiz ? joystick_3[9] : joystick_3[8];
endmodule
