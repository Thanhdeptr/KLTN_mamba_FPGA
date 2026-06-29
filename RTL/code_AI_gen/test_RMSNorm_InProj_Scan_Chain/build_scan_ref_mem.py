#!/usr/bin/env python3
"""Build channel-major x_activated / silu_z mem from conv-chain flat dumps."""

from __future__ import annotations

import argparse
from pathlib import Path

LANES = 16
GRPS = 8
D_INNER = 128
SEQ_STRIDE = 1000


def read_mem(path: Path) -> list[int]:
    out: list[int] = []
    for line in path.read_text().splitlines():
        s = line.strip()
        if not s or "x" in s.lower():
            continue
        v = int(s, 16) & 0xFFFF
        if v & 0x8000:
            v -= 0x10000
        out.append(v)
    return out


def write_mem(path: Path, vals: list[int]) -> None:
    path.write_text("\n".join(f"{v & 0xFFFF:04x}" for v in vals) + "\n")


def flat_to_channel_major(flat: list[int], tokens: int) -> list[int]:
    """flat frame order: token-major, 8 frames/token, 16 lanes/frame (grp=f)."""
    out = [0] * (D_INNER * SEQ_STRIDE)
    frames_per_tok = GRPS
    for tok in range(tokens):
        for grp in range(frames_per_tok):
            base = (tok * frames_per_tok + grp) * LANES
            if base + LANES > len(flat):
                break
            for lane in range(LANES):
                ch = grp * LANES + lane
                out[ch * SEQ_STRIDE + tok] = flat[base + lane]
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--conv-dir", type=Path, required=True)
    ap.add_argument("--out-dir", type=Path, required=True)
    ap.add_argument("--tokens", type=int, default=1)
    ap.add_argument("--x-file", type=str, default="rtl_output_conv_x_chain.mem")
    ap.add_argument("--z-file", type=str, default="rtl_output_conv_z_chain.mem")
    args = ap.parse_args()

    x_flat = read_mem(args.conv_dir / args.x_file)
    z_flat = read_mem(args.conv_dir / args.z_file)
    n_frames = args.tokens * GRPS
    need = n_frames * LANES
    if len(x_flat) < need or len(z_flat) < need:
        raise SystemExit(
            f"conv mem too short: x={len(x_flat)} z={len(z_flat)} need {need}"
        )

    args.out_dir.mkdir(parents=True, exist_ok=True)
    write_mem(args.out_dir / "x_activated_ref.mem", flat_to_channel_major(x_flat, args.tokens))
    write_mem(args.out_dir / "silu_z_ref.mem", flat_to_channel_major(z_flat, args.tokens))
    print(f"[ref] wrote x/z channel-major for N={args.tokens} -> {args.out_dir}")


if __name__ == "__main__":
    main()
