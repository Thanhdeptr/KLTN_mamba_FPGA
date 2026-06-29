#!/usr/bin/env python3
"""Generate CLZ-indexed 32-bit rsqrt seed LUT for FastRsqrt_CLZ_LUT."""

from __future__ import annotations

import argparse
import math
from pathlib import Path

FRAC_BITS = 12


def msb_pos(v: int) -> int:
    if v <= 0:
        return 0
    return v.bit_length() - 1


def norm_index(x_q: int) -> int:
    m = msb_pos(x_q)
    if m >= 14:
        x_norm = x_q >> (m - 14)
    else:
        x_norm = x_q << (14 - m)
    idx = ((min(m, 15) & 0xF) << 2) | ((x_norm >> 12) & 0x3)
    return min(idx, 63)


def build_rom(max_x_q: int = 70000) -> list[int]:
    rom = []
    for idx in range(64):
        candidates = [xq for xq in range(1, max_x_q) if norm_index(xq) == idx]
        mid = candidates[len(candidates) // 2] if candidates else 1
        val = int(round((1.0 / math.sqrt(mid / (2**FRAC_BITS))) * (2**FRAC_BITS)))
        rom.append(val)
    return rom


def write_mem(path: Path, rom: list[int]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        for val in rom:
            f.write(f"{val & 0xFFFFFFFF:08x}\n")
    print(f"Wrote {path} ({len(rom)} entries, max={max(rom)})")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--out",
        type=Path,
        default=Path(__file__).resolve().parents[2]
        / "RTL"
        / "code_initial"
        / "rmsnorm_rsqrt_coeffs.mem",
    )
    args = ap.parse_args()
    write_mem(args.out, build_rom())


if __name__ == "__main__":
    main()
