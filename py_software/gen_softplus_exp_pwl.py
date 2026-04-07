"""
Generate PWL coefficients for Softplus and Exp units (RTL code_unoptimize).
Output: softplus_pwl_coeffs.mem, exp_pwl_coeffs.mem
Segment addressing matches RTL: addr = in_data[15:10] (6 MSB of Q3.12).

Exp: fit to clamped target; tune; cap overshoot. Knee (addr 8, x in [2, 2.25])
is split into 4 sub-segments (68-entry ROM) so RTL uses in_data[9:8] when
addr==8 to reduce error in the high-slope + saturation region (see adaptive
PWL / non-uniform segmentation in literature).
Run from project root: python3 py_software/gen_softplus_exp_pwl.py
"""

import numpy as np
from pathlib import Path

FRAC_BITS = 12
SCALE = 1 << FRAC_BITS  # 4096
N_SEG = 64
SEG_SIZE = 1024  # 2^10 values per addr


def softplus_real(x: np.ndarray) -> np.ndarray:
    """softplus(x) = log(1 + exp(x)). Stable for large |x|."""
    return np.log1p(np.exp(-np.abs(x))) + np.maximum(x, 0)


def exp_real(x: np.ndarray) -> np.ndarray:
    """exp(x). For PWL we approximate; RTL saturates to 0..32767 (Q3.12)."""
    return np.exp(x)


# Max representable value in Q3.12 (RTL saturates to this)
EXP_MAX_FLOAT = 32767.0 / SCALE


def exp_real_clamped(x: np.ndarray) -> np.ndarray:
    """
    exp(x) clamped to [0, 32767/4096]. Fit PWL to this so that in the
    saturation region the segment is already flat -> less error after RTL clamp.
    """
    return np.minimum(np.exp(x), EXP_MAX_FLOAT)


def _segment_bounds(addr, n_seg=64):
    """Return (in_left, in_right) Q3.12 and (xl, xr) float for segment."""
    if addr < 32:
        in_left = addr * SEG_SIZE
        in_right = (addr + 1) * SEG_SIZE
    else:
        in_left = -32768 + (addr - 32) * SEG_SIZE
        in_right = -32768 + (addr - 32 + 1) * SEG_SIZE
    xl = in_left / float(SCALE)
    xr = in_right / float(SCALE)
    return in_left, in_right, xl, xr


def generate_pwl_coeffs(func, n_seg=64, use_midpoint_lsq=False):
    """
    Fit PWL y = a*x + b per segment; return slopes_q, intercepts_q (Q3.12).
    Segment boundaries match RTL: addr = in_data[15:10].
    If use_midpoint_lsq: fit (a,b) by least-squares on (xl, xm, xr) to reduce error.
    """
    slopes = []
    intercepts = []

    for addr in range(n_seg):
        _, _, xl, xr = _segment_bounds(addr, n_seg)
        xm = 0.5 * (xl + xr)
        yl = func(np.array([xl], dtype=np.float64))[0]
        yr = func(np.array([xr], dtype=np.float64))[0]
        ym = func(np.array([xm], dtype=np.float64))[0]

        if use_midpoint_lsq:
            # Least-squares line through (xl,yl), (xm,ym), (xr,yr)
            A = np.array([[xl, 1], [xm, 1], [xr, 1]], dtype=np.float64)
            y = np.array([yl, ym, yr], dtype=np.float64)
            ab, _, _, _ = np.linalg.lstsq(A, y, rcond=None)
            a, b = float(ab[0]), float(ab[1])
        else:
            denom = xr - xl
            if abs(denom) < 1e-12:
                a, b = 0.0, yl
            else:
                a = (yr - yl) / denom
                b = yl - a * xl

        slopes.append(a)
        intercepts.append(b)

    slopes = np.array(slopes, dtype=np.float64)
    intercepts = np.array(intercepts, dtype=np.float64)

    slopes_q = np.round(slopes * SCALE).astype(np.int32)
    intercepts_q = np.round(intercepts * SCALE).astype(np.int32)

    slopes_q = np.clip(slopes_q, -32768, 32767)
    intercepts_q = np.clip(intercepts_q, -32768, 32767)

    return slopes_q, intercepts_q


def _exp_segment_max_error(slope_q, intercept_q, addr, n_pts=32):
    """Max absolute error in segment for given slope_q, intercept_q."""
    _, _, xl, xr = _segment_bounds(addr, 64)
    xs = np.linspace(xl, xr, n_pts)
    ys_true = exp_real_clamped(xs)
    x_q = float_to_q312(xs)
    prod = slope_q * x_q.astype(np.int32)
    res = (prod >> FRAC_BITS) + intercept_q
    res = np.clip(res, 0, 32767)  # RTL clamps to [0, 32767]
    ys_pwl = res.astype(np.int32) / float(SCALE)
    return np.max(np.abs(ys_pwl - ys_true))


