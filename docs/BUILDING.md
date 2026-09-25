# Building the core

## Requirements

* Intel Quartus Prime Lite **17.0** (17.0.2 recommended, as for other MiSTer
  cores) with Cyclone V device support.
* About 20 minutes and 8 GB of RAM per full compile.

## Build

Open `Namco_NA1_NA2.qpf` in Quartus and run **Processing > Start Compilation**,
or from PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/build.ps1
```

Pass `-QuartusRoot <path>` if Quartus is not installed in
`C:\intelFPGA_lite\17.0\quartus`.

Outputs:

* `output_files/Namco_NA1_NA2.rbf`, the bitstream.
* `Releases/Namco_NA1_NA2_YYYYMMDD.rbf`, a dated copy made by the post-flow
  script `scripts/release_rbf.tcl` after every full compile.

Check the timing report (`output_files/Namco_NA1_NA2.sta.summary`): all clock
domains should have non-negative setup and hold slack.

## Install on MiSTer

1. Copy `Releases/Namco_NA1_NA2_YYYYMMDD.rbf` to `_Arcade/cores/`.
2. Copy the `MRA/*.mra` files to `_Arcade/` and, optionally, the
   `MRA/_alternatives/_<Game>` folders to `_Arcade/_alternatives/`.
3. Put the MAME ROM zips in `games/mame/`.

See [COMPATIBILITY.md](COMPATIBILITY.md) for ROM set notes.
