# Video CE / pixel-clock and orientation investigation

Status: **research only.** No RTL changed, nothing built, nothing committed.
Baseline: `Namco_NA1_NA2_MiSTer` `main` @ `720ebb4` (public repo; the video path
is identical to the private `Arcade-NA1_MiSTer` @ `b3696ff` except the post-beta
black-border change in `na1_renderer.sv`, which does not touch timing).
Date: 2026-09-25.

Trigger: external MiSTer developer feedback:

> "I think your ce_pixel is wrong. Scaling artifacts on the mister scaler,
> doesn't work with a 4k scaler at all. Also, something is going on with your
> orientation setting. it's flipping analog video for any setting other than
> horizontal (so you can have it say "vertical ccw" and the analog signal is cw)."

Evidence tags: `[HW-CONFIRMED]` owner hardware, `[MAME-CONFIRMED]` MAME source,
`[REFERENCE-CONFIRMED]` other RTL / framework source read this session,
`[MODEL-CONFIRMED]` cycle model of the actual RTL run this session (Appendix A),
`[INFERRED]`, `[UNKNOWN]`.

---

## 0. Summary (answers to the 19 report questions)

| # | Question | Answer |
|---|---|---|
| 1 | Clock tree | One PLL output: `clk_sys` = 100.000 MHz from `CLK_50M`. `CLK_VIDEO` = `clk_sys`. `SDRAM_CLK` = inverted `clk_sys` via `altddio_out`. Everything else (50.113 MHz master, 12.528 MHz 68000/MCU, 7.159 MHz pixel, 44.1 kHz audio) is a **fractional clock enable** on `clk_sys`. |
| 2 | CE_PIXEL generator | 27-bit phase accumulator in `na1_video_timing.sv`: `phase += 7,159,090`, CE when the sum reaches `100,000,000`. |
| 3 | Average pixel frequency | exactly **7,159,090 Hz** (= 57.27272 MHz / 8, copied from PsikyoSH2). |
| 4 | CE spacing | **not constant**: 13 or 14 `clk_sys` cycles (mean 13.968). ~3.2 % of gaps are 13, one every 31–32 pixels. The phase is never re-aligned, so the pattern differs line to line. |
| 5 | Raster | 456 × 263 total, 304 × 224 active, 32-dot HSync, 3-line VSync → 15,699.76 Hz / 59.6949 Hz. Line = 6,369 or 6,370 `clk_sys` (alternating). |
| 6 | CE vs raster, on average | Yes, exactly: 456 × 263 × 59.6949 = 7,159,090. **The average is correct. The per-pixel CE is not an integer division of `CLK_VIDEO`.** |
| 7 | Framework contract | CE_PIXEL is a one-`CLK_VIDEO` pulse per pixel; all video changes happen on it (we do this correctly). `video_mixer` also says `CLK_VIDEO` "should be multiple by (ce_pix*4)", i.e. a **constant integer** number of `CLK_VIDEO` cycles per pixel. The scandoubler, `hps_io` `vid_pixrep` and Direct Video HDMI all depend on that. We break it. |
| 8 | Known-good cores | PsikyoSH2: 57.27272 MHz `clk_sys` = `CLK_VIDEO`, pixel = ÷8 **constant**. ZN1 / SYSTEM11: dedicated 53.693175 MHz `clk_vid`, pixel = ÷4…÷10 **constant**. None of them uses a fractional pixel CE. |
| 9 | Real bug? | **Yes, both reports describe real bugs.** The CE finding is proven by a cycle model of our own RTL through the framework's own scandoubler and `hps_io` logic, with a ÷14 control run that makes every symptom go away. The orientation finding is proven by reading the RTL decode. |
| 10 | Mechanism | (a) Scandoubler on (Scandoubler Fx HQ2x/CRT 25 %/CRT 50 %, or `forced_scandoubler`): the scandoubler re-derives its output pixel rate from the **last measured** CE gap, so scandoubled lines come out 304, 303 or **315** pixels wide (5.5 % and 1.7 % of lines), and ascal gets that. (b) Direct Video: HDMI runs at `CLK_VIDEO` = 100 MHz, and the core reports one integer pixel-repetition value (`vid_pixrep`) to Main_MiSTer. Main puts that value in the **DV1** SPD InfoFrame. Ours reads 14 on ~97 % of lines and **13** on ~3 %. Neither is the true 13.968, and the HDMI line length changes between 6,369 and 6,370 clocks. |
| 11 | 4K scaler | Probably yes. A 4K external scaler fed by MiSTer Direct Video decodes it with the DV1 pixel-repetition value (Main_MiSTer `spd_config_update()`). Decimating by 14 drifts 0.7 px over the active line, and decimating by 13 gives a 326-px line. We don't know how the reporter connected it, so this still needs checking (§5.4, §11). |
| 12 | Orientation truth table | §8. Vertical CW/CCW drop the board's **base flip**. On F/A, the only `base_flip = 1` board, the analog / Direct Video output therefore turns 180° as soon as a Vertical mode is chosen. On all `base_flip = 0` boards, the HDMI CW/CCW labels are the wrong way round. |
| 13 | Orientation: bug or UX? | **Both, and mostly a bug** (their case C/D): the native flip is **deactivated** for CW/CCW even though Horizontal has it on. This is a regression from M26/M28B.1, not something M24 designed. The CW/CCW wording is also ambiguous, which is a UX problem on top. |
| 14 | Minimal fix | **CE:** replace the fractional NCO with an exact ÷14 of the existing 100 MHz `clk_sys`, keeping the 456 × 263 raster. **Orientation:** two decode lines: `flip_native = base_flip ^ (orient==3)` and `rotate_ccw = (orient==1)`. |
| 15 | What changes | CE generator only (`na1_video_timing.sv`), plus the matching constants in `NA1.sv`'s CRT Adjust glue. Orientation touches only `na1_board_presentation.sv` and the `NA1.sv` decode line. The transport, `clk_sys`, PLL, SDRAM clock, renderer and framework are **not** touched. |
| 16 | Risks | Line rate −0.23 % (15.664 kHz), frame rate 59.695 → 59.559 Hz, so game speed changes by the same amount. The renderer gets 14.5 more clocks per line (safer). CRT lock needs a re-test. Orientation: HDMI Vertical output changes for the nine `base_flip = 0` game sets. |
| 17 | Test plan | §10. |
| 18 | HW plan | §11. |
| 19 | Files | §12. |

