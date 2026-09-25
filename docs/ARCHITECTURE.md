# Architecture

The core implements the Namco NA-1 and NA-2 arcade boards for MiSTer (DE10-Nano
with an SDRAM module). MAME's `namcona1.cpp` driver (0.289) is the behavioural
reference; where the core copies a MAME behaviour that is not known to be
physical, the source comments say so.

## Clocks

`clk_sys` is 100 MHz from `rtl/na1/na1_pll.sv`. Clock enables in
`na1_clock_enables.sv` derive the 50.113 MHz board master clock on average,
and from it the 12.53 MHz 68000 and M37702 clocks. Video uses a 7.159 MHz pixel
enable (456 × 263 dots, 15.70 kHz), the same raster as the Psikyo SH-2 MiSTer core.

## Main blocks

| Block | Files | Notes |
| --- | --- | --- |
| MiSTer glue | `NA1.sv` | `hps_io`, OSD options, ROM download, NVRAM, video/audio out, CRT Adjust |
| 68000 | `rtl/fx68k/`, `na1_cpu.sv`, `na1_cpu_bus.sv` | FX68K core, cycle-accurate |
| Address decode | `na1_decode.sv`, `na1_memory.sv` | 68000 map, byte lanes, bus handshakes |
| Shared RAM arbiter | `na1_shared_arbiter.sv`, `na1_word_arbiter.sv` | 68000, MCU, blitter and sound share work RAM |
| SDRAM | `rtl/vendor/sdram.sv`, `na1_sdram_*.sv`, `na1_rom_sdram_bridge.sv` | program ROM, mask ROM and 512 KiB work RAM |
| MCU (C69 / C70) | `na1_m37702*.sv`, `na1_c69*.sv`, `na1_mcu_interface.sv` | M37702 CPU running the genuine BIOS from the MRA; C69 and C70 differ only in BIOS |
| Sound | `na1_c219.sv`, `na1_audio_tick.sv` | C219 16-voice PCM, samples from work RAM |
| KEYCUS | `na1_keycus.sv` | protection chip, mode from the board record |
| Blitter | `na1_blitter*.sv` | register-driven copies over the shared bus |
| Video RAM and registers | `na1_video_*.sv`, `na1_shape_*.sv`, `na1_gfx.sv`, `na1_palette*.sv` | tilemaps, character/shape RAM, palette |
| Renderer | `na1_renderer.sv`, `na1_char_prefetch.sv` | per-line tile layers, ROZ layer, direct-pixel lines, sprites, priority, operator FLIP |
| Timing and interrupts | `na1_video_timing.sv`, `na1_scanline_events.sv`, `na1_interrupts.sv` | raster timing, vblank and position interrupts |
| Video out | `na1_video_transport.sv`, `na1_board_presentation.sv` | line buffers, orientation, 15 kHz output |
| EEPROM | `na1_eeprom*.sv` | 28C16 with MiSTer NVRAM save |
| Board record | `na1_config.sv` | per-board settings from MRA index 2 |
| ROM-board I/O | `na1_rom_board_io.sv` | optional MSM6242 RTC and status port on the ROM board (board record byte 6); no supported title uses it |

## One RBF, many MRAs

The core has no game ID. Everything that differs between titles is either in
the ROM stream or in the small board record the MRA sends at index 2. See
[MRA_FORMAT.md](MRA_FORMAT.md).

## Development history

The source comments reference design notes (`docs/M*_IMPLEMENTATION.md`,
`docs/*_RESEARCH.md`) and simulation benches (`sim/`, `scripts/test-*.ps1`)
from development. They were removed from the tree before the public release and
remain in the git history, e.g.:

```bash
git show f89f80e:docs/M29_IMPLEMENTATION.md
```

`rtl/na1/na1_m37702_decode.sv` is generated from MAME's M37710 opcode tables by
`scripts/m20b-decode.py`.
