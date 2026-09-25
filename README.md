# Namco NA-1 / NA-2 for MiSTer

A MiSTer FPGA core for Namco's **NA-1** and **NA-2** arcade boards (1992-1994).
One core (`Namco_NA1_NA2`) runs every supported game; each game has its own MRA.

I created this core because I wanted to play these games on my MiSTer FPGA. I am posting it here and open sourcing it for everyone to enjoy and give feedback/make improvements. This core was created with the assistance of AI tooling.

This system offers a number of great games, many of which are fun to play with friends. A handful of the games support four players.

**Status: beta.** All ten main titles boot to the title screen and are playable
on real MiSTer hardware.

## Quick start

1. Copy the core from [`Releases/`](Releases/) (`Namco_NA1_NA2_YYYYMMDD.rbf`) to
   **`/media/fat/_Arcade/cores/`**.
2. Copy the MRA files from [`MRA/`](MRA/) to **`/media/fat/_Arcade/`**.
   For region/revision variants, copy the `_<Game>` folders from
   [`MRA/_alternatives/`](MRA/_alternatives/) to **`/media/fat/_Arcade/_alternatives/`**.
3. Put the MAME ROM zips (MAME 0.289 sets) in **`/media/fat/games/mame/`**.
   With split or merged sets, also add the MCU BIOS zips **`namcoc69.zip`**
   (NA-1 games) and **`namcoc70.zip`** (NA-2 games) there. Non-merged sets
   already include the BIOS in each game's zip.
4. Load a game from the **Arcade** menu.

ROMs are not included. You must supply your own.

## Supported games

| Game | MAME set | Year | Genre | Board | Status |
| --- | --- | --- | --- | --- | --- |
| Bakuretsu Quiz Ma-Q Dai Bouken (Japan) | `bkrtmaq` | 1992 | Quiz | NA-1 | Boots to title screen and is playable |
| Cosmo Gang the Puzzle (Japan) | `cgangpzlj` | 1992 | Puzzle | NA-1 | Boots to title screen and is playable |
| Emeraldia (Japan, Version B) | `emeraldajb` | 1993 | Puzzle | NA-1 | Boots to title screen and is playable |
| Exvania (Japan) | `exvaniaj` | 1992 | Maze-based competitive multiplayer | NA-1 | Boots to title screen and is playable |
| F/A (Japan) | `fa` | 1992 | Shoot 'em up | NA-1 | Boots to title screen and is playable |
| Knuckle Heads (Japan) | `knckheadj` | 1992 | Fighting | NA-2 | Boots to title screen and is playable |
| Nettou! Gekitou! Quiztou!! (Japan) | `quiztou` | 1993 | Quiz | NA-2 | Boots to title screen and is playable |
| Numan Athletics (Japan) | `numanathj` | 1993 | Sports | NA-2 | Boots to title screen and is playable |
| Super World Court (Japan) | `swcourtj` | 1992 | Sports (tennis) | NA-1 | Boots to title screen and is playable |
| Tinkle Pit (Japan) | `tinklpit` | 1993 | Action | NA-1 | Boots to title screen and is playable |

### Alternatives

These use the same core and the same board settings as the main set, with a
different ROM set.

| Game | MAME set | Year | Parent game | Status |
| --- | --- | --- | --- | --- |
| Cosmo Gang the Puzzle (US) | `cgangpzl` | 1992 | Cosmo Gang the Puzzle | Boots to title screen and is playable |
| Emeraldia (World) | `emeralda` | 1993 | Emeraldia | Boots to title screen and is playable |
| Emeraldia (Japan) | `emeraldaj` | 1993 | Emeraldia | Boots to title screen and is playable |
| Emeraldia (Japan, Version D) | `emeraldajd` | 1993 | Emeraldia | Boots to title screen and is playable |
| Exvania (World) | `exvania` | 1992 | Exvania | Boots to title screen and is playable |
| Fighter & Attacker (US) | `fghtatck` | 1992 | F/A | Boots to title screen and is playable |
| Knuckle Heads (World) | `knckhead` | 1992 | Knuckle Heads | Boots to title screen and is playable |
| Knuckle Heads (Japan, Prototype) | `knckheadjp` | 1992 | Knuckle Heads | Boots to title screen and is playable |
| Numan Athletics (World) | `numanath` | 1993 | Numan Athletics | Boots to title screen and is playable |
| Super World Court (World) | `swcourt` | 1992 | Super World Court | Boots to title screen and is playable |
| Super World Court (World, bootleg) | `swcourtb` | 1994 | Super World Court | Boots to title screen and is playable |