def tune_exp_intercepts_per_segment(slopes_q, intercepts_q, n_seg=64, delta_b=16, delta_a=3):
    """
    For each segment, try (slope_q + da, intercept_q + db) in a small range and
    pick the pair that minimizes max error in the segment (RTL-style clamp 0..32767).
    """
    MAX_OUT = 32767
    slopes_out = np.array(slopes_q, dtype=np.int32)
    intercepts_out = np.array(intercepts_q, dtype=np.int32)
    for addr in range(n_seg):
        best_a, best_b = slopes_q[addr], intercepts_q[addr]
        best_err = _exp_segment_max_error(best_a, best_b, addr)
        for da in range(-delta_a, delta_a + 1):
            a = np.clip(slopes_q[addr] + da, -32768, MAX_OUT)
            for db in range(-delta_b, delta_b + 1):
                b = np.clip(intercepts_q[addr] + db, -32768, MAX_OUT)
                err = _exp_segment_max_error(a, b, addr)
                if err < best_err:
                    best_err = err
                    best_a, best_b = a, b
        slopes_out[addr] = best_a
        intercepts_out[addr] = best_b
    return slopes_out, intercepts_out


def clamp_exp_intercepts_to_saturate(slopes_q, intercepts_q, n_seg=64):
    """
    For exp: in segments fully inside the saturated zone (x >= ln(MAX)), cap
    intercept so that res <= 32767 at the right endpoint. Skip segments that
    span the knee so the fit stays accurate there and RTL clamps only when needed.
    """
    MAX_OUT = 32767
    # Float x at which exp(x) reaches saturation (Q3.12 max)
    x_sat = np.log(EXP_MAX_FLOAT)
    intercepts_out = np.array(intercepts_q, dtype=np.int32)
    for addr in range(n_seg):
        if addr >= 32:
            continue  # negative-x segments: no saturation
        # Right endpoint of segment (max x in segment, in float)
        in_right = (addr + 1) * SEG_SIZE - 1
        xr_float = in_right / float(SCALE)
        if xr_float < x_sat:
            continue  # segment spans knee or is below; do not cap
        prod = int(slopes_q[addr]) * in_right
        res_right = (prod >> FRAC_BITS) + int(intercepts_out[addr])
        if res_right > MAX_OUT:
            new_b = MAX_OUT - (prod >> FRAC_BITS)
            intercepts_out[addr] = int(np.clip(new_b, -32768, 32767))
    return slopes_q, intercepts_out


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

    print(f"[INFO] Wrote {mem_path}")


# Knee segment (addr 8): x in [2.0, 2.25]. Split into 4 sub-segments for accuracy.
KNEE_ADDR = 8
KNEE_SUB_BITS = 2  # in_data[9:8] -> 4 sub-segments
KNEE_N_SUB = 4


def _knee_sub_bounds(i):
    """Float bounds for knee sub-segment i (segment 8: x in [2.0, 2.25])."""
    x_left, x_right = 2.0, 2.25
    xl = x_left + (x_right - x_left) * i / KNEE_N_SUB
    xr = x_left + (x_right - x_left) * (i + 1) / KNEE_N_SUB
    return xl, xr


def _knee_sub_max_error(slope_q, intercept_q, sub_idx, n_pts=32):
    """Max absolute error in knee sub-segment sub_idx (RTL clamp 0..32767)."""
    xl, xr = _knee_sub_bounds(sub_idx)
    xs = np.linspace(xl, xr, n_pts)
    ys_true = exp_real_clamped(xs)
    x_q = float_to_q312(xs)
    prod = slope_q * x_q.astype(np.int32)
    res = (prod >> FRAC_BITS) + intercept_q
    res = np.clip(res, 0, 32767)
    ys_pwl = res.astype(np.int32) / float(SCALE)
    return np.max(np.abs(ys_pwl - ys_true))