---

## 1. Current clock tree (traced from RTL)

| Clock / enable | Value | Where | How |
|---|---|---|---|
| `CLK_50M` | 50 MHz | board | input |
| `clk_sys` | **100.000 MHz** | `rtl/na1/na1_pll.sv` | `altera_pll`, 1 output, direct mode |
| `CLK_VIDEO` | = `clk_sys` | `NA1.sv:738-740` via `arcade_video` (`assign CLK_VIDEO = clk_video`) | same net |
| `SDRAM_CLK` | 100 MHz, inverted | `rtl/vendor/sdram.sv:308-324` `altddio_out` (`datain_h=0, datain_l=1`) + `NA1.sdc` generated clock `-invert` | forwarded `clk_sys` |
| `ce_master` | 50.113 MHz avg | `na1_clock_enables.sv` | NCO `+50,113,000 / 100,000,000`, 1–2 clk spacing |
| `ce_68k` / `ce_mcu` | 12.528 MHz avg | same | every 4th `ce_master` |
| pixel CE (`timing_pixel_ce`) | **7,159,090 Hz avg** | `na1_video_timing.sv` | NCO `+7,159,090 / 100,000,000` |
| `audio_tick` | 44,100 Hz avg | `na1_audio_tick #(.CLK(100000000))` | NCO |
| CRT Adjust read CE (H-Size ≠ 0 only) | 7,159,090 − k·71,591 Hz | `NA1.sv:686-704` | NCO, re-phased per line |
| DDR3 (screen_rotate) | `DDRAM_CLK = CLK_VIDEO` = 100 MHz | `sys/arcade_video.v` `screen_rotate` | — |

## 2. The current CE_PIXEL generator, exactly

`rtl/na1/na1_video_timing.sv`:

```
phase_sum = phase + PIXEL_HZ              // PIXEL_HZ = 7,159,090
pixel_ce  = profile_available && (phase_sum >= SYS_HZ)   // SYS_HZ = 100,000,000
on pixel_ce : phase <= phase_sum - SYS_HZ ; beam_x/beam_y advance
else        : phase <= phase_sum
```

`phase` is never reset after power-up, so the CE pattern is never re-aligned to
line or frame starts.

Result `[MODEL-CONFIRMED]` (Appendix A, 3 frames, 359,783 gaps):

| Quantity | Value |
|---|---|
| `clk_sys` per pixel, exact | 100e6 / 7,159,090 = **13.968256** |
| Gap histogram | 14 clk: 96.8 %, 13 clk: 3.2 % |
| Distance between 13-gaps | 31 or 32 pixels (alternating) |
| 13-gaps inside the 304 active pixels | 9 or 10, varying per line |
| First→last active CE | 4,232 or 4,233 clk, varying per line |
| Line length | 6,369 (374 lines) or 6,370 (414 lines) clk |
| Frame length | 1,675,185 clk (exact value 1,675,184.97) |

So the CE is correct on average and jittered per pixel and per line.

## 3. Current raster arithmetic

From `na1_video_timing.sv` constants; x = beam_x, pixels numbered from the start of active video.

| Parameter | Value | Time @ 7.15909 MHz |
|---|---|---|
| H total | 456 | 63.694 µs |
| H active | x 0..303 = 304 | 42.46 µs |
| H front porch | x 304..351 = 48 | 6.70 µs |
| HSync | x 352..383 = 32 | 4.47 µs |
| H back porch | x 384..455 = 72 | 10.06 µs |
| V total | 263 (256 logical + 7 pad) | 16.752 ms |
| V active | logical 32..255 = 224 | — |
| VSync | logical 6..8 = 3 lines (transport lines 237..239 counting from active start) | — |
| V front porch | pad 7 + logical 0..5 = 13 | — |
| V back porch | logical 9..31 = 23 | — |
| **H frequency** | 7,159,090 / 456 = **15,699.76 Hz** | |
| **V frequency** | 15,699.76 / 263 = **59.6949 Hz** | |
| Pixel rate from the raster | 456 × 263 × 59.6949 = **7,159,090 Hz** | agrees with the CE average exactly |

(`NA1.sv` states `CLK_VIDEO is clk_sys`. `arcade_video #(.WIDTH(304))`.)

### Does the framework receive a CE that matches the RGB/DE/HS/VS stream? — Yes, apart from the spacing

Traced path: `na1_video_timing` → `na1_renderer` (fixed 3-clock pipeline, keyed to
the same `pixel_ce`) → `na1_video_transport` (all signals delayed 3 clocks and then
registered, all updated **only** on the clock where `ce_pix` rises) → optional
`crt_adjust` (bypassed when Off) → `arcade_video` (edge-detects `ce_pix`,
latches RGB/HS/VS/HBL/VBL on it, emits `CE`) → `video_mixer` (gamma, optional
scandoubler, emits `CE_PIXEL`, updates `VGA_*` only `if (CE_PIXEL)`) →
`screen_rotate` / `sys_top` (ascal, analog, Direct Video).

Checked against every failure mode in the brief:

| Suspected fault | Finding |
|---|---|
| RGB changes without CE | No. The transport updates RGB/sync only under `if (d_ce[2])`. `[MODEL-CONFIRMED]` |
| CE without an output pixel | No. Exactly 456 CEs per line and 304 with DE. |
| Sync changes between CEs | No. Same register block as RGB. |
| DE vs CE disagree | No. `video_mixer` updates `VGA_DE` only on `CE_PIXEL`, and the active width is 304 every line when the scandoubler is off. |
| RGB and sync on different phases | No. Renderer and transport share one 3-clock delay, and all signals are registered on the same edge. |
| CE generated from renderer availability | No. It is a pure NCO. The renderer only supplies colour, and a late or overrunning line gives black or stale colour, never a different CE. |
| CE during reset/download | Continues. The raster free-runs, `reset` only suppresses line/frame events (M23 design). |
| Raster uses one enable, arcade_video told another | No. With CRT Adjust Off, `av_ce_pix = vt_ce_pix`, the same CE as the raster. With CRT Adjust On and H-Size ≠ 0, the read side intentionally uses a second NCO (upstream module design). |
| Fractional jitter reaching video_mixer | **Yes. This is the defect**, §5. |

So the signal set is internally consistent. It breaks exactly one assumption: a constant integer number of `CLK_VIDEO` cycles per pixel.

