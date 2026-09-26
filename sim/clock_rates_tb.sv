`timescale 1ns/1ps
// VIDEO_CE_FIX: emulated clock rates are unchanged in real time after the
// clk_sys change (docs/VIDEO_CE_FIX.md, tests 15-18).
//
// For the production SYS_HZ = 100,226,000 (= 2 x the 50.113 MHz master) and the
// Option A fallback SYS_HZ = 100,000,000, over N clk_sys cycles:
//   ce_master count == floor(N * 50,113,000 / SYS_HZ)  (exact average master)
//   ce_68k/ce_mcu count == floor(master / 4)           (12.52825 MHz)
//   audio_tick count == floor(N * 44,100 / SYS_HZ)     (C219 44.1 kHz)
// checked at every tick, i.e. the accumulators never lose or gain a tick, so
// the long-run rate in real time is exactly the target at that clk_sys.
// Production cadence is additionally exact: ce_master every 2 clk, ce_68k every
// 8 clk, phi2 exactly 4 clk after phi1.
// The RTC second (na1_rom_board_io) is a plain CLK_HZ-cycle counter; NA1.sv
// passing CLK_HZ = SYS_HZ is checked statically by scripts/test-video-ce.ps1.
module clock_rates_tb;
    reg clk=0; always #5 clk=~clk;
    reg reset=1;
    localparam integer SYS_D2=100_226_000, SYS_A=100_000_000, MASTER=50_113_000, RATE=44_100;
    localparam integer N=3_000_000;

    wire m_d2,c_d2,u_d2,p2_d2,a_d2, m_a,c_a,u_a,p2_a,a_a;
    na1_clock_enables #(.SYS_HZ(SYS_D2)) en_d2(.clk_sys(clk),.reset(reset),.ce_master(m_d2),.ce_68k(c_d2),.ce_mcu(u_d2),.ce_68k_phi2(p2_d2));
    na1_clock_enables #(.SYS_HZ(SYS_A))  en_a (.clk_sys(clk),.reset(reset),.ce_master(m_a),.ce_68k(c_a),.ce_mcu(u_a),.ce_68k_phi2(p2_a));
    na1_audio_tick #(.CLK(SYS_D2),.RATE(RATE)) at_d2(.clk_sys(clk),.reset(reset),.tick(a_d2));
    na1_audio_tick #(.CLK(SYS_A),.RATE(RATE))  at_a (.clk_sys(clk),.reset(reset),.tick(a_a));

    integer checks=0;
    task check(input cond,input [8*120-1:0] msg);
        begin checks=checks+1; if(!cond) $fatal(1,"CLOCK RATES check failed: %0s",msg); end
    endtask

    // counts are compared against the exact integer formula after every cycle
    longint n=0, cm_d2=0, cc_d2=0, ca_d2=0, cm_a=0, cc_a=0, ca_a=0;
    integer bad_d2=0, bad_a=0, gap_bad=0, last_m=-1, last_c=-1, last_p1=-1, phi_bad=0, mcu_bad=0;
    always @(posedge clk) if(!reset) begin
        n=n+1;
        if(m_d2) begin cm_d2=cm_d2+1; if(last_m>=0 && n-last_m!=2) gap_bad=gap_bad+1; last_m=n; end
        if(c_d2) begin cc_d2=cc_d2+1; if(last_c>=0 && n-last_c!=8) gap_bad=gap_bad+1; last_c=n; last_p1=n; end
        if(p2_d2 && last_p1>=0 && n-last_p1!=4) phi_bad=phi_bad+1;
        if(u_d2!==c_d2 || u_a!==c_a) mcu_bad=mcu_bad+1;
        if(a_d2) ca_d2=ca_d2+1;
        if(m_a) cm_a=cm_a+1; if(c_a) cc_a=cc_a+1; if(a_a) ca_a=ca_a+1;
        // tick k happens on the cycle where floor(n*F/SYS) first reaches k
        // (audio_tick is a registered pulse, hence n-1)
        if(cm_d2!=(n*MASTER)/SYS_D2 || cc_d2!=cm_d2/4 || ca_d2!=((n-1)*RATE)/SYS_D2) bad_d2=bad_d2+1;
        if(cm_a !=(n*MASTER)/SYS_A  || cc_a !=cm_a/4  || ca_a !=((n-1)*RATE)/SYS_A)  bad_a=bad_a+1;
    end

    initial begin
        repeat(5) @(posedge clk); @(negedge clk); reset=0;
        wait(n==N);
        check(bad_d2==0,"D2 (100.226 MHz): master/68k/MCU/audio tick counts track the exact rational rate every cycle");
        check(bad_a==0,"Option A (100 MHz): same, exact rational rates");
        check(gap_bad==0,"D2: ce_master every 2 clk, ce_68k every 8 clk, no exceptions");
        check(phi_bad==0,"D2: FX68K phi2 exactly 4 clk (two master ticks) after phi1");
        check(mcu_bad==0,"ce_mcu == ce_68k");
        $display("CLOCK RATES over %0d clk: D2 master %0d (= N/2), 68k %0d, audio %0d; A master %0d, 68k %0d, audio %0d",
            N,cm_d2,cc_d2,ca_d2,cm_a,cc_a,ca_a);
        $display("  real-time rates: master %0d Hz, 68000/MCU %0.2f Hz, C219 %0d Hz at either clk_sys",MASTER,MASTER/4.0,RATE);
        $display("PASS CLOCK RATES: %0d checks",checks);
        $finish;
    end
endmodule
