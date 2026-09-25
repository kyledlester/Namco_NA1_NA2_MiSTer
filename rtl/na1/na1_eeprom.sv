// M6: MAME-compatible NA-1 lower-lane EEPROM transport, $E00000-$E00FFF.
// Capture -> synchronous storage access -> held response. Hold tuple until
// ack, then withdraw for >=1 clock edge. No EEPROM program/busy delay.
// M22: na1_eeprom_storage is restored to its proven single-write-port
// structure (the earlier two-write-port version failed RAM inference
// entirely: 14,170 ALMs / 16,408 registers, 0 memory bits -- see
// docs/M22_IMPLEMENTATION.md "M22 fit failure"). Standard MiSTer NVRAM
// persistence instead arbitrates this module's one storage port between
// ordinary CPU transactions and the ioctl NVRAM stream.
//
// Arbitration contract: `nvram_active` must be held for the WHOLE
// download/upload session (not pulsed per word). While it is high, new
// CPU transactions are held in IDLE (the same held-request contract used
// throughout this project -- the 68000 simply sees wait states); a CPU
// transaction already mid-ACCESS when a session starts is allowed to
// finish its one storage cycle first (the NVRAM sequencer stalls that one
// cycle and retries), so the two sides can never drive the shared port in
// the same cycle. Because CPU transactions can only start while
// `nvram_active` is low, this single-cycle boundary case is the only
// possible overlap.
//
// `nvram_wr` pulses once per 16-bit hps_io WIDE=1 download word;
// `nvram_addr` is the even ioctl byte offset of that word (nvram_addr+1 is
// the odd/high byte) and must stay stable for the whole session -- it maps
// 1:1 onto this module's existing `cell_addr` numbering, so no repacking
// is needed. For upload, a free-running two-read sequencer keeps
// `nvram_rdata` is refreshed from the current `nvram_addr` by a synchronous
// two-read sequence.  The caller must use `nvram_write_busy` and
// `nvram_read_ready` to backpressure hps_io: the SPI word cadence is not slow
// enough to hide this RAM latency on real hardware.
module na1_eeprom(
    input wire clk_sys,reset,req,write,
    input wire [23:0] addr,input wire [15:0] wdata,
    input wire [1:0] byte_en,
    output wire ack,output wire [15:0] rdata,
    input wire nvram_active,nvram_wr,
    input wire [10:0] nvram_addr,input wire [15:0] nvram_wdata,
    output reg [15:0] nvram_rdata,
    output wire nvram_write_busy,nvram_read_ready,
    // M22: one clk_sys cycle high exactly when a genuine CPU write commits
    // to storage (lower lane only -- the only access that actually
    // modifies a cell, see the upper-lane note below). The caller uses
    // this to raise a real NVRAM-dirty/save request tied to actual
    // EEPROM writes, not a periodic signal -- see NA1.sv and
    // docs/M22_IMPLEMENTATION.md "EEPROM upload-request: event-driven
    // correction". Never asserted for the NVRAM ioctl download/restore
    // path (that only ever drives storage through the separate nv_write
    // path below, not cpu_grant), so restoring a saved image does not
    // itself mark the EEPROM dirty again.
    output wire nvram_dirty_event
);
    localparam IDLE=0,ACCESS=1,RESPONSE=2;
    reg [1:0] state=IDLE;
    reg held_write=0,held_lower=0;
    reg [10:0] held_cell_addr=0;
    reg [7:0] held_wdata=0;
    wire selected=req && addr>=24'he00000 && addr<=24'he00fff;
    wire cpu_grant=!reset && state==ACCESS;
    wire [7:0] storage_rdata;
    assign ack=!reset && selected && state==RESPONSE;
    // The unconnected upper lane is zero in MAME's NA-1 map. Upper-only
    // accesses complete normally but return zero and never modify a cell.
    assign rdata=ack && !held_write && held_lower ? {8'd0,storage_rdata} : 16'd0;

    // --- NVRAM ioctl sequencer: shares the one storage port below ---
    // `nvram_wr` is only a single-cycle pulse from the caller (mirroring
    // hps_io's own one-cycle-per-word download strobe) and can arrive at
    // any point in the free-running read-refresh loop below, so it is
    // latched unconditionally the instant it appears (never gated by the
    // read loop's current sub-state) and always preempts that loop at the
    // next safe boundary -- a write already in progress (WLO/WHI) is
    // always allowed to finish first, so a byte pair is never half-written.
    localparam NV_RLO=0,NV_RHI=1,NV_RPUB=2,NV_WLO=3,NV_WHI=4;
    reg [2:0] nv_state=NV_RLO;
    reg [10:0] nv_raddr=0,nv_waddr=0;
    reg [15:0] nv_wdata_lat=0;
    reg [7:0] nv_lo=0;
    reg nv_wr_pending=0;
    reg [10:0] nv_addr_prev=0;
    reg [10:0] nv_rdata_addr=0;
    reg nv_rdata_valid=0;
    wire nv_addr_changed=nvram_addr!=nv_addr_prev;
    assign nvram_write_busy=nv_wr_pending;
    assign nvram_read_ready=nvram_active && nv_rdata_valid &&
                            nv_rdata_addr==nvram_addr;
    wire nv_drives=nvram_active && !cpu_grant &&
        (nv_state==NV_RLO || nv_state==NV_RHI || nv_state==NV_WLO || nv_state==NV_WHI);
    wire nv_write=nvram_active && !cpu_grant && (nv_state==NV_WLO || nv_state==NV_WHI);
    wire [10:0] nv_cell_addr=(nv_state==NV_RLO) ? nvram_addr :
                              (nv_state==NV_RHI) ? (nv_raddr+11'd1) :
                              (nv_state==NV_WLO) ? nv_waddr : (nv_waddr+11'd1);
    wire [7:0] nv_wdata_byte=(nv_state==NV_WLO) ? nv_wdata_lat[7:0] : nv_wdata_lat[15:8];

    // Latch: catches nvram_wr the cycle it arrives, regardless of nv_state.
    // M27 ROOT-CAUSE FIX: this latch and the sequencer below must NOT be gated
    // by `reset`. NA1.sv feeds `reset_async` with `download_active`, which
    // hps_io asserts for EVERY ioctl index -- including index 1, the NVRAM
    // restore itself. Gating on `reset` therefore held `nv_wr_pending` cleared
    // and `nv_state` pinned at NV_RLO for the whole restore, so `nv_write`
    // never asserted and not one byte of a saved .nvm ever reached storage.
    // The image was silently swallowed on every core load, F/A's signature
    // check then failed and it rewrote operator defaults -- exactly the
    // "settings do not survive a core reload" symptom, and exactly why saving
    // appeared to work (the upload path runs with ioctl_download low, so
    // `reset` is not asserted there). See docs/M27_RESEARCH.md item 8.
    // `!nvram_active` alone is the correct idle condition: the session flag
    // already bounds this logic, and while it is high `cpu_grant` is
    // necessarily low (it is `!reset && state==ACCESS`, and the CPU state
    // machine cannot leave IDLE while `nvram_active` is high), so the storage
    // port is uncontested no matter what `reset` is doing.
    always @(posedge clk_sys) begin
        if(!nvram_active) begin
            nv_wr_pending<=0;
        end else begin
            if(nvram_wr && !nv_wr_pending) begin
                nv_wr_pending<=1;nv_waddr<=nvram_addr;nv_wdata_lat<=nvram_wdata;
            end else if(nv_state==NV_WHI && !cpu_grant) begin
                nv_wr_pending<=0; // consumed: the burst completes this cycle
            end
        end
    end
    // Sequencer: a pending write always preempts the read-refresh loop at
    // its next boundary (RLO/RHI/RPUB), but a write already in progress
    // (WLO/WHI) always runs to completion first. Independently, if
    // `nvram_addr` changes (the upload caller moved to a new word) while
    // idle in the read loop, restart at NV_RLO immediately -- otherwise a
    // read already in flight for the OLD address could finish and publish
    // a stale word onto `nvram_rdata` under the NEW address's name. This
    // bounds the loop's response to any address change to <=4 cycles with
    // no window where a wrong-address result can be observed.
    always @(posedge clk_sys) begin
        if(!nvram_active) begin            // M27: not `reset` -- see the latch above
            nv_state<=NV_RLO;
            nv_addr_prev<=nvram_addr;
            nv_rdata_valid<=0;
        end else if(!cpu_grant) begin
            nv_addr_prev<=nvram_addr;
            case(nv_state)
                NV_WLO: nv_state<=NV_WHI;
                NV_WHI: nv_state<=NV_RLO;
                NV_RLO: if(nv_wr_pending) nv_state<=NV_WLO;
                        else begin nv_raddr<=nvram_addr;nv_state<=NV_RHI; end
                NV_RHI: if(nv_wr_pending) nv_state<=NV_WLO;
                        else if(nv_addr_changed) nv_state<=NV_RLO;
                        else begin nv_lo<=storage_rdata;nv_state<=NV_RPUB; end
                NV_RPUB: if(nv_wr_pending) nv_state<=NV_WLO;
                         else if(nv_addr_changed) nv_state<=NV_RLO;
                         else begin
                             nvram_rdata<={storage_rdata,nv_lo};
                             nv_rdata_addr<=nv_raddr;
                             nv_rdata_valid<=1;
                             nv_state<=NV_RLO;
                         end
                default: nv_state<=NV_RLO;
            endcase
        end
        // else: a CPU access already in flight owns the port this cycle;
        // nv_state holds unchanged and retries next cycle.
    end

    wire storage_enable=cpu_grant || nv_drives;
    wire cpu_write_commit=cpu_grant && held_write && held_lower;
    wire storage_write=cpu_grant ? (held_write && held_lower) : nv_write;
    wire [10:0] storage_cell_addr=cpu_grant ? held_cell_addr : nv_cell_addr;
    wire [7:0] storage_wdata=cpu_grant ? held_wdata : nv_wdata_byte;
    assign nvram_dirty_event=cpu_write_commit;
    na1_eeprom_storage storage(.clk_sys(clk_sys),.enable(storage_enable),
        .write(storage_write),.cell_addr(storage_cell_addr),
        .wdata(storage_wdata),.rdata(storage_rdata));

    always @(posedge clk_sys) begin
        if(reset) begin
            state<=IDLE;held_write<=0;held_lower<=0;
            held_cell_addr<=0;held_wdata<=0;
        end else case(state)
            IDLE: if(selected && !nvram_active) begin
                held_write<=write;held_lower<=byte_en[0];
                held_cell_addr<=addr[11:1];held_wdata<=wdata[7:0];state<=ACCESS;
            end
            ACCESS: if(selected) state<=RESPONSE;else state<=IDLE;
            RESPONSE: if(!selected) state<=IDLE;
            default: state<=IDLE;
        endcase
    end
endmodule
