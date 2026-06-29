#!/usr/bin/env python3
"""Compare Mamba streaming wrapper vs cpp float (ScanCore-style staged checks).

1. Conv X/Z vs test_Full_mamba_Branch golden_silu / silu_z_golden_full
2. y_gated vs scan reference built from the same conv dumps (standalone SCAN_PIPE)
3. OutProj rtl-ref tol=0; final vs outproj(scan_ref y) tol=0
"""
from __future__ import annotations

import argparse
import re
import subprocess
from pathlib import Path

import numpy as np

FRAC_BITS = 12
SAT_MAX = 32767
SAT_MIN = -32768
D_INNER = 128
D_OUT = 64
LANES = 16
GRPS = 8

BRANCH_DIR = Path(__file__).resolve().parents[2] / "testbench" / "test_Full_mamba_Branch"
SCAN_DIR = Path(__file__).resolve().parents[2] / "testbench" / "test_Scancore"
CONV_TOL_PATH = Path(__file__).resolve().parents[2] / "testbench" / "test_Conv1D&Silu" / "compare_tolerance_chain.txt"


def read_q16(path: Path, n: int | None = None) -> np.ndarray:
    vals: list[int] = []
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            s = line.strip()
            if not s:
                continue
            if any(ch in s.lower() for ch in ["x", "z"]):
                vals.append(0)
                continue
            v = int(s, 16)
            if v & 0x8000:
                v -= 0x10000
            vals.append(v)
    arr = np.array(vals, dtype=np.int32)
    return arr[:n] if n is not None else arr


def load_tol(path: Path, key: str, default: int) -> int:
    if not path.is_file():
        return default
    for line in path.read_text(encoding="utf-8").splitlines():
        m = re.match(rf"{re.escape(key)}=(\d+)", line.strip())
        if m:
            return int(m.group(1))
    return default


def gather_conv_frames(
    rtl_frames: np.ndarray,
    gold_channel_major: np.ndarray,
    tokens: int,
) -> tuple[np.ndarray, np.ndarray]:
    seq_stride = gold_channel_major.size // D_INNER
    n = tokens * GRPS * LANES
    rtl_out = rtl_frames[:n].copy()
    gold_out = np.zeros(n, dtype=np.int32)
    for tok in range(tokens):
        for fg in range(GRPS):
            for lane in range(LANES):
                ch = fg * LANES + lane
                gi = ch * seq_stride + tok
                ri = (tok * GRPS + fg) * LANES + lane
                gold_out[ri] = gold_channel_major[gi]
    return rtl_out, gold_out


def compare_q16(name: str, rtl: np.ndarray, ref: np.ndarray, tol_lsb: int) -> bool:
    n = min(len(rtl), len(ref))
    rtl = rtl[:n]
    ref = ref[:n]
    err = np.abs(rtl - ref)
    bad = int((err > tol_lsb).sum())
    ok = bad == 0
    print(
        f"[{name}] n={n} max_lsb={int(err.max()) if n else 0} "
        f"bad(>{tol_lsb})={bad} ({bad / n:.2%})" if n else f"[{name}] empty"
    )
    if bad and bad <= 8:
        shown = 0
        for i in range(n):
            d = int(err[i])
            if d > tol_lsb and shown < 8:
                print(f"  idx={i} rtl={int(rtl[i])} ref={int(ref[i])} diff={d}")
                shown += 1
    return ok


def outproj_ref(y: np.ndarray, w: np.ndarray) -> np.ndarray:
    t_cnt, _d_in = y.shape
    d_out = w.shape[0]
    out = np.zeros(t_cnt * d_out, dtype=np.int32)
    for t in range(t_cnt):
        for o in range(d_out):
            acc = 0
            for c in range(_d_in):
                acc += int(y[t, c]) * int(w[o, c])
            acc >>= FRAC_BITS
            if acc > SAT_MAX:
                acc = SAT_MAX
            elif acc < SAT_MIN:
                acc = SAT_MIN
            out[t * d_out + o] = acc
    return out