---

## 4. What MiSTer expects from CE_PIXEL (framework RTL, `sys/`)

1. **One-cycle pulse per pixel on `CLK_VIDEO`, with all video changes on it.**
   `arcade_video.v` rising-edge-detects `ce_pix` and latches everything on that
   edge. `video_mixer.sv` registers `VGA_R/G/B/HS/VS` and toggles `VGA_DE` only
   `if (CE_PIXEL)`. `screen_rotate` counts `hsz`/`vsz` and writes DDR only on
   `CE_PIXEL`. **We satisfy this.**
2. **`CLK_VIDEO` is an integer multiple of the pixel rate (≥ 4×).**
   `video_mixer.sv` port comment: `CLK_VIDEO, // should be multiple by (ce_pix*4)`.
   The code relies on it in three places:
   - **`scandoubler.v`** measures the CE gap (`pixsz <= pl` on every active
     CE, where `pl` = clocks since the previous CE). It then **free-runs** its own
     input sampler (`ce_x1i` when `pix_in_cnt+1 >= pixsz`) and output pixel rate
     (`ce_x2o`/`ce_x4o` from `pixsz`, `pixsz2 = pixsz>>1`, `pixsz4 = pixsz>>2`),
     re-synchronising only on HSync edges. The output DE window, however, is
     timed in raw clocks (`hde_start/hde_end = hcnt>>1`). If `pixsz` is not the
     true pixel period, the number of output pixels in the DE window is wrong.
   - **`hps_io.sv` `video_calc`**: `vid_pixrep <= pcnt` (the CE gap at the start
     of the active line, re-sampled **every line**), reported as video-info
     parameter 16. `vid_fclks` counts exact `clk_vid` edges per frame.
   - **`sys_top.v` Direct Video**: `HDMI_TX_CLK` is switched to `clk_vid`
     (`hdmi_clk_sw`, `clkselect = ~vga_fb & direct_video`). The HDMI stream is
     every `CLK_VIDEO` cycle, i.e. each native pixel is repeated (CE gap) times.
3. **Main_MiSTer uses the repetition as a single integer.** `video.cpp`
   `spd_config_update()` (called when `cfg.direct_video && cfg.spd_quirk < 3`)
   sends an HDMI SPD InfoFrame tagged `'D','V','1'` whose byte 7 is
   `vi->pixrep ? vi->pixrep : (vi->ctime / vi->width)`, followed by `de_h`,
   `de_v`, `width`, `height`. This is how external 4K scalers decode MiSTer
   Direct Video `[REFERENCE-CONFIRMED]` (Main_MiSTer master, read 2026-09-25).
   A pixel repetition of 13.968 can't be expressed in that byte.

ascal itself (`i_ce`/`i_de`) only counts CE-qualified DE pixels and stores them.
With the scandoubler **off**, it gets exactly 304 × 224 every frame, so I found
**no fault in the Fx = None HDMI path** (§5.3).

---

## 5. Mechanism: why it looks fine on CRT and 16:9/4:3 LCD but not on the scaler or 4K

### 5.1 CRT / analog 15 kHz (scandoubler off) — fine
The analog pins carry `video_mixer`'s pass-through output. The line period
jitters by one `clk_sys` (10 ns) out of 63.7 µs (0.016 %), and pixel edges
by ±10 ns out of 140 ns. A CRT's horizontal AFC averages over many lines, so
this can't be seen. This matches the owner's `[HW-CONFIRMED]` M23 result.

### 5.2 Scandoubler active — **defect, proven** `[MODEL-CONFIRMED]`
"Active" means Scandoubler Fx HQ2x/CRT 25 %/CRT 50 %, or `forced_scandoubler`
(31 kHz VGA monitors). The scandoubled stream also feeds ascal, so this reaches
HDMI too.

Cycle model of our timing + transport + `arcade_video` + `gamma_corr` +
`scandoubler` (input and output sides) + `video_mixer` DE logic, 3.5 frames:

| CE generator | Scandoubler input capture | Scandoubled active width per output line (what ascal / VGA get) |
|---|---|---|
| **current fractional (100 MHz / 7,159,090)** | 304 px, in order, all lines ✓ | **304 on 1,466 lines, 303 on 86 lines, 315 on 26 lines** ✗ |
| control: exact ÷14 (same RTL, `SYS_HZ = 14 × PIXEL_HZ`) | 304 px ✓ | **304 on all 1,578 lines** ✓ |

The input side is robust because `pixsz` follows the most recent gap. The output
side is not. When the last measured gap before the output line is 13 (true:
13.968), the output rate is ≈7 % too fast, so the clock-timed DE window holds
315 pixels (the line is squeezed and trailing buffer contents show). When
rounding goes the other way, one pixel is lost. Because the 13-gaps move from
line to line, the affected lines move every frame. On a scaler this looks like
shimmering, horizontally mis-sized lines. **This is a concrete "scaling
artifact" mechanism.** `[INFERRED]` that it is what the reporter saw, since we
don't know their Fx setting.

### 5.3 Normal HDMI, Fx = None — no mechanism found
ascal gets `CE_PIXEL`/`VGA_DE` straight from `video_mixer` (via the OSD/scanline
stage). Every line is 304 CE-qualified DE pixels, every frame is 224 lines, and
`screen_rotate`'s CE-counted `hsz/vsz` are exact. I found no framework logic
here that measures the CE *period*. If the reporter saw artifacts with
Fx = None and Direct Video off, the cause is not established by this
investigation. Ask them (§11).

### 5.4 Direct Video / external 4K scaler — **defect, mechanism established**
With Direct Video, the HDMI pixel clock **is** `CLK_VIDEO` (100 MHz):

| Property of the DV HDMI stream | Current core | With exact ÷14 | PsikyoSH2 (reference) |
|---|---|---|---|
| HDMI clocks per native pixel | 13 or 14 (13.968 avg) | 14 | 8 |
| HDMI line total | 6,369 / 6,370, alternating | 6,384 constant | 3,648 constant |
| Active pixels × repetition | 4,232 / 4,233 clk, varying | 4,256 constant | 2,560 constant |
| `vid_pixrep` → DV1 byte 7 | **14 (≈97 % of lines) or 13 (≈3 %)**, whichever line Main samples | 14 always | 8 always |

A DV1-aware 4K scaler recovers native pixels by taking every *pixrep*-th HDMI
sample from the DE start:

