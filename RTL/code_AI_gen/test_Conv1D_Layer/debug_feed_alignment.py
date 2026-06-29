#!/usr/bin/env python3
"""Compare InProj y_out beats vs x_before_conv_full / xz golden (feed alignment)."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

SEQ = 1000
LANES = 16


def si(h: str) -> int | None:
    if not h or "x" in h.lower():
        return None
    v = int(h, 16)
    return v - 0x10000 if v & 0x8000 else v


def read_mem(path: Path) -> list[int]:
    out: list[int] = []
    with path.open() as f:
        for line in f:
            s = line.strip()
            if s:
                out.append(si(s))  # type: ignore[arg-type]
    return out


def xbc_index(ch: int, t: int) -> int:
    return ch * SEQ + t


def xz_index(ch: int, t: int) -> int:
    return t * 256 + ch


def main() -> int:
    ap = argparse.ArgumentParser(description="Debug InProj->Conv feed alignment")
    ap.add_argument("N", type=int, nargs="?", default=1, help="number of tokens")
    ap.add_argument(
        "--inproj-mem",
        type=Path,
        default=None,
        help="optional captured InProj xz mem (flat t*256+ch layout)",
    )
    args = ap.parse_args()

    root = Path(__file__).resolve().parents[2]
    xbc = read_mem(root / "RTL/testbench/test_Conv1D&Silu/x_before_conv_full.mem")
    xz = read_mem(root / "RTL/testbench/test_Inprojection/golden_output_full.mem")

    if args.inproj_mem and args.inproj_mem.is_file():
        captured = read_mem(args.inproj_mem)
    else:
        captured = None

    n = args.N
    bad_x = bad_z = 0
    max_x = max_z = 0

    for t in range(n):
        for beat in range(16):
            grp = beat
            path_x = beat < 8
            for lane in range(LANES):
                if path_x:
                    ch = grp * LANES + lane
                    gi = xbc_index(ch, t)
                    gold = xbc[gi]
                else:
                    ch = 128 + (grp - 8) * LANES + lane
                    gi = xz_index(ch, t)
                    gold = xz[gi]

                if captured is not None:
                    ri = (t * 16 + beat) * LANES + lane
                    if ri >= len(captured):
                        continue
                    rtl = captured[ri]
                    d = abs(rtl - gold)
                    if path_x:
                        max_x = max(max_x, d)
                        if d > 16:
                            bad_x += 1
                    else:
                        max_z = max(max_z, d)
                        if d > 16:
                            bad_z += 1

    print(f"Feed alignment check N={n} (golden only layout sanity)")
    if captured is not None:
        print(f"  X beats bad={bad_x} max|diff|={max_x}")
        print(f"  Z beats bad={bad_z} max|diff|={max_z}")
        return 1 if (bad_x or bad_z) else 0

    print("  No --inproj-mem provided; golden index layout OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
