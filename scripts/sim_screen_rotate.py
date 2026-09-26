#!/usr/bin/env python3
"""Emit a ModelSim-ASE-17-compilable copy of the framework's screen_rotate.

sys/arcade_video.v's screen_rotate uses module-level regs/wires before their
declarations, which ModelSim ASE 17.0 rejects ("Undefined variable").  This
copies ONLY the screen_rotate module and moves its column-0 `reg`/`wire`
declarations (in their original order) to just after the port list.  Nothing
else changes: Verilog semantics do not depend on declaration order, and the
framework file itself is never modified.

Usage: python scripts/sim_screen_rotate.py <out.v>
"""
import re, sys, pathlib

root = pathlib.Path(__file__).resolve().parent.parent
src = (root / "sys" / "arcade_video.v").read_text(encoding="utf-8", errors="replace")
start = src.index("module screen_rotate")
end = src.index("endmodule", start) + len("endmodule")
mod = src[start:end].splitlines()

ports_end = next(i for i, l in enumerate(mod) if l.strip() == ");")
decls, body = [], []
for i, line in enumerate(mod):
    if i > ports_end and re.match(r"^(reg|wire)\b", line):
        decls.append(line)
    else:
        body.append(line)
if not decls:
    sys.exit("sim_screen_rotate: no declarations found (framework changed?)")
out = body[:ports_end + 1] + ["// ---- declarations hoisted for ModelSim ASE 17 (order preserved) ----"] + decls + body[ports_end + 1:]
pathlib.Path(sys.argv[1]).write_text("// GENERATED from sys/arcade_video.v by scripts/sim_screen_rotate.py\n" + "\n".join(out) + "\n", encoding="utf-8")
print(f"sim_screen_rotate: hoisted {len(decls)} declarations -> {sys.argv[1]}")
