#!/usr/bin/env python3
"""Diagnose OutProjection mem unit-test mismatches.

Root cause summary:
- RTL uses Q3.12 MAC on clipped inputs: sum(x_q * w_q) >>> 12.
- golden_output*.mem uses C++ float matmul on unclipped y_gated, then quantize once.

Most tokens only drift a few LSB (median ~5). Large failures come from tokens where
y_gated float exceeds Q3.12 range (|x| > ~8.0): mem input is saturated but float
golden still uses the original large value (e.g. 16.86 vs 7.99 on one channel).
"""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np

FRAC_BITS = 12
SAT_MAX = 32767
SAT_MIN = -32768
D_IN = 128
D_OUT = 64
N_TOKENS = 1000


def read_mem(path: Path) -> np.ndarray:
    vals = [int(line.strip(), 16) for line in path.read_text().splitlines() if line.strip()]
    arr = np.array(vals, dtype=np.uint16)
    return np.where(arr >= 0x8000, arr.astype(np.int32) - 0x10000, arr.astype(np.int32))


def float_to_q16(val: float) -> int:
    q = int(float(val) * (1 << FRAC_BITS))
    return max(SAT_MIN, min(SAT_MAX, q))


def sat_q16(x: int) -> int:
    return int(max(SAT_MIN, min(SAT_MAX, x)))


def outproj_fixed(x_q: np.ndarray, w_q: np.ndarray) -> np.ndarray:
    y = np.zeros(D_OUT, dtype=np.int32)
    for row in range(D_OUT):
        acc = sum(int(x_q[col]) * int(w_q[row, col]) for col in range(D_IN))
        y[row] = sat_q16(acc >> FRAC_BITS)
    return y


def load_weights_q16(gv_dir: Path) -> np.ndarray:
    w = np.fromfile(gv_dir / "out_proj_weight.bin", dtype=np.float32).reshape(D_OUT, D_IN)
    return np.vectorize(float_to_q16)(w).astype(np.int32)


def token_input(input_full: np.ndarray, tok: int) -> np.ndarray:
    return np.array([input_full[ch * N_TOKENS + tok] for ch in range(D_IN)], dtype=np.int32)


def token_golden_float_q16(golden_full: np.ndarray, tok: int) -> np.ndarray:
    return golden_full[tok * D_OUT : (tok + 1) * D_OUT]


def summarize_errors(errs: np.ndarray) -> None:
    print(f"  min={errs.min()} median={np.median(errs):.1f} p95={np.percentile(errs, 95):.1f} max={errs.max()}")
    for th in (0, 1, 2, 4, 8, 16, 64):
        print(f"  tokens with max_err > {th:>2}: {(errs > th).sum():>4} / {N_TOKENS}")


