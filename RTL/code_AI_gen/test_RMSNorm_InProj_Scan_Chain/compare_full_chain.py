#!/usr/bin/env python3
"""Compare full-chain dumps vs scan reference built from conv-chain x/z."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path


def load_tol(path: Path, default: int = 48) -> int:
    if not path.is_file():
        return default
    for line in path.read_text().splitlines():
        m = re.match(r"abs_error_lsb=(\d+)", line.strip())
        if m:
            return int(m.group(1))
    return default


def read_mem(path: Path) -> list[int | None]:
    out: list[int | None] = []
    for line in path.read_text().splitlines():
        s = line.strip()
        if not s:
            continue
        if re.fullmatch(r"[xXzZ?_.]+", s):
            out.append(None)
            continue
        v = int(s, 16) & 0xFFFF
        if v & 0x8000:
            v -= 0x10000
        out.append(v)
    return out


def line_count(path: Path) -> int:
    return sum(1 for line in path.read_text().splitlines() if line.strip())


def compare(name: str, rtl: list[int | None], gold: list[int | None], tol: int) -> bool:
    n = min(len(rtl), len(gold))
    bad = max_d = x_bad = compared = 0
    for i in range(n):
        r, g = rtl[i], gold[i]
        if r is None or g is None:
            if r is None:
                x_bad += 1
            continue
        compared += 1
        d = abs(r - g)
        max_d = max(max_d, d)
        if d > tol:
            bad += 1
    print(
        f"[{name}] samples={n} compared={compared} bad={bad} "
        f"xxxx={x_bad} max|diff|={max_d} tol={tol}"
    )
    return bad == 0 and x_bad == 0


def ensure_scan_ref(root: Path, tokens: int) -> None:
    y_ref = root / "rtl_y_scan_ref.mem"
    h_ref = root / "rtl_h_scan_ref.mem"
    need_y = tokens * 128
    if y_ref.is_file() and h_ref.is_file():
        if len(read_mem(y_ref)) >= need_y:
            return
    x_dump = root / "rtl_output_conv_x_chain.mem"
    script = root / ("run_scan_from_dumps.sh" if x_dump.is_file() else "run_scan_ref.sh")
    print(f"[compare] generating scan reference via {script.name} N={tokens}")
    subprocess.run([str(script), str(tokens)], check=True, cwd=root)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", type=Path, default=Path(__file__).resolve().parent)
    ap.add_argument("--gold-dir", type=Path, default=None)
    ap.add_argument("--tokens", type=int, default=10)
    ap.add_argument("--skip-ref", action="store_true")
    ap.add_argument("--skip-h", action="store_true", help="Skip h_state compare (h_live mode)")
    args = ap.parse_args()

    root = args.dir
    gold_dir = args.gold_dir or (root.parent.parent / "testbench" / "test_Scancore")
    tol = load_tol(gold_dir / "compare_tolerance.txt")
    tokens = args.tokens
    y_n = tokens * 128
    h_n = tokens * 128 * 16

    y_dump = root / "rtl_y_gated_chain.mem"
    if line_count(y_dump) < y_n:
        print(f"FAIL: y dump short ({line_count(y_dump)} lines < {y_n})")
        raise SystemExit(1)

    if not args.skip_ref:
        ensure_scan_ref(root, tokens)

    y_ref_path = root / "rtl_y_scan_ref.mem"
    if y_ref_path.is_file() and (root / "rtl_output_conv_x_chain.mem").is_file():
        if y_ref_path.stat().st_mtime < (root / "rtl_output_conv_x_chain.mem").stat().st_mtime:
            print("[compare] conv dumps newer than ref, regenerating scan reference")
            subprocess.run([str(root / "run_scan_from_dumps.sh"), str(tokens)], check=True, cwd=root)

    y_rtl = read_mem(y_dump)[:y_n]
    y_ref = read_mem(root / "rtl_y_scan_ref.mem")[:y_n]
    if args.skip_h:
        print("[h_state_e2e] skipped (--skip-h, h_live mode)")
        ok_h = True
    else:
        h_rtl = read_mem(root / "rtl_h_state_chain.mem")[:h_n]
        h_ref = read_mem(root / "rtl_h_scan_ref.mem")[:h_n]
        ok_h = compare("h_state_e2e", h_rtl, h_ref, tol) if len(h_rtl) >= h_n else (
            print(f"[h_state_e2e] skip: dump len={len(h_rtl)}"), False
        )[1]

    ok_y = compare("y_gated_e2e", y_rtl, y_ref, tol)

    if ok_y and ok_h:
        print("PASS")
        raise SystemExit(0)
    print("FAIL")
    raise SystemExit(1)


if __name__ == "__main__":
    main()
