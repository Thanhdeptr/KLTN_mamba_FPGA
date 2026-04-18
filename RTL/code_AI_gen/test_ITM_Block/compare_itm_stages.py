#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import argparse
import numpy as np


def read_mem(path: Path) -> np.ndarray:
    vals = []
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            s = line.strip()
            if not s:
                continue
            v = int(s, 16)
            if v & 0x8000:
                v -= 0x10000
            vals.append(v)
    return np.array(vals, dtype=np.int32)


def cmp(name: str, rtl: Path, gold: Path, tol: int, max_bad_ratio: float) -> bool:
    r = read_mem(rtl)
    g = read_mem(gold)
    n = min(r.size, g.size)
    if n == 0:
        print(f"[{name}] FAIL empty")
        return False
    r = r[:n]
    g = g[:n]
    err = np.abs(r - g)
    bad = err > tol
    ratio = float(np.mean(bad))
    print(
        f"[{name}] n={n} MAE={float(np.mean(err)):.3f} MAX={int(np.max(err))} "
        f"bad(>{tol})={int(np.sum(bad))} ({ratio:.2%}) limit={max_bad_ratio:.2%}"
    )
    if np.any(bad):
        idx = np.where(bad)[0][:8]
        for i in idx:
            print(f"  idx={int(i)} gold={int(g[i])} rtl={int(r[i])} err={int(err[i])}")
    return ratio <= max_bad_ratio


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", type=Path, default=Path("."))
    ap.add_argument("--tol-conv", type=int, default=2)
    ap.add_argument("--tol-scan", type=int, default=32)
    ap.add_argument("--tol-merge", type=int, default=32)
    ap.add_argument("--max-bad-conv", type=float, default=0.05)
    ap.add_argument("--max-bad-scan", type=float, default=0.1)
    ap.add_argument("--max-bad-merge", type=float, default=0.05)
    args = ap.parse_args()

    d = args.dir
    ok_conv = cmp(
        "CONV_BRANCH",
        d / "rtl_conv_branch.mem",
        d / "golden_conv_branch.mem",
        args.tol_conv,
        args.max_bad_conv,
    )
    ok_scan = cmp(
        "SCAN_SCALAR",
        d / "rtl_scan_scalar.mem",
        d / "golden_scan_scalar.mem",
        args.tol_scan,
        args.max_bad_scan,
    )
    ok_merge = cmp(
        "MERGE_OUT",
        d / "rtl_output.mem",
        d / "golden_merge_output.mem",
        args.tol_merge,
        args.max_bad_merge,
    )

    all_ok = ok_conv and ok_scan and ok_merge
    print("PASS" if all_ok else "FAIL")
    return 0 if all_ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
