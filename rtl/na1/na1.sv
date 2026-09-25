// Machine boundary: FX68K plus replaceable MAME-compatible interrupt timing.
module na1(
    input wire clk_sys, input wire reset_async,
    input wire maincpu_reset_release,
    input wire irq_enabled, input wire [15:0] irq_mask, input wire [7:0] irq_position,
    output wire [31:0] debug_irq,
    output wire iack_service, output wire [2:0] iack_level,
    output wire iack_active, output wire vpa_n,
    output wire reset_system, output wire reset_maincpu, output wire reset_mcu,
    output wire ce_master, output wire ce_68k, output wire ce_mcu,
    output wire cpu_req, output wire cpu_write, output wire [23:0] cpu_addr,
    output wire [15:0] cpu_wdata, output wire [1:0] cpu_byte_en,
    output wire [15:0] cpu_rdata, output wire cpu_ack,
    output wire work_req, output wire work_write, output wire [17:0] work_word_addr,
    output wire [15:0] work_wdata, output wire [1:0] work_byte_en,
    input wire [15:0] work_rdata, input wire work_ack,
    output wire [12:0] region, output wire [12:0] peripheral_req,
    output wire peripheral_write, output wire [23:0] peripheral_addr,
    output wire [15:0] peripheral_wdata, output wire [1:0] peripheral_byte_en,
    input wire [12:0] peripheral_ack, input wire [207:0] peripheral_rdata,
    output wire rom_req, output wire rom_image, output wire [21:0] rom_word_addr,
    input wire [15:0] rom_rdata, input wire rom_ack,
    input wire load_valid, input wire load_image, input wire [21:0] load_word_addr,
    input wire [15:0] load_data, output wire load_ready, output wire load_rejected,
    output wire storage_valid, output wire storage_image,
    output wire [21:0] storage_word_addr, output wire [15:0] storage_data,
    input wire storage_ready,
    // Uninterpreted MiSTer download stream; no loader or ROM layout in M0.
    input wire download_active, input wire download_wr,
    input wire [26:0] download_addr, input wire [15:0] download_data,
    input wire [15:0] download_index,
    output wire download_wait,
    // M15A pixel-pipeline contract. No renderer consumes this yet.
    output wire timing_pixel_ce, output wire [8:0] timing_beam_x,
    output wire [7:0] timing_beam_y, output wire timing_visible,
    output wire timing_hblank, output wire timing_vblank,
    output wire timing_line_event, output wire timing_frame_event,
    output wire [7:0] timing_event_line,
    output wire [1:0] timing_profile_id, output wire timing_profile_available,
    output wire timing_hsync, output wire timing_vsync, output wire timing_sync_valid,
    output wire [95:0] debug_cpu
);
    na1_reset resets(.*);
    wire ce_68k_phi2;
    wire [2:0] irq_level;
    wire pending3,pending4,event3,event4;
    // M15A production timing source. The old M11 module remains test-only.
    na1_video_timing timing(.clk_sys(clk_sys),.reset(reset_system),
        .irq_position(irq_position),.profile_id(timing_profile_id),
        .profile_available(timing_profile_available),.pixel_ce(timing_pixel_ce),
        .beam_x(timing_beam_x),.beam_y(timing_beam_y),.visible(timing_visible),
        .hblank(timing_hblank),.vblank(timing_vblank),
        .line_event(timing_line_event),.frame_event(timing_frame_event),
        .event_line(timing_event_line),.irq3_event(),.irq4_event(),
        .hsync(timing_hsync),.vsync(timing_vsync),.sync_valid(timing_sync_valid));
    // M32: IRQ4 at the end of the visible window (frame_event), not line 224.
    na1_interrupts #(.VBLANK_AT_LINE224(0)) interrupts(.clk_sys(clk_sys),.reset(reset_system),.cpu_reset(reset_maincpu),
        .vblank(timing_frame_event),
        .tick(timing_line_event),.line(timing_event_line),.enabled(irq_enabled),.mask(irq_mask),.position(irq_position),
        .iack_service(iack_service),.iack_level(iack_level),.pending3(pending3),.pending4(pending4),
        .level(irq_level),.event3(event3),.event4(event4));
    assign debug_irq={3'd0,vpa_n,iack_active,iack_service,iack_level,irq_level,
        pending4,pending3,event4,event3,irq_enabled,timing_line_event,timing_event_line,6'd0};
    na1_clock_enables enables(.clk_sys(clk_sys), .reset(reset_system),
        .ce_master(ce_master), .ce_68k(ce_68k), .ce_mcu(ce_mcu),
        .ce_68k_phi2(ce_68k_phi2));
    wire [71:0] debug_native;
    na1_cpu maincpu(.clk_sys(clk_sys),.reset(reset_maincpu),
        .en_phi1(ce_68k),.en_phi2(ce_68k_phi2),.irq_level(irq_level),
        .iack_service(iack_service),.iack_level(iack_level),
        .iack_active(iack_active),.vpa_n(vpa_n),.cpu_req(cpu_req),
        .cpu_write(cpu_write),.cpu_addr(cpu_addr),.cpu_wdata(cpu_wdata),
        .cpu_byte_en(cpu_byte_en),.cpu_rdata(cpu_rdata),.cpu_ack(cpu_ack),
        .debug_native(debug_native));
    // [71:0] native; [84:72] selected region; [85] request; [86] ack;
    // [87] release event; [88] system reset; [89] MCU reset; upper bits zero.
    assign debug_cpu={6'd0,reset_mcu,reset_system,maincpu_reset_release,
        cpu_ack,cpu_req,region,debug_native};
    na1_memory memory(.reset(reset_system), .*);
    na1_rom_loader loader(.valid(load_valid), .image(load_image),
        .word_addr(load_word_addr), .data(load_data), .ready(load_ready),
        .rejected(load_rejected), .storage_valid(storage_valid),
        .storage_image(storage_image), .storage_word_addr(storage_word_addr),
        .storage_data(storage_data), .storage_ready(storage_ready));
    // MRA/ioctl image layout is unresolved. Refuse raw downloads, rather than
    // silently accepting/dropping data. Logical loader is available above.
    assign download_wait = download_active;
endmodule