- **pixrep = 14:** sample *k* sits at 14k, while pixel *k* starts at 13.968k. The
  sampling point drifts +0.032 clk per pixel, 9.6 clk (0.7 px) over 304 pixels.
  From a mid-pixel start it crosses into the next pixel around *k* ≈ 220, so one
  column is dropped per line. The per-line ±1-clk phase changes move that
  column from line to line.
- **pixrep = 13** (≈1 in 30 reads): 4,232 / 13 ≈ 326 "pixels". The picture
  is badly stretched or the mode is rejected.
- The HDMI htotal alternates between 6,369 and 6,370 on successive lines. A
  sink that locks to a stable line length sees it as timing instability.

That fits "doesn't work with a 4K scaler at all" far better than a generic
"4K is less tolerant". It also explains why a CRT or a MiSTer-scaled
LCD looks fine, since neither path ever uses `vid_pixrep`. How any particular
external scaler behaves internally is `[INFERRED]`. It also can't be the
DE10-Nano's own HDMI at 4K: ascal output goes through the ADV7513, which tops out
at 1080p60-class pixel clocks, so "4K scaler" almost certainly means an
external upscaler (RetroTINK-4K, Morph 4K, etc.) fed by Direct Video. Confirm
with the reporter.

---

## 6. M23 revisited: geometry was copied, the clock relationship was not

M23 (docs/M23_RESEARCH.md at `f89f80e`, "Recommendation C") copied PsikyoSH2's
PS6406B **envelope**: 7.15909 MHz dot rate, 456 × 263, 32-dot HSync, 3-line VSync.
That fixed the CRT (A: raster geometry/timing) `[HW-CONFIRMED]`.

It did **not** copy the clock/CE relationship (B):

| | PsikyoSH2 | NA1 (M23) |
|---|---|---|
| `clk_sys` = `CLK_VIDEO` | 57.27272 MHz | 100.000 MHz |
| Dot CE | `DOT_CE_R` every 4th `SYS_CE_R` (= clk/2), so **exactly every 8 clk** (`PS6406B.sv:225-233`, `PSH2.sv:126-129`). `ce_pix = DCE1`, edge of `DCLK = DOTCLK_DIV[1]` (`PsikyoSH2.sv:850-866`). | NCO, 13/14 clk |
| Ratio | **8 (integer)** | **13.968 (non-integer)** |

Also, the M23/M15E verification benches (`sim/m23_crt_transport_tb.sv`,
`sim/m15e_video_transport_tb.sv`, run under ModelSim ASE) compiled only
`na1_video_timing`, `na1_video_transport` and `na1_interrupts`. They never
exercised `video_mixer`, `scandoubler`, `hps_io`'s `video_calc` or Direct Video.
ModelSim ASE 17.0 can't even parse those framework files (forward-declared
localparams/variables; verified this session). That is why M23's "ce_pix /
arcade_video contract — M15E-verified" line did not catch this.

Averages agreeing is **not enough** for MiSTer. The framework needs the per-pixel
gap to be constant (§4.2).

---

## 7. Original NA-1/NA-2 clock evidence

| Clock | Value | Tag | Source |
|---|---|---|---|
| Master oscillator | 50.113 MHz | `[MAME-CONFIRMED]` (MAME `MASTER_CLOCK XTAL(50'113'000)`, from its PCB notes) | `namcona1.cpp` |
| 68000 | 50.113 / 4 = 12.528 MHz | `[MAME-CONFIRMED]` | same |
| C69 / C70 (M37702) | 50.113 / 4 = 12.528 MHz | `[MAME-CONFIRMED]` | same |
| C219 | MAME runs it at a 44,100 Hz output rate. Physical clock unknown. | rate `[MAME-CONFIRMED]` as a model value, physical `[UNKNOWN]` | same, FA_HARDWARE_SPEC §C219 |
| H sync | ≈15.73 kHz | `[MAME-CONFIRMED]` (PCB note, measured value quoted in MAME) | same |
| V sync | ≈60 Hz | `[MAME-CONFIRMED]` (PCB note) | same |
| Pixel / dot clock | — | `[UNKNOWN]` | no schematic / measurement |
| H/V totals, porches, sync widths | — | `[UNKNOWN]` | MAME uses `set_refresh_hz(60)`, `set_size(320,256)`, visarea 0..303 × 32..255, i.e. logical only |
| Video ASIC clocks | — | `[UNKNOWN]` | — |

Observation, `[INFERRED]` and **not** load-bearing: 50.113 MHz / 7 = 7.15900 MHz
≈ 2 × NTSC colour burst (7.15909). 7.15900 MHz / 455 = 15,734 Hz, which is the
measured 15.73 kHz and exactly the NTSC line length of 455 half-burst cycles. A
"master ÷ 7, 455-dot line" NA-1 video timing is therefore numerically very
plausible. It has no documentary support and must not be labelled authentic.

### The developer's architecture advice, evaluated

| Principle | Where we stand | Would adopting it fix an identified problem? |
|---|---|---|
| sys = video clock | Already true (`CLK_VIDEO = clk_sys`) | — |
| sys ≥ 4 × pixel, **integer** | 13.968×: ≥ 4× yes, integer **no** | **Yes.** This is the bug. It is fixed by making the pixel CE ÷14 of the existing 100 MHz. |
| sys ≥ every PCB clock | 100 MHz > 50.113 MHz master | already satisfied |
| Fractional CEs for component rates | Already done (master, CPU, MCU, audio) | Harmless for non-video blocks. Only the video CE has to be integer, because only video crosses into framework logic that measures CE period. |
| SDRAM integer-related to sys | SDRAM_CLK = sys (1:1, inverted) | already satisfied |

Retuning the PLL so everything becomes integer, e.g. `clk_sys` = 2 × 50.113 =
100.226 MHz (master ÷2, CPU ÷8, pixel ÷14 = 7.15900 MHz), is the "clean"
version of this advice. **It is not needed to fix any identified problem**, and it
touches the PLL, every NCO constant (`na1_clock_enables`, `na1_audio_tick`, video,
CRT Adjust) and the SDRAM clock. The vendored controller runs CL2, and the
AS4C32M16SB-7 CL2 rating documented at M15C is **100 MHz**, so 100.226 MHz is
0.23 % out of spec. Timing closure on `clk_sys` is also already at −2.9…−4.1 ns
slack. Keep this as the NB-1-style approach for new cores, not as a fix here.