def generate_knee_sub_coeffs():
    """Generate KNEE_N_SUB sub-segments for segment 8 (x in [2.0, 2.25]). Return (slopes_q, intercepts_q)."""
    x_left = 2.0
    x_right = 2.25
    slopes_q = []
    intercepts_q = []
    for i in range(KNEE_N_SUB):
        xl = x_left + (x_right - x_left) * i / KNEE_N_SUB
        xr = x_left + (x_right - x_left) * (i + 1) / KNEE_N_SUB
        yl = exp_real_clamped(np.array([xl]))[0]
        yr = exp_real_clamped(np.array([xr]))[0]
        denom = xr - xl
        if abs(denom) < 1e-12:
            a, b = 0.0, yl
        else:
            a = (yr - yl) / denom
            b = yl - a * xl
        a_q = int(np.clip(round(a * SCALE), -32768, 32767))
        b_q = int(np.clip(round(b * SCALE), -32768, 32767))
        # Cap so no overshoot at xr
        in_right_q = int(round(xr * SCALE))
        res_r = (a_q * in_right_q >> FRAC_BITS) + b_q
        if res_r > 32767:
            b_q = 32767 - (a_q * in_right_q >> FRAC_BITS)
            b_q = np.clip(b_q, -32768, 32767)
        slopes_q.append(a_q)
        intercepts_q.append(b_q)

    # Tune each knee sub in small (da, db) to reduce max error (fixes 8-sub worse than 4-sub due to quantization)
    delta_a, delta_b = 2, 4
    for i in range(KNEE_N_SUB):
        best_a, best_b = slopes_q[i], intercepts_q[i]
        best_err = _knee_sub_max_error(best_a, best_b, i)
        for da in range(-delta_a, delta_a + 1):
            for db in range(-delta_b, delta_b + 1):
                a = np.clip(slopes_q[i] + da, -32768, 32767)
                b = np.clip(intercepts_q[i] + db, -32768, 32767)
                in_r = int(round(_knee_sub_bounds(i)[1] * SCALE))
                if (a * in_r >> FRAC_BITS) + b > 32767:
                    continue  # skip overshoot
                err = _knee_sub_max_error(a, b, i)
                if err < best_err:
                    best_err = err
                    best_a, best_b = a, b
        slopes_q[i] = best_a
        intercepts_q[i] = best_b

    return slopes_q, intercepts_q


def write_exp_mem_with_knee(slopes_64, intercepts_64, knee_slopes, knee_intercepts, mem_path: str):
    """
    Write 64+KNEE_N_SUB lines: ROM[0..63] = 64 segments, ROM[64..64+KNEE_N_SUB-1] = knee sub-segments.
    RTL: when addr==8 use ROM[64+in_data[9:7]] (8 sub) or in_data[9:8] (4 sub).
    """
    mem_path = Path(mem_path)
    mem_path.parent.mkdir(parents=True, exist_ok=True)
    with mem_path.open("w") as f:
        for addr in range(64):
            a_q = slopes_64[addr]
            b_q = intercepts_64[addr]
            if addr == KNEE_ADDR:
                a_q, b_q = knee_slopes[0], knee_intercepts[0]  # first sub as fallback
            a16 = np.uint16(np.int16(a_q))
            b16 = np.uint16(np.int16(b_q))
            f.write(f"{(int(a16) << 16) | int(b16):08x}\n")
        for a_q, b_q in zip(knee_slopes, knee_intercepts):
            a16 = np.uint16(np.int16(a_q))
            b16 = np.uint16(np.int16(b_q))
            f.write(f"{(int(a16) << 16) | int(b16):08x}\n")
    print(f"[INFO] Wrote {64 + KNEE_N_SUB}-line exp coeff (knee={KNEE_N_SUB} sub) to {mem_path}")


def apply_pwl_fixed(slopes_q, intercepts_q, x_q: np.ndarray):
    """RTL-equivalent: addr = x[15:10], y = (slope*x >> FRAC_BITS) + intercept."""
    x_i32 = x_q.astype(np.int32)
    addr = (x_i32 >> 10) & 0x3F

    slopes_sel = slopes_q[addr]
    intercepts_sel = intercepts_q[addr]

    prod = slopes_sel.astype(np.int32) * x_i32
    res = (prod >> FRAC_BITS) + intercepts_sel.astype(np.int32)

    res = np.clip(res, -32768, 32767).astype(np.int16)
    return res


def apply_pwl_fixed_with_knee(slopes_64, intercepts_64, knee_slopes, knee_intercepts, x_q: np.ndarray):
    """RTL-equivalent: addr 8 -> ROM[64+in_data[9:7]] for KNEE_N_SUB=8."""
    x_i32 = x_q.astype(np.int32)
    addr = (x_i32 >> 10) & 0x3F
    sub = (x_i32 >> 8) & ((1 << KNEE_SUB_BITS) - 1)  # in_data[9:8] for 4 sub

    slopes_sel = np.array(slopes_64[addr], dtype=np.int32)
    intercepts_sel = np.array(intercepts_64[addr], dtype=np.int32)
    knee_mask = addr == KNEE_ADDR
    slopes_sel[knee_mask] = np.array(knee_slopes, dtype=np.int32)[sub[knee_mask]]
    intercepts_sel[knee_mask] = np.array(knee_intercepts, dtype=np.int32)[sub[knee_mask]]

    prod = slopes_sel * x_i32
    res = (prod >> FRAC_BITS) + intercepts_sel
    res = np.clip(res, 0, 32767).astype(np.int32)  # exp RTL clamps to [0, 32767]
    return res.astype(np.int16)


