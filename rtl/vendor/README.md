# Vendored RTL

`sdram.sv` originates from MiSTer-devel's `GBA_MiSTer` repository at commit
`93790a023395bbd90e5eaf4dfb2cb5910afd55f5`:

<https://github.com/MiSTer-devel/GBA_MiSTer/blob/93790a023395bbd90e5eaf4dfb2cb5910afd55f5/rtl/sdram.sv>

The file retains its original copyright and GPL-3.0-or-later notice. The
upstream Git blob SHA-1 of the unmodified file (as vendored for M15C) is
`35222d43b641f36cbca1d77531c08a3018f76472`.

## Local modification (M15D) — this file is no longer an unmodified copy

M15D adds channel-1 byte enables so writable work/character SDRAM can perform
upper-byte and lower-byte 68000 writes with real SDRAM DQM masking instead of
read-modify-write, and makes `init` forget latched/in-flight requests. The
complete functional delta is:

1. a new input port `ch1_be[1:0]` (`[1]` enables `DQ[15:8]`, `[0]` enables
   `DQ[7:0]`);
2. in `STATE_IDLE`, the ch1 grant line

   ```
   {cas_addr[12:9],SDRAM_BA,SDRAM_A,cas_addr[8:0]} <= {2'b00, 1'b1, ch1_addr[25:1]};
   ```

   becomes

   ```
   {cas_addr[12:9],SDRAM_BA,SDRAM_A,cas_addr[8:0]} <= {ch1_rnw ? 2'b00 : ~ch1_be, 1'b1, ch1_addr[25:1]};
   ```

3. inside the existing `if (init)` block, the request latches `ch1_rq`,
   `ch2_rq`, `ch3_rq` and the read-return pipelines `data_ready_delay1/2/3`
   are cleared. Upstream `init` restored only `state` and `refresh_count`, so
   a request latched during a refresh (or a read already returning data)
   survived a PLL-unlock `init`, re-executed after the 12,100-cycle startup
   with whatever address/data the channel inputs then carried, and pulsed a
   stale `ch1_ready` that the logical backend had already forgotten. The
   M15D lockstep bench reproduced a stale READ and a replayed WRITE on the
   unmodified logic (development bench `sim/m15d_controller_tb.sv`, in git history) and proves the
   clear removes both. `ch2_rq`/`ch3_rq`/`delay2/3` are cleared for symmetry;
   those channels are unused here.

`cas_addr[12:11]` is presented on `SDRAM_A[12:11]` during the column phase and
the controller already defines `{SDRAM_DQMH,SDRAM_DQML} = SDRAM_A[12:11]`, so
disabled lanes are masked at the WRITE command (SDRAM write DQM latency is
zero). Reads keep both masks low. Whole-word ROM/IOCTL writes pass `2'b11`
and behave exactly as before. Nothing else in the file changed; the ch2/ch3
data paths and the `altddio_out` clock forwarding are untouched. The
normalized (LF) blob SHA-1 of the modified file is
`53bf37947f1e1ec661bb68d5e97e511c569454e9`.

Same-lineage precedent: MiSTer-devel/PSX_MiSTer `rtl/sdram.sv` (also Sorgelig
2015-2019) drives its ch2 grant as
`{~ch2_be[1:0], ch2_rnw, ch2_addr[25:1]}` with the identical
`{SDRAM_DQMH,SDRAM_DQML} = SDRAM_A[12:11]` mapping.

## Simulation note

Quartus accepts the file unchanged. ModelSim rejects two upstream idioms;
the development benches (in git history) simulated a mechanically edited copy.

M15C used channel 1 in 16-bit mode at the existing 100 MHz system clock; M15D
keeps that arrangement. Channels 2 and 3 remain disabled.

## `crt_adjust.sv` (M26) — UNMODIFIED upstream copy

`crt_adjust.sv` originates from the **MiSTer-CRT-Adjust** project by
Umberto Parisi (rmonic79), with Andrea Bogazzi (@asturur):

- Upstream source used: local copy of `MiSTer-CRT-Adjust-master`,
  file `rtl/crt_adjust.sv`.
- Licence: **GNU GPL v3 or later** (the upstream `LICENSE` is the full
  GPLv3 text; the file's own header states "Distributed under GNU GPL v3
  or later"). This repository is GPL-3.0-or-later, so the licences are
  compatible.
- The original copyright/author/licence header is retained intact.

**This file is BYTE-IDENTICAL to upstream — it has no local
modifications.** All NA-1 integration lives in `NA1.sv` glue.
Verification of the vendored copy:

```
MD5       fc919129f4a1a9c3f7b95e745e8df26a
git blob  51556a59642465da8f4925f364302e05d3a06015
size      19706 bytes
```

Only `crt_adjust.sv` is vendored. The companion `crt_adjust_sys.sv`
(sys-side variant, would require editing `sys/sys_top.v`) and
`crt_vsize.sv` (V-Size) are deliberately **not** vendored: V-Size retimes
the line rate and adaptively narrows the HSync pulse, which would break
the `[HW-CONFIRMED]` M23 CRT envelope (development notes in git history).
