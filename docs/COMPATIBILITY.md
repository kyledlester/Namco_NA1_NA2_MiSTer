# Compatibility

One RBF (`Namco_NA1_NA2`) runs every title below. Each title has its own MRA,
which supplies the ROM stream, the MCU BIOS file and a small board record
([MRA_FORMAT.md](MRA_FORMAT.md)). The RTL has no per-game code.

Tested on a DE10-Nano with a 128 MB SDRAM module.

| Status | Meaning |
| --- | --- |
| **Working** | boots and plays on real MiSTer hardware |

## Main sets (`MRA/`)

| Game | MAME set | Board | Status | Notes |
| --- | --- | --- | --- | --- |
| F/A (Japan) | `fa` | NA-1 | Working | vertical game (ROT90 cabinet) |
| Bakuretsu Quiz Ma-Q Dai Bouken (Japan) | `bkrtmaq` | NA-1 | Working | quiz panel: four answer buttons |
| Cosmo Gang the Puzzle (Japan) | `cgangpzlj` | NA-1 | Working | needs a default EEPROM, see below |
| Emeraldia (Japan, Version B) | `emeraldajb` | NA-1 | Working | |
| Exvania (Japan) | `exvaniaj` | NA-1 | Working | |
| Super World Court (Japan) | `swcourtj` | NA-1 | Working | up to four players |
| Tinkle Pit (Japan) | `tinklpit` | NA-1 | Working | |
| Knuckle Heads (Japan) | `knckheadj` | NA-2 | Working | up to four players |
| Numan Athletics (Japan) | `numanathj` | NA-2 | Working | up to four players |
| Nettou! Gekitou! Quiztou!! (Japan) | `quiztou` | NA-2 | Working | quiz panel; needs a default EEPROM, see below |

## Alternate sets (`MRA/_alternatives/`)

Copy each `_<Game>` folder to `_Arcade/_alternatives/` on the SD card.

| Game | MAME set | Board | Status |
| --- | --- | --- | --- |
| Cosmo Gang the Puzzle (US) | `cgangpzl` | NA-1 | Working |
| Emeraldia (World) | `emeralda` | NA-2 | Working |
| Emeraldia (Japan) | `emeraldaj` | NA-1 | Working |
| Emeraldia (Japan, Version D) | `emeraldajd` | NA-2 | Working |
| Exvania (World) | `exvania` | NA-1 | Working |
| Fighter & Attacker (US) | `fghtatck` | NA-1 | Working |
| Knuckle Heads (World) | `knckhead` | NA-2 | Working |
| Knuckle Heads (Japan, Prototype) | `knckheadjp` | NA-2 | Working |
| Numan Athletics (World) | `numanath` | NA-2 | Working |
| Super World Court (World) | `swcourt` | NA-1 | Working |
| Super World Court (World, bootleg) | `swcourtb` | NA-1 | Working |

Every NA-1/NA-2 set in MAME 0.289 has an MRA except the medal games, which are
out of scope: this core targets arcade games only.

## ROM sets

Put MAME 0.289 sets (merged, split or non-merged) in `games/mame/`. Parts
are matched by CRC, so older sets with different file names also load. NA-1
sets need `c69.bin` and NA-2 sets need `c70.bin` (the MCU BIOS). MAME
treats these as device ROMs: non-merged sets include them in every game zip,
while split and merged sets keep them only in `namcoc69.zip` and
`namcoc70.zip`, so put those two zips in `games/mame/` as well. Each MRA looks
in the game zip, then its parent zip, then the matching `namcoc69`/`namcoc70`
zip.

## EEPROM and first boot

Settings and high scores are kept in the game's EEPROM, which MiSTer saves as
`.nvm` when you open the OSD after the game has written to it.

On the very first boot (no `.nvm` yet) the MRA fills the EEPROM with `00` and
then with MAME's dumped default EEPROM, if the set has one. A blank (`FF`)
EEPROM would make the boot self-test start in FLIP mode, and some titles hang
on it.

| Title | First boot |
| --- | --- |
| Cosmo Gang the Puzzle (Japan) | uses `eeprom_cgangpzlj`; if your zip lacks it, the MRA falls back to the US `eeprom_cgangpzl` from `cgangpzl.zip` |
| Nettou! Gekitou! Quiztou!! | needs the `eeprom` file from a complete `quiztou.zip`; without it the first boot stops at the NOTICE screen once (MAME does the same), and a reset continues |
| all other titles | set themselves up from the `00` image |

## Core features

| Feature | Notes |
| --- | --- |
| Genuine MCU | the C69/C70 BIOS runs on an M37702 CPU core; the C219 PCM sound runs from it |
| Video | all tile layers, 4-bpp tiles and sprites, the ROZ layer, direct-pixel lines, raster effects |
| Operator FLIP | the service-menu FLIP setting rotates the picture 180 degrees, as on the real board |
| Orientation (OSD) | Horizontal, Vertical CCW, Vertical CW, Flipped |
| CRT output | native 15 kHz, with optional CRT Adjust (H-size, H-position, V-shift) |
| Service Mode (OSD) | holds the board's service switch to enter the test menu |

## Known issues

* The NVRAM upload path can occasionally corrupt a restored `.nvm`; if a game
  shows odd settings, delete its `.nvm` from `nvram/` and let it set itself up again.
* Some busy ROZ scenes may exceed the renderer's line budget and show a brief
  artefact on a line.