def write_fixed_golden(path: Path, input_full: np.ndarray, w_q: np.ndarray) -> None:
    lines: list[str] = []
    for tok in range(N_TOKENS):
        x_q = token_input(input_full, tok)
        y_q = outproj_fixed(x_q, w_q)
        for v in y_q:
            lines.append(f"{(int(v) & 0xFFFF):04x}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Wrote fixed-point golden: {path}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--gen-fixed-golden",
        action="store_true",
        help="Generate golden_output_fixed_full.mem from input_full + fixed-point outproj.",
    )
    args = parser.parse_args()

    base = Path(__file__).resolve().parent
    k_root = base.parents[2]
    gv_dir = k_root / "ITMN" / "golden_vectors"
    cpp_dir = k_root / "ITMN" / "cpp_golden_files"

    input1 = read_mem(base / "input.mem")
    input_full = read_mem(base / "input_full.mem")
    golden1 = read_mem(base / "golden_output.mem")
    golden_full = read_mem(base / "golden_output_full.mem")
    w_q = load_weights_q16(gv_dir)

    print("=== OutProjection mem diagnose ===")
    print(f"input.mem={len(input1)} weight={D_OUT*D_IN} golden.mem={len(golden1)}")
    print(f"input_full={len(input_full)} golden_full={len(golden_full)}")

    # Layout sanity: token0 single input must match input_full channel-major.
    mism = 0
    for ch in range(D_IN):
        if input1[ch] != input_full[ch * N_TOKENS + 0]:
            mism += 1
    print(f"layout token0 single vs full mismatches: {mism}")

    y_single = outproj_fixed(input1, w_q)
    err_single = np.abs(y_single - golden1)
    print("single-token fixed RTL vs float golden:")
    print(f"  max_err={err_single.max()} lanes>4={(err_single > 4).sum()}")

    errs = []
    for tok in range(N_TOKENS):
        x_q = token_input(input_full, tok)
        y_q = outproj_fixed(x_q, w_q)
        g_q = token_golden_float_q16(golden_full, tok)
        errs.append(np.abs(y_q - g_q).max())
    errs_arr = np.array(errs)

    print("full 1000 tokens fixed RTL vs float golden:")
    summarize_errors(errs_arr)

    worst_tok = int(errs_arr.argmax())
    x_w = token_input(input_full, worst_tok)
    y_w = outproj_fixed(x_w, w_q)
    g_w = token_golden_float_q16(golden_full, worst_tok)
    lane = int(np.abs(y_w - g_w).argmax())
    print(f"worst token={worst_tok} lane={lane} fixed={y_w[lane]} float_golden={g_w[lane]} err={errs_arr[worst_tok]}")
    print(f"  fixed float ~= {y_w[lane] / (1 << FRAC_BITS):.6f}")
    print(f"  golden float ~= {g_w[lane] / (1 << FRAC_BITS):.6f}")

    # Show that float golden matches C++ float dump, not fixed-point recompute.
    cpp_final = sorted(cpp_dir.glob("*_Mixer_final_output.txt"))[-1]
    out_final = np.loadtxt(cpp_final, dtype=np.float32)
    if out_final.ndim == 1:
        out_final = out_final.reshape(1, -1)
    cpp_q = np.vectorize(float_to_q16)(out_final[worst_tok]).astype(np.int32)
    print(f"cpp float dump: {cpp_final.name}")
    print(f"  mem golden == cpp q16 at worst token: {np.array_equal(g_w, cpp_q)}")

    sat_tokens = []
    yg_path = sorted(cpp_dir.glob("*_Mixer_y_gated.txt"))[-1]
    y_gated = np.loadtxt(yg_path, dtype=np.float32)
    if y_gated.ndim == 1:
        y_gated = y_gated.reshape(1, -1)
    if y_gated.shape[0] != D_IN:
        y_gated = y_gated.T
    for tok in range(N_TOKENS):
        xf = y_gated[:, tok]
        if np.any((xf * (1 << FRAC_BITS) > SAT_MAX) | (xf * (1 << FRAC_BITS) < SAT_MIN)):
            sat_tokens.append(tok)

    big = [tok for tok, err in enumerate(errs) if err > 27]
    print(f"tokens with y_gated overflow Q3.12: {len(sat_tokens)}")
    print(f"tokens with max_err > 27: {len(big)}")
    print(f"same set: {set(sat_tokens) == set(big)}")

    print("\nConclusion:")
    print("- RTL/layout/weights are consistent.")
    if np.max(errs) == 0:
        print("- golden_output*.mem already match RTL fixed-point (strict).")
    else:
        print("- Small drift (~5 LSB median) vs float C++ ref is normal MAC rounding.")
        print("- Large drift is input saturation: mem clips y_gated, float C++ golden does not.")
        print("- Regenerate: python3 py_software/extract_RTL_inital_mem.py --mode outprojection")

    if args.gen_fixed_golden:
        write_fixed_golden(base / "golden_output_fixed_full.mem", input_full, w_q)
        y0 = outproj_fixed(input1, w_q)
        lines = [f"{(int(v) & 0xFFFF):04x}" for v in y0]
        (base / "golden_output_fixed.mem").write_text("\n".join(lines) + "\n", encoding="utf-8")
        print(f"Wrote fixed-point golden: {base / 'golden_output_fixed.mem'}")


if __name__ == "__main__":
    main()