---

## 8. Orientation (Part 6)

### 8.1 Terminology used below
- **raw**: the NA-1 raster with no core flip (`flip_native = 0`, game FLIP off).
- **H**: the board's "Horizontal" presentation, `H = raw` if `base_flip = 0`,
  `H = R180(raw)` if `base_flip = 1`.
- **rotCW(img)**: the *image* turned 90° clockwise (its TOP edge ends up on the
  RIGHT). `screen_rotate` with `rotate_ccw = 0` does exactly this: first input
  row → rightmost output column, written top-to-bottom (`sys/arcade_video.v`
  `screen_rotate`, `next_addr` starts at `{vsz-1,2'b00}` and steps `+stride`)
  `[REFERENCE-CONFIRMED]`.
- To view a rotCW image upright you turn the **monitor** CCW. Image rotation and
  monitor rotation are opposite, which is where CW/CCW labels usually go wrong.

Test card (the H presentation):

```
            TOP
   LEFT   [image]   RIGHT
           BOTTOM
rotCW(H):  LEFT on top, TOP on the right, RIGHT at the bottom, BOTTOM on the left
rotCCW(H): RIGHT on top, TOP on the left, LEFT at the bottom, BOTTOM on the right
R180(H):   BOTTOM on top, RIGHT on the left (upside down)
```

The current OSD labels are image rotations of H: "Vertical CCW" is intended to
mean HDMI shows rotCCW(H). This is how the owner re-labelled them on
2026-09-22, and it is consistent for F/A.

### 8.2 Current RTL decode
`na1_board_presentation.sv`: `flip_native = orient==0 ? base_flip : orient==3 ? ~base_flip : 0`
`NA1.sv:789-792`: `no_rotate = (orient!=1 && orient!=2) | direct_video`, `rotate_ccw = (orient==2)`, `flip = 0`, `VGA_DISABLE = 0`.
Renderer applies `flip_native` (XOR game FLIP) upstream of **both** outputs.
Board records: **F/A (and F/A US) `base_flip = 1`**. Every other MRA has `0`.

### 8.3 Truth table — intended vs actual

Intended (M24 design intent, carried through M26/M28B.1): analog and Direct
Video always show the board's **H** except in Flipped. HDMI rotates H.

| Mode (`status[7:6]`) | Intended HDMI | Intended analog/DV | **Actual F/A** (base 1) HDMI | **Actual F/A** analog/DV | **Actual base-0 games** HDMI | **Actual base-0** analog/DV |
|---|---|---|---|---|---|---|
| 00 Horizontal | H | H | R180(raw) = H ✓ | H ✓ | raw = H ✓ | H ✓ |
| 01 Vertical CCW | rotCCW(H) | H | rotCW(raw) = rotCCW(H) ✓ | **raw = R180(H) ✗** | rotCW(raw) = **rotCW(H) ✗ label inverted** | H ✓ |
| 10 Vertical CW | rotCW(H) | H | rotCCW(raw) = rotCW(H) ✓ | **R180(H) ✗** | **rotCCW(H) ✗ label inverted** | H ✓ |
| 11 Flipped | R180(H) | R180(H) | raw = R180(H) ✓ | R180(H) ✓ | R180(H) ✓ | R180(H) ✓ |

(With Direct Video on, `no_rotate` is forced, so DV HDMI equals the analog column.)

### 8.4 Diagnosis
- The reporter is **right**, and on F/A this is option **C**: our native flip is
  (in)actively involved in CW/CCW. `flip_native` is 1 in Horizontal and forced to 0 in
  both Vertical modes, so the analog / Direct Video picture turns 180° as soon as a
  Vertical mode is selected. F/A is ROT90 `[MAME-CONFIRMED]`. Its H = R180(raw)
  is upright on a monitor turned CCW, but raw is upright only on a monitor turned
  **CW**. Hence "it says vertical CCW and the analog signal is CW". Flipped
  flips analog too, but that one is deliberate.
- Origin: at M24, Horizontal was unflipped, so "CW/CCW leave the CRT native"
  was true. M26 moved the 180 into index 0, and M28B.1 turned it into
  `base_flip`, but the Vertical rows kept a hard-coded `0`. The comment
  "their HW-confirmed F/A behaviour must not move" protected the HDMI result and
  broke the analog one.
- On `base_flip = 0` games the analog output is fine, but the **HDMI CW/CCW labels
  are inverted** relative to the F/A-defined convention. The owner swapped the
  labels to fit F/A, whose base flip already turns everything 180°. This is a
  label bug (D/UX).
- Not A (the analog path is not transformed in any unexpected place) and not
  a status-bit decode error. The bits decode exactly as the RTL comments say. The
  table they implement is just wrong for these rows.

### 8.5 Minimal orientation fix (not applied)
```
flip_native = cfg_base_flip ^ (orient == 2'd3);   // H everywhere except Flipped
rotate_ccw  = (orient == 2'd1);                    // "Vertical CCW" = rotCCW(H)
```
Check for F/A (H = R180(raw)): Vertical CCW → rotCCW(R180(raw)) = rotCW(raw),
**identical to today's HW-confirmed HDMI picture**, and analog now shows H.
Vertical CW → rotCW(R180(raw)) = rotCCW(raw), also identical. Base-0 games: analog
is unchanged, and HDMI CW/CCW swap so they match their labels. Horizontal and
Flipped are unchanged for every game. Optionally clarify the OSD wording
(e.g. "Rotate image CW/CCW (HDMI)") or document that CW/CCW describe the image
rotation of the Horizontal picture.

---

## 9. Recommended minimal video fix (not applied)

**Option A (recommended): exact ÷14 of the existing 100 MHz `clk_sys`, 456 × 263
raster unchanged.**

| Quantity | Now | Option A | Option A′ (÷14, H_TOTAL 454) |
|---|---|---|---|
| Pixel | 7,159,090 Hz (13.968 clk) | **7,142,857.14 Hz (14 clk, constant)** | same |
| H total / active | 456 / 304 | 456 / 304 | 454 / 304 |
| Line | 6,369/6,370 clk, 63.694 µs | **6,384 clk, 63.84 µs** | 6,356 clk, 63.56 µs |
| H freq | 15,699.76 Hz | **15,664.16 Hz** (−0.23 %) | 15,733.17 Hz (NTSC) |
| V freq | 59.6949 Hz | **59.5596 Hz** | 59.822 Hz |
| HSync 32 px | 4.47 µs | 4.48 µs | 4.48 µs |
| Frame | 1,675,185 clk | 1,678,992 clk (constant) | 1,671,628 clk |
| DV pixrep | 13/14 | **14** | 14 |
| Scandoubled width | 303/304/315 | **304** (model) | 304 |

