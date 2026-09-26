#!/usr/bin/env python3
"""Cycle model of the NA1 video source through the MiSTer framework's own
video path, used to prove the CE_PIXEL contract (docs/VIDEO_CE_FIX.md).

ModelSim ASE 17 cannot compile sys/video_mixer.sv, scandoubler.v, hq2x.sv,
gamma_corr.sv or hps_io.sv, so their relevant registers are transcribed here
with exact posedge semantics (every next-state value is computed from the
current values, then committed):

  na1_video_timing   pixel CE ("div14" = production exact /14,
                     "nco" = the pre-fix 7,159,090/100 MHz accumulator), beam
  na1_video_transport 3-clock delay, register on d_ce[2]
  arcade_video       CE edge detect + latch (sync_fix is combinational)
  video_freezer      pass-through (freeze = 0)
  gamma_corr         gamma off: one-pixel CE-edge pipeline
  scandoubler        pix_len/pixsz, input sampler ce_x1i/r_d, output
                     ce_x2o/ce_x4o, sd_hcnt/hde/hs_out, hbo shift
  video_mixer        CE_PIXEL / hde / VGA_DE on CE_PIXEL, for Fx None,
                     HQ2x (ce_x4o) and CRT 25/50% (ce_x2o)
  hps_io video_calc  vid_pixrep

Checks, per output line: the framework-visible active width is constant
(304 with Fx None / CRT, 608 with HQ2x), the scandoubler captured source
pixels 0..303 in order, and vid_pixrep is always 14.

Usage: python scripts/video_ce_model.py [div14|nco] [frames]
Exit status 0 only when every check holds (use "nco" to reproduce the bug).
"""
import sys
from collections import Counter, deque

MODE = sys.argv[1] if len(sys.argv) > 1 else "div14"
FRAMES = int(sys.argv[2]) if len(sys.argv) > 2 else 3
SYS, PIX = 100_000_000, 7_159_090           # only used by the "nco" mode
HT, HVIS, HS0, HS1 = 456, 304, 352, 383

