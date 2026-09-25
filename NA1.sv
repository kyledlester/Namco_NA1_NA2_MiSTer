// MiSTer platform-facing memory foundation. Platform contract from Template_MiSTer.
// SPDX-License-Identifier: GPL-3.0-or-later
module emu (
    `include "sys/emu_ports.vh"
);
    wire c_work_req;
    wire c_work_write;
    wire c_work_ack;
    wire [17:0] c_work_word_addr;
    wire [15:0] c_work_wdata;
    wire [15:0] c_work_rdata;
    wire [1:0] c_work_byte_en;
    wire c_rom_req;
    // M30: the main CPU's M1 bus, observed by the ROM-board I/O for RTC writes.
    wire m_cpu_req,m_cpu_write,m_cpu_ack;wire [23:0] m_cpu_addr;
    wire [15:0] m_cpu_wdata;wire [1:0] m_cpu_byte_en;
    wire c_rom_image;
    wire c_rom_ack;
    wire [21:0] c_rom_word_addr;
    wire [15:0] c_rom_rdata;
    wire [12:0] c_peripheral_req;
    wire c_peripheral_write;
    wire [23:0] c_peripheral_addr;
    wire [15:0] c_peripheral_wdata;
    wire [1:0] c_peripheral_byte_en;
    wire [12:0] c_peripheral_ack;
    wire [207:0] c_peripheral_rdata;
    wire [191:0] blit_registers;wire blit_req,blit_ack,blit_fault;
    wire clk_sys, pll_locked;
    na1_pll clocks(.refclk(CLK_50M), .rst(1'b0),
                   .clk_sys(clk_sys), .locked(pll_locked));
    wire [127:0] status;
    wire [1:0] buttons;
    wire download_active, download_wr, download_wait, rom_download_wait;
    wire [26:0] download_addr;
    wire [15:0] download_data, download_index;
    // M22 NVRAM ioctl port (EEPROM persistence): standard MiSTer <nvram>
    // download/upload, index 1 (index 0 stays the ROM stream). hps_io
    // auto-downloads a previously-saved NVRAM file into the core at start.
    // `[HW-CONFIRMED BUG, fixed]`: the ORIGINAL M22 build tied
    // `ioctl_upload_req` permanently low, so the ARM side's
    // `UIO_CHK_UPLOAD` readiness query (Main_MiSTer menu.cpp
    // MENU_SAVE_CHECK: `if(is_arcade() && spi_uio_cmd(UIO_CHK_UPLOAD))
    // arcade_nvm_save();`) never saw a rising edge and `arcade_nvm_save()`
    // was never called on Save Settings -- confirmed against
    // Main_MiSTer/support/arcade/mra_loader.cpp and hps_io.sv's own
    // `upload_req` latch (`if(~old_upload_req & ioctl_upload_req)
    // upload_req<=1`, cleared only once read, i.e. a genuine edge-latched
    // dirty flag, not a level the ARM polls continuously).
    // `[IMPLEMENTATION, corrected]`: an interim fix drove `ioctl_upload_req`
    // from a free-running ~60 Hz toggle; that made the readiness query
    // pass but was an unrelated oscillator, not a meaningful dirty signal,
    // and doesn't match how real working MiSTer NVRAM cores wire this
    // port (e.g. Arcade-IremM90_MiSTer computes its own upload_req from
    // internal module state, not a periodic source). Replaced with a real
    // event-driven dirty flag: `na1_eeprom.sv`'s new `eeprom_dirty_event`
    // output pulses for exactly one clk_sys cycle on a genuine committed
    // CPU EEPROM write (never on the NVRAM ioctl download/restore path,
    // which uses a separate write path inside that module and so never
    // marks the array dirty again just from being restored). `eeprom_dirty`
    // latches on that pulse and is cleared only once an actual upload
    // session for our index starts (`nvram_upload_active`), so it stays
    // armed until a real save consumes it and re-arms cleanly for the next
    // write after that.
    // nvram_active is held for the WHOLE session (na1_eeprom.sv arbitrates
    // its one storage port on that level, not per-word) -- see the M22 fit
    // failure writeup in docs/M22_IMPLEMENTATION.md for why a genuine
    // second RAM port was abandoned in favor of this arbitration.
    localparam NVRAM_INDEX = 16'd1;
    // M28B runtime hardware-configuration record (index 0 = ROM stream,
    // index 1 = NVRAM, index 2 = configuration). na1_rom_sdram_bridge only
    // backpressures ioctl_wait while servicing index 0 (M22), so index-2
    // traffic passes through unimpeded exactly like index 1 does.
    localparam BOARD_CFG_INDEX = 16'd2;
    wire nvram_upload_active;
    wire nvram_active = (download_active || nvram_upload_active) && download_index==NVRAM_INDEX;
    wire eeprom_nvram_wr = download_active && download_wr && download_index==NVRAM_INDEX;
    wire [15:0] eeprom_nvram_rdata;
    wire eeprom_nvram_write_busy,eeprom_nvram_read_ready;
    wire eeprom_dirty_event;
    // M29.3: index-1 EEPROM storage is a synchronous, single-port byte RAM.
    // Real hps_io SPI transfers can present/consume 16-bit words faster than
    // its two-byte sequencer.  Backpressure downloads until the current pair
    // commits, and uploads until the requested pair has actually been read.
    // Index 0 retains the SDRAM bridge's existing wait behavior; index 2 and
    // all other streams remain unthrottled.
    assign download_wait = rom_download_wait ||
        (download_active && download_index==NVRAM_INDEX && eeprom_nvram_write_busy) ||
        (nvram_upload_active && download_index==NVRAM_INDEX && !eeprom_nvram_read_ready);
    reg eeprom_dirty=0;
    always @(posedge clk_sys) begin
        if(eeprom_dirty_event) eeprom_dirty<=1;
        else if(nvram_upload_active) eeprom_dirty<=0;
    end
    // M15E: the video path is live (MAME_COMPAT timing). Scandoubler effects
    // use the framework's conventional arcade option bits.
    // M18: J1 declares the joystick buttons in framework order, so
    // joystick_N = {.., [8] Coin, [7] Start, [6] Button 3, [5] Bomb, [4] Shot,
    // [3] up, [2] down, [1] left, [0] right}. No DIP/switches download.
    // M21: standard MiSTer HDMI/scaler rotation (screen_rotate/MISTER_FB).
    // M24: that single O[1] Vert/Horz toggle is RETIRED and replaced by one
    // 2-bit orientation selector at O[7:6] (bits 6/7 were never used by any
    // previous build, so a stale saved status[1] from an older core cannot
    // reach any presentation control -- status[1] is now referenced nowhere).
    // Horizontal is index 0, hence the power-on default. Vertical CW/CCW are
    // HDMI/scaler framebuffer rotations (screen_rotate); Flipped is a native
    // 180-degree presentation transform inside the renderer, so it reaches
    // BOTH the HDMI/scaler path and the M23 native 15-kHz CRT output. This is
    // a MiSTer presentation feature only -- it is NOT F/A's own service-menu
    // FLIP, which stays unimplemented and is deliberately not wired to it.
    // See docs/M24_RESEARCH.md / docs/M24_IMPLEMENTATION.md.
    // M22: F/A has no game DIPs (settings live in EEPROM via its own service
    // menu, [MAME-CONFIRMED] docs/M18_IMPLEMENTATION.md); only the hardware
    // control-panel bit that opens that menu is exposed. status[4]/[5] were
    // previously unused. `[HW-CONFIRMED]` (owner, 2026-09-21): the genuine
    // C69 firmware's menu entry responds to the Service 1 (DSW b7)
    // press/release edge, not the separate service-mode switch (DSW b6)
    // level by itself.
    // `[HW-CONFIRMED BUG]` (owner, 2026-09-21, round 3): collapsing this to
    // a single `O[4]` toggle (with an internally synthesized Service-1
    // pulse on its Off->On edge) made the OSD item itself stop toggling at
    // all -- unlike `O[1]`/`O[3:2]` in this same CONF_STR, which continued
    // to work -- while no static CONF_STR/status-bit defect could be found
    // to explain that (see docs/M22_IMPLEMENTATION.md, "Service Mode UX
    // correction", round 3). Reverted to the previously owner-confirmed
    // two-control split: `O[4]` is a plain persistent toggle driving DSW b6
    // (the service-mode switch level) only, and `R[5]` is a momentary
    // action -- the same self-clearing `R[]` convention already used for
    // `R[0],Reset` -- driving DSW b7 (Service 1) directly from the
    // framework's own one-frame action pulse, no synthesized hold needed.
    // Test/Freeze (DSW b1/b0) stay inactive: no established MiSTer
    // convention for this core was found and F/A's use of them is
    // unresearched -- see docs/M22_IMPLEMENTATION.md.
    // M26 CRT Adjust status bits. Allocated in a fresh high block so they
    // cannot collide with anything live: status[0] Reset, [3:2] Scandoubler
    // Fx, [4] Service Mode, [7:6] Orientation. status[1], [5] and
    // [8]..[95] stay free ([5] retired with the Service 1 row); CRT Adjust
    // uses only [108:96]:
    //   [96]      CRT Adjust master enable (0 = Off = default = TRUE bypass)
    //   [100:97]  CRT H-Size     signed 4-bit, -8..+7, one step = ~1% WIDER
    //   [104:101] CRT H-Position signed 4-bit, -8..+7, one step = 6 px right
    //   [108:105] CRT V-Shift    signed 4-bit, -8..+7, one step = 1 line down
    // All three are wrap-encoded around 0 (MiSTer signed convention), so the
    // all-zero power-on status word is exactly "CRT Adjust Off, everything
    // neutral" -- an untouched user gets the accepted M23/M24 core.
    // The P1/H1 submenu+hide convention follows the upstream CRT Adjust
    // reference; H1 items are gated by status_menumask bit 1 (Main_MiSTer
    // user_io_hd_mask() parses the digit after H, so H1 -> menumask bit 1).
    // `[HW-CONFIRMED BUG]` (owner, 2026-09-22): Confirm on the "CRT Adjust"
    // page row closed the whole OSD instead of opening the submenu. Root
    // cause is CONF_STR ENTRY ORDER, not the P1/H1 syntax. Main_MiSTer
    // menu.cpp draws rows for P/F/S/C/T/R/O/o only (menu.cpp:1997-2196), but
    // its selection loop advances its entry counter for EVERY in-page,
    // non-hidden token whose first character is >= 'A' (menu.cpp:2386-2401).
    // "J1,..." is therefore counted but never drawn, so every selectable row
    // after it actioned the token one position too early. That is also the
    // never-explained M22 Service Mode defect: the drawn "Service 1" row
    // actioned O[4], and the drawn "CRT Adjust" row actioned R[5], whose
    // handler ends with `menustate = MENU_NONE1` -- i.e. closes the OSD
    // (menu.cpp:2615). Fix: keep J1/V last, as the MiSTer core template and
    // every stock core do, so the two undrawn tokens sit past all real rows.
    // Guarded by scripts/test-confstr-menu.ps1.
    // M27 CONFIG VERSION `v,1`. Main_MiSTer stores the 128-bit status word
    // in <core><config_ver>.CFG (user_io.cpp:148-158) and lowercase `v,<n>`
    // sets config_ver to "_v<n>" (user_io.cpp:933-940). M26 SWAPPED THE
    // MEANING of O[7:6]: index 0 used to be the unrotated presentation and
    // index 3 the native 180, and they are now the other way round. A status
    // word saved before M26 therefore restores index 3 and the OSD comes up
    // reading "Flipped" forever -- `[HW-CONFIRMED BUG]` (owner, 2026-09-22).
    // Opening the OSD does NOT rewrite it: MENU_SAVE_CHECK only calls
    // arcade_nvm_save() (menu.cpp), and the status word is written solely by
    // the system menu's "Save settings" item (menu.cpp:3073-3090), so the
    // stale value survives every reload. Bumping the config version is the
    // framework's own remedy: MiSTer starts a fresh CFG, so the all-zero
    // power-on status applies and Orientation defaults to index 0,
    // "Horizontal" -- the native-180 presentation the owner wants. Cost is a
    // one-time reset of this core's other OSD settings to their defaults.
    // Like J1/V, `v` is counted by menu.cpp's selection pass but never drawn,
    // so it MUST stay at the end with them.
    `include "build_id.v"
    localparam CONF_STR = {"NA1;;-;O[3:2],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%;-;O[7:6],Orientation,Horizontal,Vertical CCW,Vertical CW,Flipped;-;O[4],Service Mode,Off,On;-;P1,CRT Adjust;P1O[96],CRT Adjust,Off,On;H1P1O[100:97],CRT H-Size,0,+1,+2,+3,+4,+5,+6,+7,-8,-7,-6,-5,-4,-3,-2,-1;H1P1O[104:101],CRT H-Position,0,+6,+12,+18,+24,+30,+36,+42,-48,-42,-36,-30,-24,-18,-12,-6;H1P1O[108:105],CRT V-Shift,0,+1,+2,+3,+4,+5,+6,+7,-8,-7,-6,-5,-4,-3,-2,-1;-;R[0],Reset;-;J1,Shot,Bomb,Button 3,Start,Coin,Button 6;v,1;V,v",`BUILD_DATE};
    wire forced_scandoubler, direct_video;
    wire [21:0] gamma_bus;
    wire [31:0] joystick_0, joystick_1, joystick_2, joystick_3;
    wire [64:0] rtc;   // M30: hps_io RTC (MSM6242B layout) for na1_rom_board_io
    hps_io #(.CONF_STR(CONF_STR), .WIDE(1)) hps_io (
        .clk_sys(clk_sys), .HPS_BUS(HPS_BUS), .EXT_BUS(),
        .status(status), .buttons(buttons),
        .joystick_0(joystick_0), .joystick_1(joystick_1),
        .joystick_2(joystick_2), .joystick_3(joystick_3),
        .forced_scandoubler(forced_scandoubler), .direct_video(direct_video),
        // M26: H1 CRT-Adjust items are hidden while the master enable is Off
        // (upstream convention: menumask bit 1 gates the H1 entries).
        .status_menumask({14'd0, ~status[96], 1'b0}),
        .gamma_bus(gamma_bus),
        .ioctl_download(download_active), .ioctl_wr(download_wr),
        .ioctl_addr(download_addr), .ioctl_dout(download_data),
        .ioctl_index(download_index), .ioctl_wait(download_wait),
        .ioctl_upload(nvram_upload_active), .ioctl_upload_req(eeprom_dirty),
        .ioctl_upload_index(NVRAM_INDEX[7:0]),
        .ioctl_din(eeprom_nvram_rdata), .ioctl_rd(),
        // M30: MSM6242B-layout BCD date/time for the optional ROM-board RTC.
        .RTC(rtc)
    );
    wire reset_system, reset_maincpu, reset_mcu;
    wire ce_master, ce_68k, ce_mcu;
    (* keep = "true" *) wire [95:0] debug_cpu;
    wire [12:0] peripheral_req,peripheral_ack;
    wire [207:0] peripheral_rdata;
    wire [12:0] transport_ack;
    wire [207:0] transport_rdata;
    // M28B: ONE RBF / MANY MRAs. The MRA delivers a 6-byte runtime BOARD
    // description at ioctl index 2: which KEYCUS part is fitted and on which
    // register it answers, plus (M28B.1) how the cabinet's monitor is mounted
    // and which control panel is wired. No game identity, no GAME_ID, no per-game table --
    // see rtl/na1/na1_config.sv and docs/M28B_IMPLEMENTATION.md. The
    // compiled-in default is F/A's board (`01 5D 01 02 01 00`), so a config-less MRA
    // (including any pre-M28B one) behaves exactly as the accepted M27 core
    // did; the production F/A MRA nevertheless configures it explicitly, so
    // F/A exercises the same runtime path every other game does.
    wire [7:0] keycus_cfg_mode; wire [15:0] keycus_cfg_id; wire [2:0] keycus_cfg_id_offset;
    wire cfg_video_base_flip; wire [7:0] cfg_control_panel;
    wire cfg_rom_board_io;
    na1_config #(.CONFIG_INDEX(BOARD_CFG_INDEX)) config_record(
        .clk_sys(clk_sys),
        .download_active(download_active),.download_wr(download_wr),
        .download_index(download_index),.download_addr(download_addr),
        .download_data(download_data),
        .keycus_mode(keycus_cfg_mode),.keycus_id(keycus_cfg_id),
        .keycus_id_offset(keycus_cfg_id_offset),
        .video_base_flip(cfg_video_base_flip),.control_panel(cfg_control_panel),
        .rom_board_io(cfg_rom_board_io));
    // M24/M26 orientation selector (truth table at the screen_rotate decode
    // below); M28B.1 feeds it the board's base presentation.
    wire [1:0] orient = status[7:6];
    wire flip_native;
    wire keycus_ack; wire [15:0] keycus_rdata;
    na1_keycus keycus(.clk_sys(clk_sys),.reset(reset_system),.req(peripheral_req[5]),
        .write(peripheral_write),.addr(peripheral_addr),.wdata(peripheral_wdata),
        .byte_en(peripheral_byte_en),
        .cfg_mode(keycus_cfg_mode),.cfg_id(keycus_cfg_id),.cfg_id_offset(keycus_cfg_id_offset),
        .ack(keycus_ack),.rdata(keycus_rdata));
    wire palette_ack; wire [15:0] palette_rdata;
    na1_palette palette(.clk_sys(clk_sys),.reset(reset_system),.req(peripheral_req[7]),
        .write(peripheral_write),.addr(peripheral_addr),.wdata(peripheral_wdata),
        .byte_en(peripheral_byte_en),.ack(palette_ack),.rdata(palette_rdata),
        .render_enable(r_palette_enable),.render_word_addr(r_palette_addr),.render_rdata(r_palette_rdata));
    wire additional_ack;
    wire [15:0] additional_rdata;
    wire eeprom_ack;
    wire [15:0] eeprom_rdata;
    wire peripheral_write;
    wire [23:0] peripheral_addr;
    wire [15:0] peripheral_wdata;
    wire [1:0] peripheral_byte_en;
    wire mcu_irq0_request,maincpu_release;
    wire [15:0] mcu_irq0_wdata;
    wire [1:0] mcu_irq0_byte_en;
    wire [127:0] mailbox_state;
    wire [15:0] gfx_selector,irq_mask;
    wire [7:0] irq_position;wire irq_enabled;
    (* keep = "true" *) wire [31:0] debug_irq;
    // M15A internal raster contract (MAME_COMPAT). The M15B renderer consumes
    // it and the M15E transport below carries the result to the framework.
    (* keep = "true" *) wire timing_pixel_ce,timing_visible,timing_hblank,timing_vblank;
    (* keep = "true" *) wire timing_line_event,timing_frame_event;
    wire [7:0] timing_event_line;
    (* keep = "true" *) wire [8:0] timing_beam_x;
    (* keep = "true" *) wire [7:0] timing_beam_y;
    (* keep = "true" *) wire [1:0] timing_profile_id;
    (* keep = "true" *) wire timing_profile_available,timing_hsync,timing_vsync,timing_sync_valid;
    wire cpu_work_req,cpu_work_write,cpu_work_ack;
    wire [17:0] cpu_work_word_addr;
    wire [15:0] cpu_work_wdata,cpu_work_rdata;
    wire [1:0] cpu_work_byte_en;
    wire mailbox_req,mailbox_write,mailbox_ack;
    // M15D authoritative work/shared RAM backend (SDRAM) behind the shared arbiter.
    wire work_req,work_write,work_ack;
    wire [17:0] work_word_addr;
    wire [15:0] work_wdata,work_rdata;
    wire [1:0] work_byte_en;
    wire [2:0] mailbox_slot;
    wire [15:0] mailbox_wdata,mailbox_rdata;
    wire [1:0] mailbox_byte_en;
    na1_m3_transport #(.ENABLE_IRQ(1),.ENABLE_BLIT(1)) transport(.clk_sys(clk_sys),.reset(reset_system),
        .req(c_peripheral_req),.write(c_peripheral_write),.addr(c_peripheral_addr),
        .wdata(c_peripheral_wdata),.byte_en(c_peripheral_byte_en),
        .ack(transport_ack),.rdata(transport_rdata),.mcu_irq0_request(mcu_irq0_request),
        .mcu_irq0_wdata(mcu_irq0_wdata),.mcu_irq0_byte_en(mcu_irq0_byte_en),
        .mailbox_state(mailbox_state),.gfx_selector(gfx_selector),.render_words(vreg_words),
        .blit_registers(blit_registers),.blit_req(blit_req),.blit_ack(blit_ack),
        .irq_mask(irq_mask),.irq_position(irq_position),.irq_enabled(irq_enabled),.mcu_mailbox_req(mailbox_req),
        .mcu_mailbox_write(mailbox_write),.mcu_mailbox_slot(mailbox_slot),
        .mcu_mailbox_wdata(mailbox_wdata),.mcu_mailbox_byte_en(mailbox_byte_en),
        .mcu_mailbox_ack(mailbox_ack),.mcu_mailbox_rdata(mailbox_rdata));
    na1_additional_ram additional(.clk_sys(clk_sys),.reset(reset_system),
        .req(peripheral_req[10]),.write(peripheral_write),.addr(peripheral_addr),
        .wdata(peripheral_wdata),.byte_en(peripheral_byte_en),
        .ack(additional_ack),.rdata(additional_rdata));
    na1_eeprom eeprom(.clk_sys(clk_sys),.reset(reset_system),
        .req(peripheral_req[4]),.write(peripheral_write),.addr(peripheral_addr),
        .wdata(peripheral_wdata),.byte_en(peripheral_byte_en),
        .ack(eeprom_ack),.rdata(eeprom_rdata),
        .nvram_active(nvram_active),.nvram_wr(eeprom_nvram_wr),
        .nvram_addr(download_addr[10:0]),
        .nvram_wdata(download_data),.nvram_rdata(eeprom_nvram_rdata),
        .nvram_write_busy(eeprom_nvram_write_busy),
        .nvram_read_ready(eeprom_nvram_read_ready),
        .nvram_dirty_event(eeprom_dirty_event));
    wire video_ack,scroll_ack,sprite_ack;
    wire [15:0] video_rdata,scroll_rdata,sprite_rdata;
    // M15B renderer read ports on the authoritative local stores.
    wire r_video_enable,r_scroll_enable,r_palette_enable,r_shape_enable,r_sprite_enable;
    wire [14:0] r_video_addr;wire [10:0] r_scroll_addr,r_sprite_addr;wire [11:0] r_palette_addr;wire [13:0] r_shape_addr;
    wire [15:0] r_video_rdata,r_scroll_rdata,r_palette_rdata,r_shape_rdata,r_sprite_rdata;
    wire [2047:0] vreg_words;
    na1_video_ram #(.BASE(24'hff0000),.WORDS(24576),.ADDR_WIDTH(15)) video(
        .clk_sys(clk_sys),.reset(reset_system),.req(peripheral_req[9]),
        .write(peripheral_write),.addr(peripheral_addr),.wdata(peripheral_wdata),
        .byte_en(peripheral_byte_en),.ack(video_ack),.rdata(video_rdata),
        .render_enable(r_video_enable),.render_word_addr(r_video_addr),.render_rdata(r_video_rdata));
    na1_video_ram #(.BASE(24'hffe000),.WORDS(2048),.ADDR_WIDTH(11)) scroll(
        .clk_sys(clk_sys),.reset(reset_system),.req(peripheral_req[11]),
        .write(peripheral_write),.addr(peripheral_addr),.wdata(peripheral_wdata),
        .byte_en(peripheral_byte_en),.ack(scroll_ack),.rdata(scroll_rdata),
        .render_enable(r_scroll_enable),.render_word_addr(r_scroll_addr),.render_rdata(r_scroll_rdata));
    na1_video_ram #(.BASE(24'hfff000),.WORDS(2048),.ADDR_WIDTH(11)) sprite(
        .clk_sys(clk_sys),.reset(reset_system),.req(peripheral_req[12]),
        .write(peripheral_write),.addr(peripheral_addr),.wdata(peripheral_wdata),
        .byte_en(peripheral_byte_en),.ack(sprite_ack),.rdata(sprite_rdata),
        .render_enable(r_sprite_enable),.render_word_addr(r_sprite_addr),.render_rdata(r_sprite_rdata));
    // M8 translation. M15D: character RAM is authoritative in SDRAM, shape RAM
    // is local dual-port storage. No renderer consumes either yet.
    wire gfx_ack;wire [15:0] gfx_rdata;
    wire char_req,char_write,char_ack,shape_req,shape_write,shape_ack;
    wire [16:0] char_word_addr;wire [13:0] shape_word_addr;
    wire [15:0] char_wdata,char_rdata,shape_wdata,shape_rdata;
    wire [1:0] char_byte_en,shape_byte_en;
    na1_gfx gfx(.clk_sys(clk_sys),.reset(reset_system),.req(peripheral_req[8]),
        .write(peripheral_write),.addr(peripheral_addr),.wdata(peripheral_wdata),
        .byte_en(peripheral_byte_en),.selector(gfx_selector),.ack(gfx_ack),.rdata(gfx_rdata),
        .character_req(char_req),.character_write(char_write),.character_word_addr(char_word_addr),
        .character_wdata(char_wdata),.character_byte_en(char_byte_en),
        .character_ack(char_ack),.character_rdata(char_rdata),
        .shape_req(shape_req),.shape_write(shape_write),.shape_word_addr(shape_word_addr),
        .shape_wdata(shape_wdata),.shape_byte_en(shape_byte_en),
        .shape_ack(shape_ack),.shape_rdata(shape_rdata));
    na1_shape_ram shape_storage(.clk_sys(clk_sys),.reset(reset_system),
        .req(shape_req),.write(shape_write),.word_addr(shape_word_addr),
        .wdata(shape_wdata),.byte_en(shape_byte_en),.ack(shape_ack),.rdata(shape_rdata),
        .render_enable(r_shape_enable),.render_word_addr(r_shape_addr),.render_rdata(r_shape_rdata));
    // Disjoint register/mailbox, KEYCUS, EEPROM, palette and RAM slots.
    assign peripheral_ack= {sprite_ack,scroll_ack,additional_ack,video_ack,gfx_ack,palette_ack,1'b0,keycus_ack,eeprom_ack,4'd0};
    assign peripheral_rdata= {sprite_rdata,scroll_rdata,additional_rdata,video_rdata,gfx_rdata,palette_rdata,16'd0,keycus_rdata,eeprom_rdata,64'd0};
    // M16: production C69-startup compatibility sequencer (RAM clear, BIOS
    // vector words, one-clock release) inside the MCU boundary releases the
    // 68000 so genuine F/A executes from the SDRAM program ROM.
    // M18: raw active-low input bytes exactly as the C69 reads them through
    // its P7 multiplexer (MAME namcona1_joy: b7 Start, b6 Button 3, b5 Bomb,
    // b4 Shot, b3 Up, b2 Down, b1 Left, b0 Right; DSW b7 Service 1, b6
    // service-mode switch, b5..b2 Coin 1..4, b1 Test, b0 Freeze). Player 2's
    // coin button feeds coin lane 2. P4 is unconnected on F/A. The service
    // period is the MAME_COMPAT frame event [IMPLEMENTATION].
    // M22: Service 1 (DSW b7) and the service-mode switch (DSW b6) are wired
    // from the new OSD controls above (R[5]/O[4]) so the operator can reach
    // F/A's own EEPROM-backed service menu; Test/Freeze (b1/b0) stay
    // inactive (1), unresearched/no established convention.
    // M20C: C69_GENUINE=1 selects the genuine C69 (na1_c69 behind
    // na1_mcu_interface): the M37702 executes the owner's c69.bin, delivered
    // as index-0 stream bytes $A00000-$A03FFF (appended to the 10 MiB ROM image
    // by the MRA; hps_io WIDE=1 puts stream byte 2k in ioctl_dout[7:0], which
    // is the little-endian low byte the M37702 expects, so the word is stored
    // unchanged) and owns the shared RAM, mailbox, C219 register bus, inputs
    // and the 68000 release itself. The bounded M16/M18 models stay selectable
    // as the fallback (C69_GENUINE=0 restores the accepted M19 build exactly).
    // The line-224 event feeds C69 IRQ1 and the [MAME-CONFIRMED] simulate_mcu
    // $F60 shim (docs/M20B_IMPLEMENTATION.md section 6).
    localparam C69_GENUINE = 1;
    wire startup_active,startup_done,startup_release,input_active;
    wire [15:0] input_periods;
    // M28B.1: the MiSTer-facing panel mapping and the base orientation both
    // come from the board record, in one small module (no game identity).
    wire [7:0] input_p1, input_p2, input_p3, input_p4;
    wire coin_1, coin_2, coin_3, coin_4;
    na1_board_presentation board_presentation(
        .orient(orient),.cfg_base_flip(cfg_video_base_flip),.cfg_panel(cfg_control_panel),
        .joystick_0(joystick_0),.joystick_1(joystick_1),
        .joystick_2(joystick_2),.joystick_3(joystick_3),
        .flip_native(flip_native),
        .input_p1(input_p1),.input_p2(input_p2),
        .input_p3(input_p3),.input_p4(input_p4),
        .coin_1(coin_1),.coin_2(coin_2),.coin_3(coin_3),.coin_4(coin_4));
    // `O[4]`/`status[4]` drives the service-mode switch level (DSW b6)
    // continuously, matching how Coin/other level inputs are already wired
    // (the firmware does its own level debounce).
    // Service 1 (DSW b7) is tied inactive (owner, 2026-09-22). Its `R[5]`
    // OSD row existed only as the M22 workaround for the CONF_STR row/token
    // off-by-one fixed in M26 -- pressing it was what actually toggled
    // `O[4]`. With that fixed, the Service Mode toggle reaches the firmware
    // menu on its own, so the row is gone. status[5] is deliberately NOT
    // referenced here: an `R[]` bit left in a stale saved config would hold
    // Service 1 pressed forever. To restore the control, re-add
    // `R[5],Service 1;` to CONF_STR and put `status[5]` back in bit 7.
    // DSW b5..b2 are Coin 1..4 `[MAME-CONFIRMED]`; M29 wires lanes 3/4 from the
    // third and fourth MiSTer joysticks (previously tied inactive).
    wire [7:0] input_dsw = ~{1'b0, status[4], coin_1, coin_2, coin_3, coin_4, 1'b0, 1'b0};
    // M29: the MCU BIOS moved from stream $600000 to $A00000 because the mask
    // ROM now occupies the full 8 MiB ($200000-$9FFFFF). $A00000>>14 = 13'h280.
    // The part itself is c69.bin or c70.bin -- same 16 KiB M37702 internal ROM
    // port, selected only by which file the MRA names (no RTL "C70 mode").
    wire c69_rom_we = download_active && download_index == 16'd0 && download_wr &&
                      !download_addr[0] && download_addr[26:14] == 13'h0280;
    // M32: the MCU's IRQ1 and the $F60 shim follow the 68000's IRQ4 to the end
    // of the visible window (frame_event), keeping MAME's MCU/68000 phase.
    wire scanline224_event = timing_frame_event;
    wire c69_c219_req,c69_c219_write;wire [8:0] c69_c219_addr;wire [7:0] c69_c219_wdata;
    wire c69_c219_ack;wire [7:0] c69_c219_rdata;
    na1_mcu_interface #(.GENUINE_ENABLE(C69_GENUINE),.FA_HELPER_ENABLE(!C69_GENUINE),
                        .STARTUP_ENABLE(!C69_GENUINE),.INPUT_ENABLE(!C69_GENUINE)) mcu(.clk_sys(clk_sys),.reset(reset_system),
        .input_tick(timing_frame_event),.input_p1(input_p1),.input_p2(input_p2),
        .input_p3(input_p3),.input_p4(input_p4),
        .input_dsw(input_dsw),.input_active(input_active),.input_periods(input_periods),
        .irq0_request(mcu_irq0_request),.irq0_wdata(mcu_irq0_wdata),
        .irq0_byte_en(mcu_irq0_byte_en),.mailbox_state(mailbox_state),
        .backend_maincpu_release(1'b0),.maincpu_reset_release(maincpu_release),
        .startup_active(startup_active),.startup_done(startup_done),.startup_release(startup_release),
        .cpu_req(cpu_work_req),.cpu_write(cpu_work_write),
        .cpu_word_addr(cpu_work_word_addr),.cpu_wdata(cpu_work_wdata),
        .cpu_byte_en(cpu_work_byte_en),.cpu_ack(cpu_work_ack),.cpu_rdata(cpu_work_rdata),
        .work_req(work_req),.work_write(work_write),.work_word_addr(work_word_addr),
        .work_wdata(work_wdata),.work_byte_en(work_byte_en),
        .work_ack(work_ack),.work_rdata(work_rdata),
        .mailbox_req(mailbox_req),.mailbox_write(mailbox_write),.mailbox_slot(mailbox_slot),
        .mailbox_wdata(mailbox_wdata),.mailbox_byte_en(mailbox_byte_en),
        .mailbox_ack(mailbox_ack),.mailbox_rdata(mailbox_rdata),
        .completion_event(),.completion_count(),.helper_busy(),
        .mcu_req(),.mcu_write(),.mcu_word_addr(),.mcu_wdata(),.mcu_byte_en(),
        .mcu_ack(),.mcu_rdata(),
        .ce_mcu(ce_mcu),.scanline_event(scanline224_event),
        .rom_we(c69_rom_we),.rom_waddr(download_addr[13:1]),.rom_wdata(download_data),
        .c219_req(c69_c219_req),.c219_write(c69_c219_write),.c219_addr(c69_c219_addr),.c219_wdata(c69_c219_wdata),
        .c219_ack(c69_c219_ack),.c219_rdata(c69_c219_rdata),
        .genuine_release(),.shim_write());
    na1 machine (
        .clk_sys(clk_sys),
        .reset_async(RESET | !pll_locked | status[0] | buttons[1] | download_active),
        .maincpu_reset_release(maincpu_release),
        .irq_enabled(irq_enabled),.irq_mask(irq_mask),.irq_position(irq_position),.debug_irq(debug_irq),
        .reset_system(reset_system), .reset_maincpu(reset_maincpu),
        .reset_mcu(reset_mcu), .ce_master(ce_master),
        .ce_68k(ce_68k), .ce_mcu(ce_mcu),
        .cpu_req(m_cpu_req), .cpu_write(m_cpu_write), .cpu_addr(m_cpu_addr),
        .cpu_wdata(m_cpu_wdata), .cpu_byte_en(m_cpu_byte_en), .cpu_rdata(), .cpu_ack(m_cpu_ack), .debug_cpu(debug_cpu),
        .work_req(c_work_req),.work_write(c_work_write),
        .work_word_addr(c_work_word_addr),.work_wdata(c_work_wdata),
        .work_byte_en(c_work_byte_en),.work_rdata(c_work_rdata),.work_ack(c_work_ack),
        .region(), .peripheral_req(c_peripheral_req), .peripheral_write(c_peripheral_write), .peripheral_addr(c_peripheral_addr),
        .peripheral_wdata(c_peripheral_wdata), .peripheral_byte_en(c_peripheral_byte_en),
        .peripheral_ack(c_peripheral_ack), .peripheral_rdata(c_peripheral_rdata),
        .rom_req(c_rom_req), .rom_image(c_rom_image), .rom_word_addr(c_rom_word_addr), .rom_rdata(c_rom_rdata), .rom_ack(c_rom_ack),
        .load_valid(1'b0), .load_image(1'b0), .load_word_addr(22'd0),
        .load_data(16'd0), .load_ready(), .load_rejected(),
        .storage_valid(), .storage_image(), .storage_word_addr(), .storage_data(),
        .storage_ready(1'b0),
        .download_active(download_active), .download_wr(download_wr),
        .download_addr(download_addr), .download_data(download_data),
        .download_index(download_index), .download_wait(),
        .timing_pixel_ce(timing_pixel_ce),.timing_beam_x(timing_beam_x),
        .timing_beam_y(timing_beam_y),.timing_visible(timing_visible),
        .timing_hblank(timing_hblank),.timing_vblank(timing_vblank),
        .timing_line_event(timing_line_event),.timing_frame_event(timing_frame_event),
        .timing_event_line(timing_event_line),
        .timing_profile_id(timing_profile_id),.timing_profile_available(timing_profile_available),
        .timing_hsync(timing_hsync),.timing_vsync(timing_vsync),.timing_sync_valid(timing_sync_valid)
    );
    wire runtime_rom_req,runtime_rom_image,runtime_rom_ack;
    wire [21:0] runtime_rom_word_addr;
    wire [15:0] runtime_rom_rdata;
    // M30: optional ROM-board I/O (board record byte 6). Transparent unless the
    // record says the ROM PCB fits the MSM6242 RTC + status port (X-Day 2's
    // M112 board); then it answers $D80000 and $DC0000-$DC001F in place of the
    // program ROM. Only the CPU's ROM reads pass through it -- blitter sources
    // still read ROM, exactly as MAME's blit() reads m_prgrom.
    wire io_rom_req,io_rom_ack;wire [15:0] io_rom_rdata;
    na1_rom_board_io rom_board_io(.clk_sys(clk_sys),.reset(reset_system),.enable(cfg_rom_board_io),
        .rtc(rtc),
        .rom_req(c_rom_req),.rom_image(c_rom_image),.rom_word_addr(c_rom_word_addr),
        .rom_ack(c_rom_ack),.rom_rdata(c_rom_rdata),
        .down_req(io_rom_req),.down_ack(io_rom_ack),.down_rdata(io_rom_rdata),
        .cpu_req(m_cpu_req),.cpu_write(m_cpu_write),.cpu_addr(m_cpu_addr),.cpu_wdata(m_cpu_wdata),
        .cpu_byte_en(m_cpu_byte_en),.cpu_ack(m_cpu_ack));
    na1_blitter_fabric dma(
      .clk_sys(clk_sys),
      .reset(reset_system),
      .blit_req(blit_req),
      .blit_registers(blit_registers),
      .blit_ack(blit_ack),
      .blit_fault(blit_fault),
      .direct_ack(transport_ack),
      .direct_rdata(transport_rdata),
      .cpu_work_req(c_work_req),
      .work_req(cpu_work_req),
      .cpu_work_write(c_work_write),
      .work_write(cpu_work_write),
      .cpu_work_ack(c_work_ack),
      .work_ack(cpu_work_ack),
      .cpu_work_word_addr(c_work_word_addr),
      .work_word_addr(cpu_work_word_addr),
      .cpu_work_wdata(c_work_wdata),
      .work_wdata(cpu_work_wdata),
      .cpu_work_rdata(c_work_rdata),
      .work_rdata(cpu_work_rdata),
      .cpu_work_byte_en(c_work_byte_en),
      .work_byte_en(cpu_work_byte_en),
      .cpu_rom_req(io_rom_req),
      .rom_req(runtime_rom_req),
      .cpu_rom_image(c_rom_image),
      .rom_image(runtime_rom_image),
      .cpu_rom_ack(io_rom_ack),
      .rom_ack(runtime_rom_ack),
      .cpu_rom_word_addr(c_rom_word_addr),
      .rom_word_addr(runtime_rom_word_addr),
      .cpu_rom_rdata(io_rom_rdata),
      .rom_rdata(runtime_rom_rdata),
      .cpu_peripheral_req(c_peripheral_req),
      .peripheral_req(peripheral_req),
      .cpu_peripheral_write(c_peripheral_write),
      .peripheral_write(peripheral_write),
      .cpu_peripheral_addr(c_peripheral_addr),
      .peripheral_addr(peripheral_addr),
      .cpu_peripheral_wdata(c_peripheral_wdata),
      .peripheral_wdata(peripheral_wdata),
      .cpu_peripheral_byte_en(c_peripheral_byte_en),
      .peripheral_byte_en(peripheral_byte_en),
      .cpu_peripheral_ack(c_peripheral_ack),
      .peripheral_ack(peripheral_ack),
      .cpu_peripheral_rdata(c_peripheral_rdata),
      .peripheral_rdata(peripheral_rdata)
    );
    // M15C/M15D: one authoritative SDRAM holding ROM (CPU/blitter), work RAM
    // and character RAM. The prefetch client is driven by the M15B renderer.
    wire sdram_req,sdram_rnw,sdram_ready,sdram_busy;
    wire [25:0] sdram_word_addr;
    wire [15:0] sdram_wdata;
    wire [1:0] sdram_byte_en;
    wire [63:0] sdram_q;
    wire prefetch_req,prefetch_ack;wire [14:0] prefetch_row;wire [63:0] prefetch_data;
    // M20A: C219 sample reads are a fifth (round-robin) client on the work RAM.
    wire audio_req,audio_ack;wire [15:0] audio_row;wire [63:0] audio_data;
    na1_sdram_memory memory(
      .clk_sys(clk_sys),.reset_runtime(reset_system),.reset_controller(!pll_locked),
      .rom_req(runtime_rom_req),.rom_image(runtime_rom_image),
      .rom_word_addr(runtime_rom_word_addr),.rom_ack(runtime_rom_ack),
      .rom_rdata(runtime_rom_rdata),.download_active(download_active),
      .download_wr(download_wr),.download_index(download_index),
      .download_addr(download_addr),.download_data(download_data),
      .download_wait(rom_download_wait),
      .work_req(work_req),.work_write(work_write),.work_word_addr(work_word_addr),
      .work_wdata(work_wdata),.work_byte_en(work_byte_en),
      .work_ack(work_ack),.work_rdata(work_rdata),
      .char_req(char_req),.char_write(char_write),.char_word_addr(char_word_addr),
      .char_wdata(char_wdata),.char_byte_en(char_byte_en),
      .char_ack(char_ack),.char_rdata(char_rdata),
      .prefetch_req(prefetch_req),.prefetch_row(prefetch_row),
      .prefetch_ack(prefetch_ack),.prefetch_data(prefetch_data),
      .audio_req(audio_req),.audio_row(audio_row),.audio_ack(audio_ack),.audio_data(audio_data),
      .phy_req(sdram_req),.phy_rnw(sdram_rnw),.phy_word_addr(sdram_word_addr),
      .phy_wdata(sdram_wdata),.phy_byte_en(sdram_byte_en),
      .phy_ready(sdram_ready),.phy_rdata(sdram_q),.phy_busy(sdram_busy));
    // M15B/M19 production renderer (layers 0..3 + sprites), driven by the M15A
    // MAME_COMPAT beam. Its pixel stream feeds the M15E transport and the
    // framework's arcade_video below.
    wire pix_valid,pix_visible;wire [8:0] pix_x;wire [7:0] pix_y;
    wire [11:0] pix_index;wire [14:0] pix_rgb555;wire [23:0] pix_rgb;
    wire render_busy;wire [15:0] render_overruns,render_lines;
    // M24 orientation selector (full truth table at the screen_rotate decode
    // below). Declared here because the renderer is its first consumer.
    // M28B.1: `flip_native` is no longer a bare decode of the selector -- the
    // board record supplies the BASE presentation, so "Horizontal" is whatever
    // that board's cabinet actually needs and "Flipped" is its opposite. With
    // F/A's record (base flip = 1) this is bit-identical to the M24/M26 decode.
    // `orient`/`flip_native` are declared with the board record above.
    na1_renderer #(.DEPTH(4)) renderer(
      .clk_sys(clk_sys),.reset(reset_system),
      .pixel_ce(timing_pixel_ce),.beam_x(timing_beam_x),.beam_y(timing_beam_y),
      .beam_visible(timing_visible),.line_event(timing_line_event),.event_line(timing_event_line),
      .flip_native(flip_native),
      .video_enable(r_video_enable),.video_word_addr(r_video_addr),.video_rdata(r_video_rdata),
      .scroll_enable(r_scroll_enable),.scroll_word_addr(r_scroll_addr),.scroll_rdata(r_scroll_rdata),
      .palette_enable(r_palette_enable),.palette_word_addr(r_palette_addr),.palette_rdata(r_palette_rdata),
      .shape_enable(r_shape_enable),.shape_word_addr(r_shape_addr),.shape_rdata(r_shape_rdata),
      .sprite_enable(r_sprite_enable),.sprite_word_addr(r_sprite_addr),.sprite_rdata(r_sprite_rdata),
      .vreg(vreg_words),
      .prefetch_req(prefetch_req),.prefetch_row(prefetch_row),
      .prefetch_ack(prefetch_ack),.prefetch_data(prefetch_data),
      .out_valid(pix_valid),.out_visible(pix_visible),.out_x(pix_x),.out_y(pix_y),
      .out_index(pix_index),.out_rgb555(pix_rgb555),.out_rgb(pix_rgb),.out_shadow(),
      .busy(render_busy),.overrun_count(render_overruns),.lines_rendered(render_lines));
    sdram rom_sdram(
      .init(!pll_locked),.clk(clk_sys),.SDRAM_DQ(SDRAM_DQ),.SDRAM_A(SDRAM_A),
      .SDRAM_DQML(SDRAM_DQML),.SDRAM_DQMH(SDRAM_DQMH),.SDRAM_BA(SDRAM_BA),
      .SDRAM_nCS(SDRAM_nCS),.SDRAM_nWE(SDRAM_nWE),.SDRAM_nRAS(SDRAM_nRAS),
      .SDRAM_nCAS(SDRAM_nCAS),.SDRAM_CKE(SDRAM_CKE),.SDRAM_CLK(SDRAM_CLK),
      .ch1_addr(sdram_word_addr),.ch1_dout(sdram_q),.ch1_din(sdram_wdata),
      .ch1_be(sdram_byte_en),
      .ch1_req(sdram_req),.ch1_rnw(sdram_rnw),.ch1_ready(sdram_ready),
      .ch2_addr(26'd0),.ch2_dout(),.ch2_din(32'd0),.ch2_req(1'b0),
      .ch2_rnw(1'b1),.ch2_ready(),.ch3_addr(24'd0),.ch3_dout(),
      .ch3_din(16'd0),.ch3_req(1'b0),.ch3_rnw(1'b1),.ch3_ready());

    // M15E/M23 video transport: the free-running beam supplies ce_pix and the
    // sync/blanking, the renderer supplies the colour. M23 [IMPLEMENTATION]:
    // the physical raster is the PS6406B envelope borrowed from the working
    // Arcade-PsikyoSH2_MiSTer core (456x263 @ 7.15909 MHz, 15.70 kHz /
    // 59.70 Hz, 32-dot HSync, 3-line VSync) with F/A's 304x224 logical image
    // centred in it; it never stops (reset, ROM download), so a CRT stays
    // locked while MiSTer shows its loading bar. See rtl/na1/na1_video_timing.sv
    // and docs/M23_RESEARCH.md. Not physical NA-1 timing. CLK_VIDEO is clk_sys.
    wire vt_ce_pix,vt_hblank,vt_vblank,vt_hsync,vt_vsync;
    wire [23:0] vt_rgb;
    na1_video_transport transport_video(
      .clk_sys(clk_sys),
      .pixel_ce(timing_pixel_ce),.beam_visible(timing_visible),
      .beam_hblank(timing_hblank),.beam_vblank(timing_vblank),
      .beam_hsync(timing_hsync),.beam_vsync(timing_vsync),
      .in_valid(pix_valid),.in_visible(pix_visible),.in_rgb(pix_rgb),
      .ce_pix(vt_ce_pix),.rgb(vt_rgb),.hblank(vt_hblank),.vblank(vt_vblank),
      .hsync(vt_hsync),.vsync(vt_vsync),.de(),.visible());
    // ------------------------------------------------------------------
    // M26 CRT Adjust (presentation only; M23 transport and M24 orientation
    // are untouched). Upstream: MiSTer-CRT-Adjust by Umberto Parisi
    // (rmonic79), GPL-3.0-or-later; rtl/vendor/crt_adjust.sv is vendored
    // BYTE-IDENTICAL and all integration lives in the glue below. V-Size
    // (crt_vsize.sv) is deliberately NOT vendored or exposed: it retimes the
    // line rate and narrows HSync, which would break the HW-confirmed M23
    // envelope (docs/M26_RESEARCH.md section 9).
    //
    // The module resizes/repositions CONTENT through a line buffer while the
    // sync stays native, so H total (456), V total (263), HSync/VSync width,
    // line/frame frequency and the transport pixel CE are all unchanged.
    // It is downstream of the beam, so it cannot affect line_event, IRQ3/IRQ4,
    // the renderer, the CPU, C69/C219 or SDRAM.
    //
    // NOTE (accepted, documented): with this core-side insertion point the
    // adjusted stream also reaches HDMI while CRT Adjust is On. Off (the
    // default) leaves HDMI exactly as before. Isolating HDMI would require
    // editing sys/sys_top.v, which this project does not do.
    // All four controls are sampled once per frame (at the beam's frame_event,
    // inside vertical blanking) rather than used combinationally. Changing them
    // mid-frame disturbs the line-buffer engine for that frame -- observed in
    // sim/m26_crt_adjust_tb.sv as a frame with no active video -- so latching
    // makes every frame internally consistent and a control change simply takes
    // effect at the next frame. Same idiom as M24's flip_l.
    reg         crt_on   = 1'b0;
    reg  signed [3:0] crt_hsize_s = 4'sd0;   // -8..+7, + = WIDER
    reg  signed [3:0] crt_hpos_s  = 4'sd0;   // -8..+7, one step = 6 px right
    reg  signed [3:0] crt_vsh_s   = 4'sd0;   // -8..+7, one step = 1 line down
    always @(posedge clk_sys) if (timing_frame_event) begin
        crt_on      <= status[96];
        crt_hsize_s <= $signed(status[100:97]);
        crt_hpos_s  <= $signed(status[104:101]);
        crt_vsh_s   <= $signed(status[108:105]);
    end
    // Gate the adjust off while the scandoubler is active (upstream integration
    // rule: the module targets the native 15 kHz stream).
    wire        crt_sd_off = (status[3:2] == 2'd0) && !forced_scandoubler;
    wire        crt_act  = crt_on && crt_sd_off;
    // H-Position in output pixels (6 px per step) and V-Shift in lines, sized
    // to the module's signed ports (9-bit hoffset, 6-bit voffset).
    // NOTE: a bare size cast like 9'(crt_hpos_s) evaluates UNSIGNED and turns
    // -1 into +511; sign-extend explicitly (caught by sim/m26_crt_adjust_tb.sv).
    wire signed [8:0] crt_hoffset = crt_act ? ($signed({{5{crt_hpos_s[3]}},crt_hpos_s}) * 9'sd6) : 9'sd0;
    wire signed [5:0] crt_voffset = crt_act ? $signed({{2{crt_vsh_s[3]}},crt_vsh_s}) : 6'sd0;
    // Read-rate generator. At H-Size neutral the module is fed the ACTUAL M23
    // pixel CE, so the read side counts exactly the same pulses as the write
    // side and the content is reproduced byte-exact (structural identity, not
    // an approximation). For H-Size != 0 an exact rational NCO of the SAME
    // form na1_video_timing.sv uses generates the adjusted rate:
    //     READ_INC = PIXEL_HZ - hsize*STEP,  STEP = round(PIXEL_HZ/100)
    // giving exactly 1.000% per step (step-size error 0.00014%). Positive
    // hsize lowers the read rate -> slower read -> WIDER picture.
    // Max READ_INC = 7,159,090 + 8*71,591 = 7,731,818, so the worst-case sum
    // is 99,999,999 + 7,731,818 = 107,731,817 < 2^27: same 27-bit phase /
    // 28-bit sum as M23. The accumulator is re-phased on every hs_ref_out
    // rise so every line gets an identical read-tick pattern.
    localparam integer CRT_SYS_HZ   = 100000000;
    localparam integer CRT_PIXEL_HZ = 7159090;
    localparam integer CRT_STEP     = 71591;
    wire crt_hs_ref;
    reg  crt_hs_ref_d = 1'b0;
    always @(posedge clk_sys) crt_hs_ref_d <= crt_hs_ref;
    wire crt_hs_ref_rise = crt_hs_ref && !crt_hs_ref_d;
    wire signed [31:0] crt_read_inc = CRT_PIXEL_HZ - (crt_hsize_s * CRT_STEP);
    reg [26:0] crt_phase = 27'd0;
    wire [27:0] crt_phase_sum = {1'b0, crt_phase} + crt_read_inc[26:0];
    wire crt_rd_tick = (crt_phase_sum >= CRT_SYS_HZ);
    always @(posedge clk_sys) begin
        if (crt_hs_ref_rise)   crt_phase <= 27'd0;
        else if (crt_rd_tick)  crt_phase <= crt_phase_sum - CRT_SYS_HZ;
        else                   crt_phase <= crt_phase_sum[26:0];
    end
    // Hybrid read CE: the real M23 CE whenever H-Size is neutral (or the
    // feature is off), the NCO only when actually resizing.
    wire crt_rd_ce = (!crt_act || crt_hsize_s == 4'sd0) ? vt_ce_pix : crt_rd_tick;
    wire [23:0] crt_rgb;
    wire crt_hs, crt_vs, crt_hb, crt_vb;
    // HPOS_MODE 0 = HPOS_SYNCSHIFT. Upstream documents CONTENTSHIFT (mode 1)
    // as being for wide/centred games and SYNCSHIFT for "narrow / side-anchored
    // games with a wide asymmetric H back-porch", where CONTENTSHIFT runs the
    // content out of the buffer window. F/A is exactly that shape: the active
    // 304 px sit at write-pointer 104..407 of a 456-dot line, i.e. 104 dots of
    // blanking before and only 48 after. CONTENTSHIFT was measured losing the
    // whole active window at negative hoffset (sim/m26_crt_adjust_tb.sv), so
    // SYNCSHIFT is used: it delays HSync through a line-length shift register,
    // redistributing front/back porch while H total (456), the line period and
    // the pulse width all stay native. The read-rate accumulator is reset on
    // hs_ref_out (the SHIFTED HSync), which is what SYNCSHIFT requires.
    crt_adjust #(.VTOTAL(263),.HTOTAL(456),.HPOS_MODE(0)) crt_adjust(
      .clk(clk_sys),.pxl_cen(vt_ce_pix),.pxl2_cen(crt_rd_ce),
      .active(crt_act),
      .hsize($signed({crt_hsize_s[3],crt_hsize_s})),.hoffset(crt_hoffset),.voffset(crt_voffset),
      .r_in(vt_rgb[23:16]),.g_in(vt_rgb[15:8]),.b_in(vt_rgb[7:0]),
      .hs_in(vt_hsync),.vs_in(vt_vsync),.hb_in(vt_hblank),.vb_in(vt_vblank),
      .r_out(crt_rgb[23:16]),.g_out(crt_rgb[15:8]),.b_out(crt_rgb[7:0]),
      .hs_out(crt_hs),.vs_out(crt_vs),.hb_out(crt_hb),.vb_out(crt_vb),
      .hs_ref_out(crt_hs_ref));
    // TRUE external bypass: with CRT Adjust Off the raw M23 transport stream
    // goes straight to arcade_video, so the accepted M23/M24 output is
    // reproduced with zero added latency -- not merely "the module configured
    // neutrally".
    wire        av_ce_pix = crt_act ? crt_rd_ce  : vt_ce_pix;
    wire [23:0] av_rgb    = crt_act ? crt_rgb    : vt_rgb;
    wire        av_hblank = crt_act ? crt_hb     : vt_hblank;
    wire        av_vblank = crt_act ? crt_vb     : vt_vblank;
    wire        av_hsync  = crt_act ? crt_hs     : vt_hsync;
    wire        av_vsync  = crt_act ? crt_vs     : vt_vsync;
    arcade_video #(.WIDTH(304),.DW(24),.GAMMA(1)) arcade_video(
      .clk_video(clk_sys),.ce_pix(av_ce_pix),.RGB_in(av_rgb),
      .HBlank(av_hblank),.VBlank(av_vblank),.HSync(av_hsync),.VSync(av_vsync),
      .CLK_VIDEO(CLK_VIDEO),.CE_PIXEL(CE_PIXEL),
      .VGA_R(VGA_R),.VGA_G(VGA_G),.VGA_B(VGA_B),
      .VGA_HS(VGA_HS),.VGA_VS(VGA_VS),.VGA_DE(VGA_DE),.VGA_SL(VGA_SL),
      .fx({1'b0,status[3:2]}),.forced_scandoubler(forced_scandoubler),.gamma_bus(gamma_bus));
    // M21: standard MiSTer HDMI/scaler rotation. screen_rotate (sys/arcade_video.v)
    // sits downstream of the framework's own arcade_video/video_mixer output
    // above; it never touches the renderer, transport, beam/IRQ timing or
    // SDRAM. F/A is MAME ROT90; rotate_ccw=0 (matching the published 1942
    // MiSTer core, also ROT90) was the initial guess and is now
    // [HW-CONFIRMED] correct (owner, DE10-Nano, 2026-09-21): rotating with
    // rotate_ccw=0 produces the intended portrait presentation on HDMI with
    // no mirroring, and the unrotated mode restores the original
    // presentation; aspect/presentation are correct in both.
    // M23: the analog/native output is ALWAYS live, independent of HDMI
    // rotation. The earlier `VGA_DISABLE = video_rotated` coupling forced
    // VGA_HS/VS constant whenever Orientation=Vert (the default), i.e. no
    // CRT sync at all until the owner switched to Horz [HW-CONFIRMED].
    // Working reference cores (Arcade-PsikyoSH2_MiSTer `VGA_DISABLE = 0`,
    // ZN1 likewise) keep the native raster on the analog pins while the
    // HDMI/scaler path shows the rotated framebuffer: framebuffer rotation
    // is a presentation transform, not a video source. As upstream cores
    // do, rotation is also bypassed automatically when MiSTer's global
    // Direct Video is on, so the HDMI path then carries the native raster.
    // M24 orientation decode. One 2-bit selector, O[7:6]:
    //
    //   orient  OSD label      native/CRT   HDMI/scaler   no_rotate rotate_ccw flip_native
    //   00      Horizontal     180          180           1         x          1
    //   01      Vertical CCW   normal       90 CW         0         0          0
    //   10      Vertical CW    normal       90 CCW        0         1          0
    // The two vertical OSD labels were swapped (owner, 2026-09-22) with no
    // RTL change: index 0 is now the native 180-degree presentation, so the
    // same scaler rotation the framework calls CW now reaches the cabinet as
    // CCW. Labels describe the observed result, not screen_rotate's argument.
    //   11      Flipped        normal       normal        1         x          0
    // M26 (owner request, 2026-09-22): the two non-rotating modes were SWAPPED.
    // What M24 shipped as "Flipped" (the native 180-degree presentation) is the
    // orientation the cabinet actually needs, so it is now index 0 "Horizontal"
    // and therefore the power-on default; the former unrotated "Horizontal" is
    // now index 3 "Flipped". Only this decode line changed -- the renderer
    // transform, screen_rotate wiring and CW/CCW behaviour are untouched.
    //
    // CW/CCW are framebuffer (screen_rotate -> MISTER_FB -> HDMI scaler)
    // modes only: a 90-degree rotation transposes the image and would require
    // retiming the native raster, which M23 forbids, so the CRT keeps showing
    // the native orientation there -- the same behaviour as the reference
    // cores. Flipped is applied upstream inside the renderer, before the
    // output branches, so it appears on BOTH outputs while screen_rotate
    // stays idle. screen_rotate's own `flip` input is therefore permanently
    // 0 and is never used by this feature.
    wire no_rotate = (orient != 2'd1 && orient != 2'd2) | direct_video;
    wire rotate_ccw = (orient == 2'd2); // [HW-CONFIRMED] 0 = screen_rotate CW
                                        // (OSD label "Vertical CCW", see above)
    wire flip = 1'b0;                   // M24: native flip is upstream; never used
    wire video_rotated;
    screen_rotate screen_rotate(.*);
    assign VGA_DISABLE = 1'b0;
    assign VGA_F1 = 1'b0;
    assign VGA_SCALER = 1'b0;
    // Native raster is 304x224 (4:3-ish); ARX/ARY swap with orientation so
    // the reported aspect ratio matches whichever image (rotated or not) is
    // actually being displayed, per established upstream-core convention.
    assign VIDEO_ARX = no_rotate ? 13'd4 : 13'd3;
    assign VIDEO_ARY = no_rotate ? 13'd3 : 13'd4;
    assign HDMI_FREEZE = 1'b0;
    assign HDMI_BLACKOUT = 1'b0;
    assign HDMI_BOB_DEINT = 1'b0;
    // M20A: Namco C219 PCM engine [MAME-CONFIRMED contract] at MAME's 44.1 kHz
    // cadence [IMPLEMENTATION; physical rate UNKNOWN], reading its samples from
    // the shared work RAM in SDRAM. Output is 16-bit signed stereo held between
    // samples; the framework resamples it (AUDIO_S=1, no mixing). M20C: the
    // register port is driven by the genuine C69 (C69_GENUINE=1); with the
    // bounded backend nothing drives it. With AUDIO_SELFTEST=1 (debug builds
    // only, never released) a wiring self-test keys one F/A effect every 2 s
    // from the uploaded sample set instead.
`ifdef NA1_AUDIO_SELFTEST
    localparam AUDIO_SELFTEST = 1; // debug build: quartus_map --verilog_macro=NA1_AUDIO_SELFTEST=1
`else
    localparam AUDIO_SELFTEST = 0;
`endif
    wire audio_tick;
    na1_audio_tick #(.CLK(100000000),.RATE(44100)) audio_tick_gen(.clk_sys(clk_sys),.reset(reset_system),.tick(audio_tick));
    wire c219_req,c219_write,c219_ack;wire [8:0] c219_addr;wire [7:0] c219_wdata,c219_rdata;
    wire signed [15:0] audio_left,audio_right;
    generate if(AUDIO_SELFTEST) begin: selftest
      na1_c219_selftest selftest(.clk_sys(clk_sys),.reset(reset_system),.arm(startup_done),
        .reg_req(c219_req),.reg_write(c219_write),.reg_addr(c219_addr),.reg_wdata(c219_wdata),.reg_ack(c219_ack));
      assign c69_c219_ack=1'b0;assign c69_c219_rdata=8'd0;
    end else if(C69_GENUINE) begin: genuine_driver
      assign c219_req=c69_c219_req;assign c219_write=c69_c219_write;
      assign c219_addr=c69_c219_addr;assign c219_wdata=c69_c219_wdata;
      assign c69_c219_ack=c219_ack;assign c69_c219_rdata=c219_rdata;
    end else begin: no_driver
      assign c219_req=1'b0;assign c219_write=1'b0;assign c219_addr=9'd0;assign c219_wdata=8'd0;
      assign c69_c219_ack=1'b0;assign c69_c219_rdata=8'd0;
    end endgenerate
    na1_c219 c219(.clk_sys(clk_sys),.reset(reset_system),.sample_tick(audio_tick),
      .reg_req(c219_req),.reg_write(c219_write),.reg_addr(c219_addr),.reg_wdata(c219_wdata),
      .reg_ack(c219_ack),.reg_rdata(c219_rdata),
      .mem_req(audio_req),.mem_row(audio_row),.mem_ack(audio_ack),.mem_data(audio_data),
      .out_left(audio_left),.out_right(audio_right),.out_valid(),.overruns(),.fetches());
    assign AUDIO_L = audio_left;
    assign AUDIO_R = audio_right;
    assign AUDIO_S = 1'b1;
    assign AUDIO_MIX = 2'd0;
    assign LED_USER = reset_maincpu;
    // M31 diagnostic: the DE10-Nano disk LED lights for ~0.2 s after any
    // renderer line overrun (a line whose render did not finish within one
    // raster line; it is then shown half-drawn and the next line is skipped).
    // Observation only -- nothing in the video path depends on it.
    reg [15:0] overrun_seen=0;reg [24:0] overrun_led=0;
    always @(posedge clk_sys) begin
        overrun_seen<=render_overruns;
        if(render_overruns!=overrun_seen) overrun_led<=25'd20000000;
        else if(overrun_led!=0) overrun_led<=overrun_led-1'b1;
    end
    assign LED_DISK = {1'b0, overrun_led!=0};
    assign {LED_POWER,BUTTONS} = 4'd0;
    assign ADC_BUS = 'z;
    assign USER_OUT = '1;
    assign {UART_RTS,UART_TXD,UART_DTR} = 3'd0;
    assign {SD_SCK,SD_MOSI,SD_CS} = 'z;
    // DDR3 (DDRAM_*) is driven only by screen_rotate above (the M21 HDMI/
    // scaler rotation framebuffer); all NA-1 game state/memory still lives
    // exclusively in SDRAM, unchanged.
endmodule