- **Changes only the CE generator.** In `na1_video_timing.sv`, replace the NCO with a
  mod-14 counter (or an NCO whose increment divides `SYS_HZ` exactly). Beam
  counters, the logical/pad split, event timing, the transport, renderer,
  arcade_video wiring, PLL and SDRAM are all untouched.
- Option A′ lands on 15.73 kHz / 59.82 Hz (closer to the measured PCB rates), but it
  also changes `HSYNC_START`/porches, `crt_adjust #(.HTOTAL(456))`, the renderer's
  blank region assumptions and the M23 HW-confirmed envelope. That is more change
  than needed. Keep it as a later option.
- The CRT Adjust glue (`NA1.sv` `CRT_PIXEL_HZ = 7159090`, `CRT_STEP = 71591`) should
  be updated to 7,142,857 / 71,429 so the H-Size steps stay 1.000 %. The
  H-Size ≠ 0 read NCO stays fractional by upstream design (it resamples on purpose).
  It is only active when the user turns CRT Adjust on, which also disables the
  scandoubler path, and is out of scope.

### Regression risks
| Area | Effect | Risk |
|---|---|---|
| Game speed / music tempo | frame 59.695 → 59.560 Hz (−0.23 %). MAME is 60.00, we are already −0.51 %, and this makes it −0.73 %. | low. Visible only in side-by-side timing. |
| Renderer line budget | +14.5 clk per line (6,384 vs ~6,369.5) | beneficial (M31 Emeraldia budget) |
| CPU cycles per frame | +0.23 % | beneficial / neutral |
| IRQ3/IRQ4/vblank position | same beam structure, same line indices | none expected. Re-run M31 checks. |
| CRT lock | −0.23 % line rate, inside the 15.625–15.734 kHz band | low. HW re-test required. |
| HDMI vsync_adjust / VRR | new constant refresh | none expected |
| CRT Adjust | constants only | low |
| Orientation fix | HDMI Vertical swaps for base-0 games | intended. Owner must accept. |

---

## 10. Focused test plan (Part 7)

The simulator has to compile the framework (`sys/arcade_video.v`, `video_mixer.sv`,
`scandoubler.v`, `hq2x.sv`, `gamma_corr.sv`, `video_freezer.sv`, `hps_io.sv`'s
`video_calc`). ModelSim ASE 17.0 **cannot** (verified), so use Verilator (the owner's
qualified tool root) or a newer Questa. The Appendix A Python model is a stop-gap.

Bench `sim/video_ce_contract_tb.sv` (proposed): `na1_video_timing` + renderer
stand-in (3-clock pipeline, colour = encoded beam x/y) + `na1_video_transport` +
`arcade_video` (WIDTH 304, DW 24, GAMMA 1) + `video_calc`, run for 4 frames after 2
settle frames, once each for `fx` = 0, 1 (HQ2x) and 3 (CRT 25 %). The scratch
draft in this session's scratchpad (`cesim/tb_ce.sv`) is a starting point.

| # | Check | Assertion |
|---|---|---|
| 1 | one CE per active pixel | every DE-qualified `CE_PIXEL` carries decoded x = previous x + 1, starting at 0 |
| 2 | CEs per line | exactly 456 between HS rises (fx=0) |
| 3 | CEs per frame | exactly 456 × 263 = 119,928 between VS rises |
| 4 | RGB on pixel boundaries | transport `rgb` and framework `VGA_R/G/B` never change except on the edge after `ce_pix` / `CE_PIXEL` |
| 5 | DE on boundaries | `VGA_DE` changes only after `CE_PIXEL` |
| 6 | HS on boundaries | same for `VGA_HS` |
| 7 | VS on boundaries | same for `VGA_VS` |
| 8 | active width | 304 DE pixels on every line, **including with the scandoubler on** (fx=1, 3). This check fails today. |
| 9 | active height | 224 DE lines per frame (448 scandoubled) |
| 10 | line period | exactly 6,384 clk every line (new), no variation |
| 11 | frame period | exactly 1,678,992 clk every frame |
| 12 | no fractional drift | CE gap == 14 on every one of ≥ 4 frames' CEs (histogram has one bin) |
| 13 | workload independence | identical CE/HS/VS/DE event trace with the renderer stand-in replaced by an always-busy / overrunning renderer and by the real `na1_renderer` |
| 14 | reset / download | trace identical while `reset` is held for ≥ 1 frame (events suppressed, raster unchanged) |
| 15 | orientation vs timing | CE/HS/VS/DE trace bit-identical for all four `orient` values. Pixel content per mode matches §8.3's intended table (R180 / identity). `screen_rotate` HDMI mapping checked with a 4-corner test card: (0,0) lands at the expected FB corner for each mode. |
| 16 | framework contract | `video_calc.vid_pixrep` == 14 on every sample, `vid_hcnt` == 304, `vid_vcnt` == 224, and `vid_fclks` constant |

Structural comparison: record the (CE gap, DE width, htotal) event stream of the
PsikyoSH2 PS6406B generator (constant 8, 320, 3,648) and require ours to have the
same **shape**: a single-valued histogram for each quantity.

Keep the existing M23/M24/M26/M31 bench assertions (IRQ3/IRQ4 lines, HSync
width, VSync 3 lines, orientation pixel maps) and just update the frequency
constants.

## 11. Hardware validation plan

Build A (CE fix only), then Build B (CE + orientation), F/A plus one base-0 game
(Exvania or Ma-Q):

