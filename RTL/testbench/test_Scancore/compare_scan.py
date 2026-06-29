#!/usr/bin/env python3
"""Compare streaming scan RTL dumps vs test_Scancore golden (tol=48 LSB)."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


def load_tol(path: Path, default: int = 48, key: str = "abs_error_lsb") -> int:
    if not path.is_file():
        return default
    for line in path.read_text().splitlines():
        m = re.match(rf"{re.escape(key)}=(\d+)", line.strip())
        if m:
            return int(m.group(1))
    return default


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


def gather_y_samples(
    rtl: list[int],
    gold: list[int],
    tokens: int,
    channels: int = 128,
) -> tuple[list[int], list[int]]:
    """RTL dump is token-major (tok*128+ch); golden is channel-major (ch*SEQ+tok)."""
    seq_stride = len(gold) // channels
    rtl_out: list[int] = []
    gold_out: list[int] = []
    for tok in range(tokens):
        for ch in range(channels):
            rtl_out.append(rtl[tok * channels + ch])
            gold_out.append(gold[ch * seq_stride + tok])
    return rtl_out, gold_out


def compare(name: str, rtl: list[int], gold: list[int], tol: int) -> bool:
    n = min(len(rtl), len(gold))
    bad = 0
    max_d = 0
    for i in range(n):
        d = abs(rtl[i] - gold[i])
        max_d = max(max_d, d)
        if d > tol:
            bad += 1
    print(f"[{name}] samples={n} bad={bad} max|diff|={max_d} tol={tol}")
    if bad and bad <= 10:
        shown = 0
        for i in range(n):
            d = abs(rtl[i] - gold[i])
            if d > tol and shown < 10:
                print(f"  idx={i} rtl={rtl[i]} gold={gold[i]} diff={d}")
                shown += 1
    return bad == 0


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", type=Path, default=Path(__file__).resolve().parent)
    ap.add_argument("--tokens", type=int, default=None)
    ap.add_argument(
        "--skip-h",
        action="store_true",
        help="Skip h_state compare (h_live prod mode keeps per-channel state only)",
    )
    ap.add_argument(
        "--y-gold",
        type=str,
        default="golden_y_gated.mem",
        help="y golden mem (default: golden_y_gated.mem = cpp float y_pre*silu(z))",
    )
    args = ap.parse_args()
    root = args.dir
    tol_path = root / "compare_tolerance.txt"
    tol_h = load_tol(tol_path)
    tol_y = load_tol(tol_path, key="y_gated_abs_error_lsb", default=tol_h)

    y_gold_full = read_mem(root / args.y_gold)
    seq_stride = len(y_gold_full) // 128
    tokens = args.tokens if args.tokens is not None else seq_stride

    h_n = tokens * 128 * 16
    y_n = tokens * 128

    h_rtl = read_mem(root / "rtl_h_state_stream.mem")[:h_n]
    h_gold = read_mem(root / "h_state.mem")[:h_n]
    y_rtl_raw = read_mem(root / "rtl_y_gated_stream.mem")
    if len(y_rtl_raw) < y_n:
        print(f"[y_gated] ERROR: rtl dump has {len(y_rtl_raw)} samples, need {y_n} (sim incomplete?)")
        print("FAIL")
        raise SystemExit(1)
    y_rtl_raw = y_rtl_raw[:y_n]
    y_rtl, y_gold = gather_y_samples(y_rtl_raw, y_gold_full, tokens)

    if args.skip_h:
        print("[h_state] skipped (--skip-h, h_live mode)")
        ok_h = True
    else:
        ok_h = compare("h_state", h_rtl, h_gold, tol_h)
    ok_y = compare("y_gated_float", y_rtl, y_gold, tol_y)

    if ok_h and ok_y:
        print("PASS")
        raise SystemExit(0)
    print("FAIL")
    raise SystemExit(1)


if __name__ == "__main__":
    main()
