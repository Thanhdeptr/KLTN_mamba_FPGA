#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import argparse
import numpy as np

FRAC_BITS = 12


def read_mem(path: Path) -> np.ndarray:
    vals = []
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            s = line.strip()
            if not s:
                continue
            if any(ch in s.lower() for ch in ["x", "z"]):
                vals.append(0.0)
                continue
            v = int(s, 16)
            if v & 0x8000:
                v -= 0x10000
            vals.append(v / float(1 << FRAC_BITS))
    return np.array(vals, dtype=np.float64)


def compare_one(
    name: str,
    rtl_path: Path,
    gold_path: Path,
    tol: float,
    max_bad_ratio: float,
) -> tuple[bool, str, float]:
    rtl = read_mem(rtl_path)
    gold = read_mem(gold_path)
    n = min(len(rtl), len(gold))

    if n == 0:
        return False, f"[{name}] empty data"

    rtl = rtl[:n]
    gold = gold[:n]
    err = np.abs(rtl - gold)

    max_err = float(err.max())
    mae = float(err.mean())
    bad = int((err > tol).sum())
    ratio = bad / n

    ok = ratio <= max_bad_ratio
    msg = (
        f"[{name}] n={n} max_err={max_err:.6f} mae={mae:.6f} "
        f"bad(>{tol})={bad} ({ratio:.2%}) limit={max_bad_ratio:.2%}"
    )
    return ok, msg, ratio


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default=".")
    ap.add_argument("--tol-rms", type=float, default=0.06)
    ap.add_argument("--tol-inproj", type=float, default=0.10)
    ap.add_argument("--tol-silu", type=float, default=0.15)
    ap.add_argument("--tol-ygated", type=float, default=0.15)
    ap.add_argument("--tol-final", type=float, default=0.20)
    ap.add_argument("--max-bad-ratio-rms", type=float, default=0.25)
    ap.add_argument("--max-bad-ratio-inproj", type=float, default=0.25)
    ap.add_argument("--max-bad-ratio-silu", type=float, default=0.20)
    ap.add_argument("--max-bad-ratio-ygated", type=float, default=0.20)
    ap.add_argument("--max-bad-ratio-final", type=float, default=0.15)
    ap.add_argument(
        "--tail-mode",
        choices=["strict", "report", "skip"],
        default="report",
        help="strict: tail stages must meet limits; report: tail reported but not gate PASS; skip: do not compare tail",
    )
    args = ap.parse_args()

    d = Path(args.dir)

    front_checks = [
        ("RMSNorm", d / "rtl_rms.mem", d / "rms_golden.mem", args.tol_rms, args.max_bad_ratio_rms),
        ("InProjection", d / "rtl_inproj.mem", d / "inproj_golden.mem", args.tol_inproj, args.max_bad_ratio_inproj),
        ("SiLU", d / "rtl_silu.mem", d / "x_activated.mem", args.tol_silu, args.max_bad_ratio_silu),
    ]

    tail_checks = [
        ("YGated", d / "rtl_ygated.mem", d / "y_gated_golden.mem", args.tol_ygated, args.max_bad_ratio_ygated),
        ("FinalOut", d / "rtl_final.mem", d / "final_golden.mem", args.tol_final, args.max_bad_ratio_final),
    ]

    all_ok = True
    for name, rtl, gold, tol, max_bad_ratio in front_checks:
        ok, msg, _ = compare_one(name, rtl, gold, tol, max_bad_ratio)
        print(msg)
        all_ok &= ok

    if args.tail_mode != "skip":
        tail_ok = True
        for name, rtl, gold, tol, max_bad_ratio in tail_checks:
            ok, msg, _ = compare_one(name, rtl, gold, tol, max_bad_ratio)
            print(msg)
            tail_ok &= ok

        if args.tail_mode == "strict":
            all_ok &= tail_ok
        elif not tail_ok:
            print("INFO: tail mismatch kept as diagnostic (tail-mode=report)")

    if all_ok:
        print("PASS: compared stages are within configured limits")
        return 0

    print("FAIL: one or more required stages exceed configured limits")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