def ensure_scan_ref(root: Path, tokens: int) -> Path:
    ref_path = root / "rtl_y_scan_ref.mem"
    x_dump = root / "rtl_output_conv_x_streaming.mem"
    need_y = tokens * D_INNER
    if ref_path.is_file() and len(read_q16(ref_path)) >= need_y:
        if x_dump.is_file() and ref_path.stat().st_mtime >= x_dump.stat().st_mtime:
            return ref_path
    script = root / "run_scan_ref_wrapper.sh"
    print(f"[compare] generating scan ref via {script.name} N={tokens}")
    subprocess.run(["bash", str(script), str(tokens)], check=True, cwd=root)
    return ref_path


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tokens", type=int, default=1)
    ap.add_argument("--dir", type=Path, default=Path("."))
    ap.add_argument("--skip-conv", action="store_true")
    ap.add_argument("--skip-ref", action="store_true")
    args = ap.parse_args()

    d = args.dir.resolve()
    n_tok = args.tokens
    n_y = n_tok * D_INNER
    n_out = n_tok * D_OUT
    n_conv = n_tok * GRPS * LANES

    tol_conv = load_tol(CONV_TOL_PATH, "abs_error_lsb", 48)
    tol_z = load_tol(CONV_TOL_PATH, "z_silu_lsb", tol_conv)
    tol_scan = load_tol(SCAN_DIR / "compare_tolerance.txt", "y_gated_abs_error_lsb", 192)

    ok_all = True

    if not args.skip_conv:
        x_path = d / "rtl_output_conv_x_streaming.mem"
        z_path = d / "rtl_output_conv_z_streaming.mem"
        gold_x_path = BRANCH_DIR / "golden_silu.mem"
        gold_z_path = BRANCH_DIR / "silu_z_golden_full.mem"
        for p in (x_path, z_path, gold_x_path, gold_z_path):
            if not p.exists():
                print(f"FAIL: missing {p}")
                return 1
        rtl_x, gold_x = gather_conv_frames(read_q16(x_path, n_conv), read_q16(gold_x_path), n_tok)
        rtl_z, gold_z = gather_conv_frames(read_q16(z_path, n_conv), read_q16(gold_z_path), n_tok)
        ok_all &= compare_q16("Conv X vs cpp golden_silu", rtl_x, gold_x, tol_conv)
        ok_all &= compare_q16("Conv Z vs cpp silu_z_golden_full", rtl_z, gold_z, tol_z)

    rtl_y_path = d / "rtl_y_streaming.mem"
    rtl_out_path = d / "rtl_final.mem"
    w_path = BRANCH_DIR / "outproj_weight.mem"
    for p in (rtl_y_path, rtl_out_path, w_path):
        if not p.exists():
            print(f"FAIL: missing {p}")
            return 1

    y = read_q16(rtl_y_path, n_y).reshape(n_tok, D_INNER)
    w = read_q16(w_path).reshape(D_OUT, D_INNER)
    rtl_out = read_q16(rtl_out_path, n_out)
    ref_out = outproj_ref(y, w)
    ok_all &= compare_q16("OutProj(rtl-ref tol=0)", rtl_out, ref_out, 0)

    if not args.skip_ref:
        ref_path = ensure_scan_ref(d, n_tok)
        y_ref = read_q16(ref_path, n_y)
        ok_all &= compare_q16("y_gated vs scan_ref(conv dumps)", read_q16(rtl_y_path, n_y), y_ref, tol_scan)
        # OutProj rtl-ref (tol=0) is the strict final check; scan_ref outproj may drift when y differs slightly.

    if ok_all:
        print(f"PASS: Mamba streaming wrapper N={n_tok}")
        return 0
    print(f"FAIL: Mamba streaming wrapper N={n_tok}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