The NA-2 medal games are out of scope: this
core targets arcade games only.

### ROM notes

* **Cosmo Gang the Puzzle (Japan)** needs a default EEPROM file. It uses
  `eeprom_cgangpzlj` from its own zip or, if missing, the US `eeprom_cgangpzl`
  from `cgangpzl.zip`.
* **Nettou! Gekitou! Quiztou!!** needs the `eeprom` file from a complete
  `quiztou.zip`. Without it the first boot stops at the NOTICE screen once;
  reset the core and it will work fine going forward.

More detail: [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md).

## About the hardware

NA-1 and NA-2 are Namco's early-1990s boards:

* Motorola **68000** main CPU at 12.5 MHz.
* Namco **C69** (NA-1) or **C70** (NA-2) MCU, a Mitsubishi M37702 running
  Namco's BIOS. It handles the controls and drives the **C219** 16-voice PCM
  sound chip.
* Tilemap and sprite video with a rotate/zoom layer, a blitter, and a
  per-game **KEYCUS** protection chip.
* Game settings and high scores kept in an EEPROM.

## About the core

* Runs the genuine C69/C70 MCU BIOS on an M37702 CPU core, so sound and inputs
  come from Namco's own firmware.
* One RBF for every game. The core has no per-game code; each MRA carries a
  small board record (protection chip, cabinet orientation, control panel).
  See [docs/MRA_FORMAT.md](docs/MRA_FORMAT.md).
* Full video: all tile layers, 4-bpp tiles and sprites, the rotate/zoom layer,
  direct-pixel lines and raster effects.
* Black borders outside the game's display window, as on the arcade board
  (MAME fills them with the background colour, e.g. F/A's maroon and
  Exvania's light-blue side borders).
* The game's own service-menu FLIP setting works (a true 180° rotation), which does not work in MAME.
* Native 15 kHz output for CRTs, with optional CRT Adjust (H-size,
  H-position, V-shift) thanks to rmonic79/MiSTer-CRT-Adjust.
* OSD options: scandoubler effects, orientation (Horizontal, Vertical CCW,
  Vertical CW, Flipped), Service Mode, CRT Adjust, Reset.
* EEPROM saved to the SD card as `.nvm`. MiSTer writes it when you open the
  OSD after the game has changed its settings or scores.
* Up to four players for the games that support it.

MAME's `namcona1` driver (0.289) is the behavioural reference.

### Known issues

* Restoring a saved `.nvm` can occasionally corrupt it. If a game shows odd
  settings, delete its `.nvm` from `/media/fat/nvram/` and let it set itself
  up again.
* Some busy rotate/zoom scenes may briefly show an artefact on a line.

## Releases

Builds are in [`Releases/`](Releases/) as `Namco_NA1_NA2_YYYYMMDD.rbf`. The MRAs
name the core without the date (`<rbf>Namco_NA1_NA2</rbf>`), and MiSTer loads
the newest dated file in `_Arcade/cores/`. You are welcome to run your own build if you'd prefer.

## Building

Quartus Prime Lite 17.0. Open `Namco_NA1_NA2.qpf` and compile; the build copies
a dated RBF into `Releases/`. See [docs/BUILDING.md](docs/BUILDING.md).

## Documentation

* [Compatibility](docs/COMPATIBILITY.md)
* [MRA format](docs/MRA_FORMAT.md)
* [Architecture](docs/ARCHITECTURE.md)
* [Building](docs/BUILDING.md)
* [Credits and third-party components](docs/REFERENCES.md)

## License

GPL-3.0-or-later (see [LICENSE](LICENSE)). The MiSTer framework in `sys/` keeps
its own notices ([LICENSE.MiSTer](LICENSE.MiSTer)); FX68K, the SDRAM controller
and CRT Adjust are GPL-3.0-or-later. See [docs/REFERENCES.md](docs/REFERENCES.md).

No ROMs, MCU BIOS images or other game data are included in this repository.
