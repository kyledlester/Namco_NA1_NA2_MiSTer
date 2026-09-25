# Credits and third-party components

## Included code

| Component | Path | Origin | License |
| --- | --- | --- | --- |
| FX68K 68000 core | `rtl/fx68k/`, `microrom.mem`, `nanorom.mem` | [ijor/fx68k](https://github.com/ijor/fx68k) by Jorge Cwik, unmodified (see `rtl/fx68k/ORIGIN.md`) | GPL-3.0-or-later |
| SDRAM controller | `rtl/vendor/sdram.sv` | [MiSTer-devel/GBA_MiSTer](https://github.com/MiSTer-devel/GBA_MiSTer), with byte enables added (see `rtl/vendor/README.md`) | GPL-3.0-or-later |
| CRT Adjust | `rtl/vendor/crt_adjust.sv` | MiSTer-CRT-Adjust by Umberto Parisi (rmonic79) with Andrea Bogazzi, unmodified | GPL-3.0-or-later |
| MiSTer framework | `sys/` | [MiSTer-devel/Template_MiSTer](https://github.com/MiSTer-devel/Template_MiSTer) | see `LICENSE.MiSTer` and file headers |

## Behavioural references

The core's NA-1/NA-2 logic was written for this project. Its behaviour follows
these MAME 0.289 sources (BSD-3-Clause):

* [`src/mame/namco/namcona1.cpp`](https://github.com/mamedev/mame/blob/master/src/mame/namco/namcona1.cpp): board, video, KEYCUS and ROM definitions
* `src/devices/cpu/m37710/`: M37702 (C69/C70 MCU) instruction set and timing
* `src/devices/sound/c140.cpp`: C219 PCM
* `src/devices/rtc/msm6242.cpp`: MSM6242 real-time clock (optional ROM-board I/O)

Other MiSTer cores used as references: Arcade-PsikyoSH2_MiSTer (video timing,
board-record convention) and SYSTEM11_MiSTer (M37702 on MiSTer).

## Game data

No ROMs, MCU BIOS images or other game data are included. MRAs list MAME part
names and CRCs only.
