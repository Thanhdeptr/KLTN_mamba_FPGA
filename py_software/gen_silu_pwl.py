"""
Generate SiLU PWL coefficients (silu_pwl_coeffs.mem) for SiLU_Unit_PWL.v
and optionally golden fixed-point output for RTL test.
Run from project root: python3 py_software/gen_silu_pwl.py [options]
"""

import argparse
import numpy as np
from pathlib import Path

FRAC_BITS = 12  # Q3.12
SCALE = 1 << FRAC_BITS  # 4096


def silu_real(x: np.ndarray) -> np.ndarray:
    """SiLU(x) = x / (1 + exp(-x))."""
    return x / (1.0 + np.exp(-x))


def generate_pwl_coeffs(func, x_min=-4.0, x_max=4.0, n_seg=64, fit_mode="l2"):
    """
    Fit PWL y = a*x + b per segment; return slopes_q, intercepts_q (Q3.12).
    Segment boundaries MUST match RTL: addr = in_data[15:10] (6 MSBs of 16-bit).
    So each addr covers 1024 consecutive Q3.12 values.
    addr 0..31:  x in [0, 0.25), [0.25, 0.5), ..., [7.75, 8)
    addr 32..63: x in [-8, -7.75), [-7.75, -7.5), ..., [-0.25, 0)
    """
    slopes = []
    intercepts = []
    SEG_SIZE = 1024  # 2^10 values per addr

    for addr in range(n_seg):
        if addr < 32:
            in_left = addr * SEG_SIZE
            in_right = (addr + 1) * SEG_SIZE
        else:
            in_left = -32768 + (addr - 32) * SEG_SIZE
            in_right = -32768 + (addr - 32 + 1) * SEG_SIZE

        xl = in_left / float(SCALE)
        xr = in_right / float(SCALE)

        if fit_mode == "endpoint":
            yl = func(np.array([xl], dtype=np.float64))[0]
            yr = func(np.array([xr], dtype=np.float64))[0]

            denom = xr - xl
            if abs(denom) < 1e-12:
                a = 0.0
                b = yl
            else:
                a = (yr - yl) / denom
                b = yl - a * xl
        else:
            # L2 linear fit over every representable Q3.12 point in this segment.
            x_q = np.arange(in_left, in_right, dtype=np.int32)
            x_seg = x_q.astype(np.float64) / float(SCALE)
            y_seg = func(x_seg)
            A = np.stack([x_seg, np.ones_like(x_seg)], axis=1)
            a, b = np.linalg.lstsq(A, y_seg, rcond=None)[0]

        slopes.append(a)
        intercepts.append(b)

    slopes = np.array(slopes, dtype=np.float64)
    intercepts = np.array(intercepts, dtype=np.float64)

    slopes_q = np.round(slopes * SCALE).astype(np.int32)
    intercepts_q = np.round(intercepts * SCALE).astype(np.int32)

    slopes_q = np.clip(slopes_q, -32768, 32767)
    intercepts_q = np.clip(intercepts_q, -32768, 32767)

    return slopes_q, intercepts_q


def write_mem_file(slopes_q, intercepts_q, mem_path: str):
    """Write 64 lines of 8-hex (32-bit: slope|intercept) for $readmemh."""
    mem_path = Path(mem_path)
    mem_path.parent.mkdir(parents=True, exist_ok=True)

    with mem_path.open("w") as f:
        for a_q, b_q in zip(slopes_q, intercepts_q):
            a16 = np.uint16(np.int16(a_q))
            b16 = np.uint16(np.int16(b_q))
            word = (int(a16) << 16) | int(b16)
            f.write(f"{word:08x}\n")

    print(f"[INFO] Wrote coeff ROM to {mem_path}")