def float_to_q312(x: np.ndarray) -> np.ndarray:
    q = np.round(x * SCALE).astype(np.int32)
    q = np.clip(q, -32768, 32767)
    return q.astype(np.int16)


def q312_to_float(q: np.ndarray) -> np.ndarray:
    return q.astype(np.int32) / float(SCALE)


def check_errors(name, func, slopes_q, intercepts_q, x_min=-8.0, x_max=8.0, n_pts=20001, clip_exp=True):
    """Report PWL vs true function error on a dense grid."""
    xs = np.linspace(x_min, x_max, n_pts)
    xs_q = float_to_q312(xs)
    ys_true = func(xs)
    ys_q = apply_pwl_fixed(slopes_q, intercepts_q, xs_q)
    ys_pwl = q312_to_float(ys_q)

    # Exp RTL clamps output to [0, 32767]; mirror for fair comparison
    if name == "exp" and clip_exp:
        max_q312 = 32767 / SCALE
        ys_pwl = np.clip(ys_pwl, 0.0, max_q312)
        ys_true = np.minimum(ys_true, max_q312)

    abs_err = np.abs(ys_pwl - ys_true)
    print(f"[{name}] abs_err mean={abs_err.mean():.6f}, max={abs_err.max():.6f}")
    if name == "exp" and clip_exp:
        sat_mask = xs >= 2.0
        unsat_mask = ~sat_mask
        if np.any(sat_mask):
            print(f"        (x>=2 saturate) mean={abs_err[sat_mask].mean():.6f}, max={abs_err[sat_mask].max():.6f}")
        if np.any(unsat_mask):
            print(f"        (x<2 unsat)     mean={abs_err[unsat_mask].mean():.6f}, max={abs_err[unsat_mask].max():.6f}")


def check_errors_exp_with_knee(slopes_64, intercepts_64, knee_slopes, knee_intercepts, n_pts=20001):
    """Report exp PWL error when using 68-entry ROM (knee sub-segments)."""
    xs = np.linspace(-8.0, 8.0, n_pts)
    xs_q = float_to_q312(xs)
    ys_true = np.minimum(exp_real_clamped(xs), 32767 / SCALE)
    ys_q = apply_pwl_fixed_with_knee(slopes_64, intercepts_64, knee_slopes, knee_intercepts, xs_q)
    ys_pwl = np.clip(ys_q.astype(np.int32) / float(SCALE), 0.0, 32767 / SCALE)
    abs_err = np.abs(ys_pwl - ys_true)
    print(f"[exp+knee] abs_err mean={abs_err.mean():.6f}, max={abs_err.max():.6f}")
    sat_mask = xs >= 2.0
    unsat_mask = ~sat_mask
    if np.any(sat_mask):
        print(f"          (x>=2 saturate) mean={abs_err[sat_mask].mean():.6f}, max={abs_err[sat_mask].max():.6f}")
    if np.any(unsat_mask):
        print(f"          (x<2 unsat)     mean={abs_err[unsat_mask].mean():.6f}, max={abs_err[unsat_mask].max():.6f}")


def main():
    rtl_dir = Path("RTL/code_unoptimize")
    rtl_dir.mkdir(parents=True, exist_ok=True)

    # ---- Softplus ----
    slopes_sp, intercepts_sp = generate_pwl_coeffs(softplus_real, n_seg=N_SEG)
    write_mem_file(slopes_sp, intercepts_sp, str(rtl_dir / "softplus_pwl_coeffs.mem"))
    check_errors("softplus", softplus_real, slopes_sp, intercepts_sp)

    # ---- Exp: 64 segments + 4 sub-segments for knee (addr 8, x in [2, 2.25]) ----
    slopes_exp, intercepts_exp = generate_pwl_coeffs(
        exp_real_clamped, n_seg=N_SEG, use_midpoint_lsq=True
    )
    slopes_exp, intercepts_exp = tune_exp_intercepts_per_segment(
        slopes_exp, intercepts_exp, n_seg=N_SEG, delta_b=16, delta_a=3
    )
    slopes_exp, intercepts_exp = clamp_exp_intercepts_to_saturate(slopes_exp, intercepts_exp, n_seg=N_SEG)
    knee_slopes, knee_intercepts = generate_knee_sub_coeffs()
    write_exp_mem_with_knee(
        slopes_exp, intercepts_exp, knee_slopes, knee_intercepts,
        str(rtl_dir / "exp_pwl_coeffs.mem"),
    )
    # Check with knee sub-segments (68-entry ROM)
    check_errors_exp_with_knee(slopes_exp, intercepts_exp, knee_slopes, knee_intercepts)


if __name__ == "__main__":
    main()
