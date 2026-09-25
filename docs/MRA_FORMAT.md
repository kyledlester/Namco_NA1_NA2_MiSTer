# MRA format

Every NA-1/NA-2 title loads the same RBF. An MRA tells the core three things:
the ROM stream (index 0), the first-boot EEPROM (index 1) and the board record
(index 2). Use an existing MRA in `MRA/` as a template.

```xml
<rbf>Namco_NA1_NA2</rbf>
...
<rom index="1"> first-boot EEPROM </rom>
<nvram index="1" size="2048"/>
<rom index="2"><part>01 5D 01 02 01 00</part></rom>   <!-- board record -->
<rom index="0" zip="..."> ROM stream </rom>
```

Index 2 is listed before index 0 so the board record reaches the core before
the ROM stream, while the CPUs are still held in reset.

## ROM stream (index 0)

Always exactly 10,502,144 bytes:

| Stream offset | Size | Contents |
| --- | --- | --- |
| `$000000-$1FFFFF` | 2 MiB | program EPROMs (EP0 pair, then EP1 pair); `00`-padded where a socket is empty |
| `$200000-$9FFFFF` | 8 MiB | mask ROMs in order; `00`-padded (MAME's `ROMREGION_ERASE00`) |
| `$A00000-$A03FFF` | 16 KiB | MCU BIOS: `c69.bin` (NA-1) or `c70.bin` (NA-2) |

Program and mask ROMs are 16-bit pairs. Use `<interleave output="16">` with
the `*l` (odd-offset) part at `map="01"` and the `*u` (even-offset) part at
`map="10"`.

## First-boot EEPROM (index 1)

The game's 2 KiB 28C16 EEPROM. Every MRA sends 2 KiB of `00`, followed by
MAME's dumped default EEPROM when the set has one:

```xml
<rom index="1" zip="exvaniaj.zip|exvania.zip" md5="none">
    <part repeat="0x800">00</part>
    <part name="eeprom" crc="..."/>
</rom>
<nvram index="1" size="2048"/>
```

`<nvram>` comes after it, so a saved `.nvm` overrides both. An erased EEPROM
(`FF`) would make the boot self-test start in FLIP mode, and some titles hang
on it.

## Board record (index 2)

Six or seven bytes that describe the board, never the game:

| Byte | Field | Values |
| --- | --- | --- |
| 0 | KEYCUS mode | `00` none, `01` ID + changing value (most titles), `02` LFSR (Tinkle Pit) |
| 1-2 | KEYCUS ID | little-endian: the Namco part number in decimal, e.g. C349 = `$015D` → `5D 01` |
| 3 | KEYCUS ID word | which KEYCUS word (0-7) returns the ID |
| 4 | Cabinet orientation | `00` MAME ROT0, `01` MAME ROT90 (F/A) |
| 5 | Control panel | `00` joystick + 3 buttons, `01` four-button quiz panel |
| 6 | ROM-board I/O (optional) | `00` plain EPROM board, `01` MSM6242 RTC + status port (unused by the supported titles) |

The values for every supported board are in the `MRA/` files.

## ROM names and CRCs

Part names, CRCs and offsets come from `mame -listxml <set>` and the set's
`ROM_START` block in MAME's `namcona1.cpp`. MiSTer matches parts by CRC first,
so dumps with other file names load too.