def apply_pwl_fixed(slopes_q, intercepts_q, x_q: np.ndarray):
    """RTL-equivalent: addr = x[15:10], y = (slope*x >> FRAC_BITS) + intercept."""
    x_i32 = x_q.astype(np.int32)
    addr = ((x_i32 >> 10) & 0x3F)

    slopes_sel = slopes_q[addr]
    intercepts_sel = intercepts_q[addr]

    prod = slopes_sel.astype(np.int32) * x_i32
    res = (prod >> FRAC_BITS) + intercepts_sel.astype(np.int32)

    res = np.clip(res, -32768, 32767).astype(np.int16)
    return res


def float_to_q312(x: np.ndarray) -> np.ndarray:
    q = np.round(x * SCALE).astype(np.int32)
    q = np.clip(q, -32768, 32767)
    return q.astype(np.int16)


def q312_to_float(q: np.ndarray) -> np.ndarray:
    return q.astype(np.int32) / float(SCALE)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--x_min", type=float, default=-4.0)
    parser.add_argument("--x_max", type=float, default=4.0)
    parser.add_argument("--n_seg", type=int, default=64)
    parser.add_argument(
        "--fit_mode",
        choices=["l2", "endpoint"],
        default="l2",
        help="l2: least-squares fit per segment, endpoint: line through segment endpoints",
    )
    parser.add_argument(
        "--coeff_out",
        type=str,
        default="RTL/code_unoptimize/silu_pwl_coeffs.mem",
    )
    parser.add_argument(
        "--golden_in_txt",
        type=str,
        default="",
        help="Optional: float input txt to generate golden fixed Q3.12 output",
    )
    parser.add_argument(
        "--golden_out_mem",
        type=str,
        default="ITMN/silu_golden/silu_siluunit_q312_golden.mem",
    )
    args = parser.parse_args()

    # 1) Generate SiLU PWL coeffs
    slopes_q, intercepts_q = generate_pwl_coeffs(
        silu_real,
        x_min=args.x_min,
        x_max=args.x_max,
        n_seg=args.n_seg,
        fit_mode=args.fit_mode,
    )
    write_mem_file(slopes_q, intercepts_q, args.coeff_out)

    # 2) Check error on dense grid
    xs = np.linspace(args.x_min, args.x_max, 20001)
    xs_q = float_to_q312(xs)
    ys_true = silu_real(xs)
    ys_q = apply_pwl_fixed(slopes_q, intercepts_q, xs_q)
    ys_pwl = q312_to_float(ys_q)

    abs_err = np.abs(ys_pwl - ys_true)
    with np.errstate(divide="ignore", invalid="ignore"):
        rel_err = np.where(np.abs(ys_true) > 1e-6, abs_err / np.abs(ys_true), np.nan)
    finite_rel = rel_err[np.isfinite(rel_err)]

    print(f"[CHECK] abs_err mean={abs_err.mean():.6f}, max={abs_err.max():.6f}")
    if finite_rel.size:
        print(f"[CHECK] rel_err mean={finite_rel.mean():.4f}, max={finite_rel.max():.4f}")

    # 3) Optional: golden fixed-point for RTL test
    if args.golden_in_txt:
        x_float = np.loadtxt(args.golden_in_txt, dtype=np.float64).reshape(-1)
        x_q = float_to_q312(x_float)
        y_q = apply_pwl_fixed(slopes_q, intercepts_q, x_q)

        out_path = Path(args.golden_out_mem)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        with out_path.open("w") as f:
            for v in y_q:
                u16 = np.uint16(v)
                f.write(f"{u16:04x}\n")

        print(f"[INFO] Wrote golden fixed-point to {out_path}")
        y_true = silu_real(x_float)
        y_pwl = q312_to_float(y_q)
        print("[SAMPLE] x, y_true, y_pwl:")
        for i in range(min(5, x_float.shape[0])):
            print(f"  {x_float[i]:+.5f}  {y_true[i]:+.5f}  {y_pwl[i]:+.5f}")


if __name__ == "__main__":
    main()