**CRT 15 kHz (owner's YPbPr chain, Direct Video off, Fx None)**
1. Lock through MRA loading screen, reset and gameplay, with no roll or tear (M23 test).
2. Geometry unchanged within ~0.2 % width. CRT Adjust Off/On + H-Size ±4 still work.
3. Build B, F/A: Horizontal, Vertical CCW and Vertical CW all show the **same** analog
   picture. Flipped shows it upside down. Base-0 game: same.

**Normal HDMI / MiSTer scaler**
4. Fx None: unchanged picture, 304 × 224 in the OSD info (`vid_hcnt/vcnt`).
5. Fx HQ2x, CRT 25 %, CRT 50 %, and `forced_scandoubler=1` in the ini. Before the fix
   look for shimmering or horizontally mis-sized lines, scroll a playfield
   (Emeraldia/F/A attract). After the fix they should be gone.
6. Build B: Vertical CCW/CW on F/A are **unchanged** from today. On a base-0 game
   they are now swapped, matching the labels (§8.1 test card).
7. Aspect-ratio and integer-scaling modes (vscale_mode) still work.

**Direct Video / 4K external scaler**
8. `direct_video=1`: an HDMI→VGA DAC path locks, and the OSD info shows a stable
   resolution and repetition.
9. External 4K scaler (ask the reporter which one, and with what DV1/profile
   settings). Before the fix: failure, stretching or a dropped column. After:
   clean 304 × 224 decode.
10. Direct Video + each orientation: DV shows the analog column of §8.3.

**Questions for the reporter:** which game (F/A?), Fx / `forced_scandoubler`
setting, Direct Video on or off, which 4K scaler and how it was connected, and what
"doesn't work" looked like (no signal / wrong size / artifacts).

---

## 12. Files that would change (not modified)

| File | Change |
|---|---|
| `rtl/na1/na1_video_timing.sv` | pixel CE: fractional NCO → exact ÷14 of `clk_sys`. Header comment (7.142857 MHz, 15.664 kHz, 59.56 Hz, integer CE requirement). |
| `NA1.sv` | CRT Adjust constants (`CRT_PIXEL_HZ`, `CRT_STEP`). Transport comment block. Orientation decode `rotate_ccw = (orient==2'd1)` plus the truth-table comment. |
| `rtl/na1/na1_board_presentation.sv` | `flip_native = cfg_base_flip ^ (orient == 2'd3)` plus comments |
| `docs/ARCHITECTURE.md`, `docs/COMPATIBILITY.md` | pixel clock/raster numbers, orientation table |
| `sim/…` (restored/new) | §10 bench, plus the updated M23/M24/M26 benches |

Not touched: `na1_video_transport.sv`, `na1_renderer.sv`, `na1_pll.sv`,
`na1_clock_enables.sv`, `na1_audio_tick`, `rtl/vendor/*`, `sys/*`, `NA1.sdc`, MRAs.

---

## Appendix A — cycle model used for §2/§5 (reproducible)

Python, cycle-accurate register semantics, transcribed from:
`na1_video_timing` (NCO, beam, pad lines), `na1_video_transport` (3-clock delay +
register on `d_ce[2]`), `arcade_video` (edge-detect CE, latch), `sync_fix`
(combinational for positive sync), `video_freezer`/`sync_lock` (pass-through when
not frozen), `gamma_corr` (gamma off: one-pixel CE-edge pipeline), `scandoubler`
(`pix_len`, `pixsz/2/4`, `pix_in_cnt`/`ce_x1i`, `r_d` capture, `pix_out_cnt`/`ce_x2o/x4o`,
`sd_hcnt`/`hde_start/end`/`hs_out`, `hbo` shift), `video_mixer` (`CE_PIXEL <= ce_pix_sd`,
`hde <= ~hb_sd`, `VGA_DE` toggled on `CE_PIXEL`), and `hps_io` `video_calc` (`pcnt`,
`old_de/old_de1`, `vid_pixrep`). Renderer stand-in colour = beam x. Run twice:
`SYS_HZ = 100,000,000` (current) and `SYS_HZ = 100,227,260` (= 14 × 7,159,090, so the
unchanged NCO fires exactly every 14 clocks, the ÷14 control).

Output:
```
SYS_HZ 100000000  lines checked 672
 scandoubler capture: {'len304': 672}
 scandoubled DE pixels per output line (what ascal sees): {304: 1466, 303: 86, 315: 26}
 hps_io vid_pixrep samples: {14: 866, 13: 30}
SYS_HZ 100227260  lines checked 672
 scandoubler capture: {'len304': 672}
 scandoubled DE pixels per output line (what ascal sees): {304: 1578}
 hps_io vid_pixrep samples: {14: 896}
```
This model is a transcription, not the RTL itself. Its result should be confirmed
by the §10 Verilator bench before and after the fix.

---

## 13. Addendum (2026-09-25): clock-option comparison for the CE fix

The owner asked whether an integer pixel CE can keep the M23 rate
(7,159,090 Hz) instead of accepting ÷14 at 100 MHz (−0.227 %). Numbers below come from
`opts.py` (scratchpad): exact arithmetic, and a 32-bit-fraction Cyclone V fPLL search.

### Constraints found in the current design
- **Renderer line budget is nearly full.** M31 measured Emeraldia's heaviest lines
  at **6,050–6,325 clk under bench contention**, against a 6,370-clk line (99.3 %).
  Render work is counted in `clk_sys` cycles (renderer and SDRAM both run on
  `clk_sys`), so the budget is *cycles per line* = divider × 456.
- `na1_renderer` `VREG_MAXWAIT = 6000` clk is documented as "< 1 line" (M31).
- The 68000 and C69 run on **real SDRAM wait states** (DTACK/ack, no catch-up,
  M20C). SDRAM latency is fixed in `clk_sys` cycles, so a slower `clk_sys` lengthens
  every wait in wall time.
- C219: worst measured 1,300 clk per 44.1 kHz sample (M20A).
- `sdram.sv`: CL2, `cycles_per_refresh = 780` (refresh every 781 clk; JEDEC limit
  7.8125 µs), 12,100-cycle startup. Project docs (M15C) give the AS4C32M16SB-7
  CL2 rating as 100 MHz. **`[REFERENCE-CONFIRMED]` the stock GBA_MiSTer core,
  source of this `sdram.sv` (commit 93790a0), clocks the same controller from
  `clk_sys` = 100.663296 MHz on a fractional PLL.**
- STA today: `clk_sys` intra-domain setup slack **−2.890 ns** (slow 100 °C model,
  TNS −1006 ns; genuine, not a clock-group artefact). Hardware works regardless.
- Wall-time constants tied to 100 MHz: `na1_clock_enables` (50,113,000/100,000,000),
  `na1_audio_tick #(.CLK(100000000))`, `na1_rom_board_io #(CLK_HZ=100_000_000)`
  (RTC 1 s tick, default not overridden in `NA1.sv`), `na1_video_timing SYS_HZ`,
  CRT Adjust `CRT_SYS_HZ`, `sdram.sv` refresh/startup, `na1_c219_selftest` (debug
  only). `na1_scanline_events` is not instantiated.
- Known PCB clocks `[MAME-CONFIRMED]`: master 50.113 MHz, 68000 and C69/C70 at
  12.528 MHz, C219 44.1 kHz (model). Every option below keeps `clk_sys` > 50.113 MHz.

### Comparison

| | **A** 100 MHz ÷14 | **B** 93.06817 MHz ÷13 | **C** separate CLK_VIDEO | **D2** 100.226 MHz ÷14 (= 2 × master) |
|---|---|---|---|---|
| clk_sys / CLK_VIDEO | 100.000000 / same | 93.068170 / same | 100.000 / 57.27272 (8×) | 100.226000 / same |
| PLL | unchanged (integer, 50×12/2/3) | fractional, error < 0.01 Hz | 2nd fractional PLL | fractional, error < 0.01 Hz (NB-1 got 96.768 MHz to 2e-4 Hz on this toolchain) |
| Pixel | 7,142,857.14 (−2,267 ppm) | 7,159,090 (0) | 7,159,090 (0) | **7,159,000 (−13 ppm)** = master ÷ 7 |
| H @456 / V @263 | 15,664.16 Hz / 59.5596 Hz | 15,699.76 / 59.6949 | 15,699.76 / 59.6949 | **15,699.56 / 59.6942** |
| Error vs M23 | −0.227 % | 0 | 0 | −0.0013 % |
| SDRAM clk | 100.000 (10.000 ns, at the CL2 rating) | 93.07 (10.745 ns, +0.745 ns) | 100.000 | 100.226 (9.977 ns, 0.23 % over the datasheet CL2 rating; GBA runs this controller 0.66 % over) |
| Refresh (781 clk) | 7.810 µs ✓ | **8.392 µs ✗, needs 726** | 7.810 ✓ | 7.792 µs ✓ (no change) |
| Renderer cycles/line (Emeraldia worst 6,325) | 6,384 (+59 margin) | **5,928 (−397, heavy lines overrun)** | 6,369.5 in sys domain (current) | 6,384 (+59) |
| `VREG_MAXWAIT` 6,000 < line | ✓ | **✗** | ✓ | ✓ |
| clk per 68000 cycle | 7.982 | 7.429 (SDRAM waits +7.4 % wall time) | 7.982 | **8.000 exact** |
| C219 budget (worst 1,300) | 2,268 | 2,110 | 2,268 | 2,273 |
| Blitter wall-time throughput | ±0 | −6.9 % | ±0 | +0.23 % |
| STA delta vs −2.890 ns | 0 | +0.745 ns (still negative) | new CDC paths | ≈ −0.02 ns |
| sys = video, sys ≥ 4× pixel, sys ≥ PCB, SDRAM 1:1 | ✓ ✓ ✓ ✓ | ✓ ✓ ✓ ✓ | ✗ ✓ ✓ ✓ | ✓ ✓ ✓ ✓. Master and CPU CEs also become integer (÷2, ÷8). |
| Non-video CEs keep exact averages | yes (unchanged) | yes (new constants) | yes (unchanged) | yes (new constants; NCOs then fire exactly every 2 clk) |
| RTL touched | video CE, CRT consts | PLL, all NCO consts, sdram refresh, VREG_MAXWAIT, video, CRT, re-verify M20C/M29 budgets | PLL, beam + transport + renderer read side moved to video clock, event/IRQ CDC, crt_adjust domain, SDC | PLL (fractional), constants in clock_enables / audio_tick / rom_board_io / video_timing / CRT glue |
| Framework wiring | none | none | CLK_VIDEO split | none |
| Regression scope | CRT lock, game speed −0.23 % | renderer overruns (Emeraldia band returns), CPU/MCU wait-state parity (M20C), SDRAM refresh, blitter | IRQ/event phase, renderer CDC, timing closure | CRT lock, PLL lock/jitter, SDRAM stability (GBA precedent), constant audit |

Variant D1 (100.22726 MHz = 14 × 7,159,090) hits the M23 rate exactly, but leaves the
master NCO fractional (ratio 2.0000108). D2 is preferred: its 13 ppm offset is invisible
(0.2 Hz of line rate) and every CE in the core becomes an exact integer.

**Option B is disqualified** by the renderer budget, not only by SDRAM refresh: it
removes 441 cycles per line from a budget M31 measured at 99.3 % use, breaks
`VREG_MAXWAIT < line`, and stretches every CPU/MCU SDRAM wait by 7.4 %.
**Option C** buys the exact rate at the price of clock-domain crossings through the
beam/IRQ/renderer, the most delicate verified logic in the core.

### Recommendation: D2
`clk_sys` = `CLK_VIDEO` = `SDRAM_CLK` = 100.226 MHz (fractional PLL, 2 × 50.113 MHz),
pixel CE = exact ÷14 = 7.159000 MHz (master ÷ 7), raster 456 × 263 unchanged:
15,699.56 Hz / 59.6942 Hz. Every cycle budget matches Option A, and the video rate
matches M23 to 13 ppm. Fallback: Option A, if the fractional PLL or SDRAM
misbehaves on hardware (a one-line PLL revert plus constants).

Implementation notes:
- Generate the pixel CE with an **explicit ÷14 counter**, not an NCO whose constants
  happen to divide. A later constant edit must not be able to reintroduce jitter.
  Add a sim assertion that every gap is 14.
- Put the system frequency in **one** localparam (`SYS_HZ = 100_226_000`) and pass it
  to `na1_clock_enables` (currently hard-coded), `na1_audio_tick`,
  `na1_rom_board_io`, `na1_video_timing` and the CRT glue, so no module keeps a stale 100 MHz.
- Keep the NA1 PLL hierarchy that `sys_top.sdc`'s `*|clocks|pll|*|divclk` group and
  `NA1.sdc`'s SDRAM generated clock match. Switching `na1_pll.sv` to
  `fractional_vco_multiplier("true")` does not change the `general[0].gpll~…|divclk`
  naming. Verify from the STA clock list.
- Record the fitter's achieved frequency (PLL Usage Summary) in the docs.