def run():
    phase = 0; div = 0; bx = 0; by = 0; pad = 0; padc = 0
    hist = deque([(0, 0, 0, 0, 0)] * 4, maxlen=4)
    t_rgb = -1; t_hs = 0; t_hb = 1; t_ce = 0
    a_oldce = 0; a_CE = 0; a_HS = 0; a_rgb = -1; a_HBL = 1
    g_old = 0; g_in = (-1, 0, 1); g_rgb = -1; g_hs = 0; g_hb = 1
    s_old = 0; pix_len = 0; pix_in = 0; pixsz = 0; p2 = 0; p4 = 0; valid = 0; s_hs = 0; ce_x1i = 0
    po = 0; x4o = 0; x2o = 0; o_hs = 0; hs_out = 0; sdh = 0; hcnt = 0
    hde_s = hde_e = hs_s = hs_e = 0; so_hs = 0; so_hb = 1; hbo = [1] * 9
    # video_mixer, three Fx variants: 0 = None, 1 = HQ2x, 2 = CRT (scandoubler, no hq2x)
    m = [dict(ce=0, hde=0, old=0, de=0, cnt=0) for _ in range(3)]
    widths = [Counter() for _ in range(3)]
    old_hs_line = [0, 0, 0]
    pcnt = 0; od = 0; od1 = 0; pixrep = Counter()
    captured = []; cap = Counter(); frames = 0
    while frames < FRAMES + 1:
        # ---- combinational ----
        if MODE == "nco":
            ps = phase + PIX; pce = ps >= SYS
        else:
            pce = div == 13
        hb = bx >= HVIS; vis = (not hb) and (not pad) and by >= 32
        hs = HS0 <= bx <= HS1
        cur = (pce, bx, vis, hs, hb)   # beam sample accepted on this pce
        d2 = hist[-3]                  # the sample from three clocks ago
        live = frames >= 1
        # ---- timing ----
        if MODE == "nco":
            phase = ps - SYS if pce else ps
        else:
            div = 0 if pce else div + 1
        if pce:
            if bx == HT - 1:
                bx = 0
                if pad:
                    if padc == 6: pad = 0; padc = 0; by = 0
                    else: padc += 1
                elif by == 255: pad = 1; padc = 0; by = 0; frames += 1
                else: by += 1
            else: bx += 1
        # ---- transport ----
        n_t_ce = d2[0]
        if d2[0]: n_t = (d2[1] if d2[2] else -1, d2[3], d2[4])
        else: n_t = (t_rgb, t_hs, t_hb)
        # ---- arcade_video ----
        n_a = (0, a_HS, a_rgb, a_HBL)
        if (not a_oldce) and t_ce: n_a = (1, t_hs, t_rgb, t_hb)
        n_a_old = t_ce
        # ---- gamma_corr (edge of a_CE) ----
        n_g = (g_in, g_rgb, g_hs, g_hb)
        if (not g_old) and a_CE: n_g = ((a_rgb, a_HS, a_HBL), g_in[0], g_in[1], g_in[2])
        n_g_old = a_CE
        # ---- scandoubler input ----
        pl = pix_len + 1; pc = pix_in + 1
        n_pix_len = pl if pix_len < 255 else pix_len
        n_pix_in = pc if pix_in < 255 else pix_in
        n_x1 = 0; n_pixsz, n_p2, n_p4, n_valid = pixsz, p2, p4, valid
        if (not s_old) and a_CE:
            if valid and not g_hb: n_pixsz, n_p2, n_p4 = pl, pl >> 1, pl >> 2
            n_pix_len = 0; n_valid = 1
        if ((not s_hs) and g_hs) or pc >= pixsz: n_x1 = 1; n_pix_in = 0
        if g_hb: n_valid = 0
        if ce_x1i and g_rgb >= 0: captured.append(g_rgb)
        # ---- scandoubler output ----
        pco = po + 1; n_po = pco if po < 255 else po; n_x4 = 0; n_x2 = 0
        if pco in (p4, p2, p2 + p4): n_x4 = 1
        if pco == p2: n_x2 = 1
        if ((not o_hs) and hs_out) or pco >= pixsz: n_x2 = 1; n_x4 = 1; n_po = 0
        n_hbo = hbo[:]
        if x4o: n_hbo[1:9] = hbo[0:8]
        n_sdh = sdh + 1; n_hs_out = hs_out; n_hcnt = hcnt + 1
        n_hs_ = [hde_s, hde_e, hs_s, hs_e]
        if sdh == hde_s: n_sdh = 0; n_hbo[0] = 0
        if sdh == hde_e: n_hbo[0] = 1
        if sdh == hs_e: n_hs_out = 0
        if sdh == hs_s: n_hs_out = 1
        if so_hb and not g_hb: n_hs_[0] = hcnt >> 1; n_hbo[0] = 0; n_hcnt = 0; n_sdh = 0
        if (not so_hb) and g_hb: n_hs_[1] = hcnt >> 1
        if so_hs and not g_hs: n_hs_[3] = hcnt >> 1
        if (not so_hs) and g_hs: n_hs_[2] = hcnt >> 1
        # ---- video_mixer: CE_PIXEL, hde, VGA_DE on CE_PIXEL ----
        srcs = [(a_CE, 0 if g_hb else 1, g_hs),          # Fx None (fs_osc path == CE)
                (x4o, 0 if hbo[6] else 1, hs_out),       # HQ2x
                (x2o, 0 if hbo[6] else 1, hs_out)]       # CRT 25/50%
        for i, (ce_src, hde_src, hs_line) in enumerate(srcs):
            v = m[i]; n = dict(v)
            n['ce'] = ce_src; n['hde'] = hde_src
            if v['ce']:
                n['old'] = v['hde']
                if v['old'] != v['hde']: n['de'] = v['hde']
                if n['de']: n['cnt'] = v['cnt'] + 1
            if hs_line and not old_hs_line[i]:
                if live and n['cnt']: widths[i][n['cnt']] += 1
                n['cnt'] = 0
            old_hs_line[i] = hs_line
            m[i] = n
        # ---- hps_io video_calc vid_pixrep on the Fx None CE_PIXEL ----
        if a_CE:
            de = 1 if a_rgb >= 0 else 0
            if (not od1) and od and live: pixrep[pcnt] += 1
            od1 = od; od = de; pcnt = 1
        else: pcnt += 1
        # ---- scandoubler capture check, per input line ----
        if (not s_hs) and g_hs:
            if live and captured:
                ok = captured == list(range(304))
                cap['ok' if ok else 'bad'] += 1
            captured = []
        # ---- commit ----
        hist.append(cur)
        # registers that sample the *current* (pre-edge) value of other regs
        s_hs, s_old, so_hs, so_hb = g_hs, a_CE, g_hs, g_hb
        t_ce = n_t_ce; t_rgb, t_hs, t_hb = n_t
        a_CE, a_HS, a_rgb, a_HBL = n_a; a_oldce = n_a_old
        g_in, g_rgb, g_hs, g_hb = n_g; g_old = n_g_old
        pix_len, pix_in, ce_x1i, pixsz, p2, p4, valid = n_pix_len, n_pix_in, n_x1, n_pixsz, n_p2, n_p4, n_valid
        po, x4o, x2o, o_hs, hbo, sdh, hs_out, hcnt = n_po, n_x4, n_x2, hs_out, n_hbo, n_sdh, n_hs_out, n_hcnt
        hde_s, hde_e, hs_s, hs_e = n_hs_
    return widths, cap, pixrep


def main():
    widths, cap, pixrep = run()
    names = ["Fx None", "HQ2x", "CRT 25/50%"]
    expect = [304, 608, 304]
    ok = True
    print(f"mode={MODE} frames={FRAMES}")
    for n, w, e in zip(names, widths, expect):
        good = set(w) == {e}
        ok &= good
        print(f"  {n:11s} framework active width per line: {dict(w)}  expect {{{e}}}  {'OK' if good else 'FAIL'}")
    good = cap.get('bad', 0) == 0 and cap.get('ok', 0) > 0
    ok &= good
    print(f"  scandoubler input capture (304 px in order per line): {dict(cap)}  {'OK' if good else 'FAIL'}")
    good = set(pixrep) == {14}
    ok &= good
    print(f"  hps_io vid_pixrep samples: {dict(pixrep)}  expect {{14}}  {'OK' if good else 'FAIL'}")
    print(("PASS" if ok else "FAIL") + " VIDEO CE FRAMEWORK MODEL")
    return 0 if ok else 1

if __name__ == "__main__":
    sys.exit(main())
