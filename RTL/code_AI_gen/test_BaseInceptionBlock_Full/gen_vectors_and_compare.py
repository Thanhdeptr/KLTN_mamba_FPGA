#!/usr/bin/env python3
"""
Compare RTL output against PyTorch-derived golden output (Q3.12 mem).

Default mode is strict PyTorch signoff:
- Load rtl_output.mem
- Load weights_and_io/inception_golden_output_q312.mem
- Compare first N tokens (default 10)
- PASS if bad-ratio <= 5%

Optional debug mode:
- --mode rtl-ref : compare against RTL-like reference model
"""

import argparse
import sys
from pathlib import Path
import numpy as np

FRAC_BITS = 12
D_MODEL = 64
DIM = 16
TOKENS_DEFAULT = 10
BAD_RATIO_THRESH = 0.05
QMIN = -32768
QMAX = 32767
SEQ_LEN_MEM = 1000


def load_mem_i16(path: Path) -> np.ndarray:
    vals = []
    with open(path, "r") as f:
        for line in f:
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            v = int(s, 16)
            if v & 0x8000:
                v -= 0x10000
            vals.append(v)
    return np.array(vals, dtype=np.int32)


def load_ct_mem_as_tokens(path: Path, tokens: int, channels: int, seq_len: int = SEQ_LEN_MEM) -> np.ndarray:
    """Load mem flattened from tensor [C, T] and return [tokens, C]."""
    raw = load_mem_i16(path)
    need = channels * seq_len
    if raw.size < need:
        raise ValueError(f"{path} too small: got {raw.size}, need >= {need}")
    ct = raw[:need].reshape(channels, seq_len)
    return ct[:, :tokens].T.copy().astype(np.int32)


def clip_i16(x: np.ndarray) -> np.ndarray:
    return np.clip(x, QMIN, QMAX).astype(np.int32)


def qmul_vec_mat(x: np.ndarray, w: np.ndarray) -> np.ndarray:
    acc = w.astype(np.int64) @ x.astype(np.int64)
    return (acc >> FRAC_BITS).astype(np.int32)


def div_trunc_zero(num: np.ndarray, den: np.ndarray) -> np.ndarray:
    out = np.zeros_like(num, dtype=np.int64)
    nz = den != 0
    out[nz] = np.trunc(num[nz].astype(np.float64) / den[nz].astype(np.float64)).astype(np.int64)
    return out


def bn_relu_rtl_approx(x: np.ndarray, gamma: np.ndarray, beta: np.ndarray, mean: np.ndarray, var: np.ndarray) -> np.ndarray:
    diff = x.astype(np.int64) - mean.astype(np.int64)
    denom = var.astype(np.int64) + 1
    denom[denom == 0] = 1
    norm = div_trunc_zero(diff << FRAC_BITS, denom)
    y = ((norm * gamma.astype(np.int64)) >> FRAC_BITS) + beta.astype(np.int64)
    y = np.maximum(y, 0)
    return clip_i16(y)


def run_rtl_like_reference(input_tokens: np.ndarray, weights: dict) -> np.ndarray:
    x_hist1 = np.zeros((D_MODEL,), dtype=np.int32)
    x_hist2 = np.zeros((D_MODEL,), dtype=np.int32)
    b_hist = np.zeros((DIM, 38), dtype=np.int32)

    out_all = []

    w_bn = weights["weights_bn"].reshape(DIM, D_MODEL)
    w_c1 = weights["weights_c1"].reshape(DIM, D_MODEL)
    w_c9 = weights["weights_c9"].reshape(DIM, DIM, 9)
    w_c19 = weights["weights_c19"].reshape(DIM, DIM, 19)
    w_c39 = weights["weights_c39"].reshape(DIM, DIM, 39)

    bn_gamma = weights["bn_gamma"]
    bn_beta = weights["bn_beta"]
    bn_mean = weights["bn_mean"]
    bn_var = weights["bn_var"]

    for t in range(input_tokens.shape[0]):
        x_cur = input_tokens[t].astype(np.int32)
        pool_cur = np.maximum(np.maximum(x_cur, x_hist1), x_hist2)

        bottleneck = qmul_vec_mat(x_cur, w_bn)
        conv1 = qmul_vec_mat(pool_cur, w_c1)

        conv9 = np.zeros((DIM,), dtype=np.int64)
        conv19 = np.zeros((DIM,), dtype=np.int64)
        conv39 = np.zeros((DIM,), dtype=np.int64)

        for oc in range(DIM):
            a9 = 0
            a19 = 0
            a39 = 0
            for ic in range(DIM):
                a9 += int(bottleneck[ic]) * int(w_c9[oc, ic, 0])
                a19 += int(bottleneck[ic]) * int(w_c19[oc, ic, 0])
                a39 += int(bottleneck[ic]) * int(w_c39[oc, ic, 0])

                for k in range(1, 9):
                    a9 += int(b_hist[ic, k - 1]) * int(w_c9[oc, ic, k])
                for k in range(1, 19):
                    a19 += int(b_hist[ic, k - 1]) * int(w_c19[oc, ic, k])
                for k in range(1, 39):
                    a39 += int(b_hist[ic, k - 1]) * int(w_c39[oc, ic, k])

            conv9[oc] = a9 >> FRAC_BITS
            conv19[oc] = a19 >> FRAC_BITS
            conv39[oc] = a39 >> FRAC_BITS

        concat = np.concatenate([
            conv1.astype(np.int32),
            conv9.astype(np.int32),
            conv19.astype(np.int32),
            conv39.astype(np.int32),
        ])

        out_t = bn_relu_rtl_approx(concat, bn_gamma, bn_beta, bn_mean, bn_var)
        out_all.append(out_t)

        x_hist2 = x_hist1.copy()
        x_hist1 = x_cur.copy()
        b_hist[:, 1:] = b_hist[:, :-1]
        b_hist[:, 0] = bottleneck

    return np.stack(out_all, axis=0)


def compare_arrays(ref: np.ndarray, rtl: np.ndarray) -> dict:
    err = np.abs(ref.astype(np.int32) - rtl.astype(np.int32))
    return {
        "mae": float(err.mean()),
        "max": int(err.max()),
        "bad0": int((err > 0).sum()),
        "bad1": int((err > 1).sum()),
        "total": int(err.size),
        "bad_ratio": float((err > 0).mean()),
        "err": err,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["pytorch", "rtl-ref"], default="pytorch")
    ap.add_argument("--tokens", type=int, default=TOKENS_DEFAULT)
    ap.add_argument("--weights-dir", type=Path, default=Path("weights_and_io"), help="Directory containing golden mems")
    ap.add_argument("--golden-file", type=Path, default=Path("inception_golden_output_q312.mem"), help="Golden mem to compare against")
    ap.add_argument("--rtl-file", type=Path, default=Path("rtl_output.mem"), help="RTL output mem to compare")
    ap.add_argument("--abs-threshold", type=int, default=0,
                    help="Count mismatch only when abs_err > threshold (default: 0, strict)")
    args = ap.parse_args()

    wdir = args.weights_dir
    rtl_path = args.rtl_file
    if not rtl_path.exists():
        print("[ERROR] rtl_output.mem not found. Run simulation first.")
        return 1

    rtl = load_mem_i16(rtl_path)
    need = args.tokens * D_MODEL
    if rtl.size < need:
        print(f"[ERROR] RTL output too small: {rtl.size}, need {need}")
        return 1
    rtl = rtl[:need].reshape(args.tokens, D_MODEL)

    if args.mode == "pytorch":
        py_path = wdir / args.golden_file
        if not py_path.exists():
            print(f"[ERROR] Missing PyTorch golden mem: {py_path}")
            return 1

        try:
            ref = load_ct_mem_as_tokens(py_path, args.tokens, D_MODEL)
        except Exception as e:
            print(f"[ERROR] {e}")
            return 1

        m = compare_arrays(ref, rtl)
        bad_mask = m["err"] > args.abs_threshold
        bad_count = int(bad_mask.sum())
        bad_ratio = float(bad_mask.mean())
        print("[RESULTS] RTL vs PyTorch golden (Q3.12):")
        print(f"  Tokens:      {args.tokens}")
        print(f"  Total elems: {m['total']}")
        print(f"  MAE:         {m['mae']:.6f}")
        print(f"  Max error:   {m['max']}")
        print(f"  Abs-thresh:  {args.abs_threshold}")
        print(f"  Bad count:   {bad_count}")
        print(f"  Bad ratio:   {bad_ratio*100:.2f}%")

        if bad_ratio <= BAD_RATIO_THRESH:
            print(f"[PASS] PyTorch signoff passed (bad ratio <= {BAD_RATIO_THRESH*100:.1f}%)")
            return 0

        idx = np.argwhere(m["err"] > args.abs_threshold)
        print("[DEBUG] First 10 mismatches [token, channel, pytorch, rtl, abs_err]:")
        for p in idx[:10]:
            t, c = int(p[0]), int(p[1])
            print(f"  {t:02d}, {c:02d}: {int(ref[t,c])}, {int(rtl[t,c])}, {int(m['err'][t,c])}")
        print(f"[FAIL] PyTorch signoff failed (bad ratio > {BAD_RATIO_THRESH*100:.1f}%)")
        return 1

    # Optional internal debug mode
    req = {
        "weights_bn": 16 * 64,
        "weights_c1": 16 * 64,
        "weights_c9": 16 * 16 * 9,
        "weights_c19": 16 * 16 * 19,
        "weights_c39": 16 * 16 * 39,
        "bn_gamma": 64,
        "bn_beta": 64,
        "bn_mean": 64,
        "bn_var": 64,
    }
    weights = {
        "weights_bn": load_mem_i16(wdir / "inception_bottleneck_weight_q312.mem"),
        "weights_c1": load_mem_i16(wdir / "inception_conv1_k1_weight_q312.mem"),
        "weights_c9": load_mem_i16(wdir / "inception_conv2_k9_weight_q312.mem"),
        "weights_c19": load_mem_i16(wdir / "inception_conv3_k19_weight_q312.mem"),
        "weights_c39": load_mem_i16(wdir / "inception_conv4_k39_weight_q312.mem"),
        "bn_gamma": load_mem_i16(wdir / "inception_bn_weight_q312.mem"),
        "bn_beta": load_mem_i16(wdir / "inception_bn_bias_q312.mem"),
        "bn_mean": load_mem_i16(wdir / "inception_bn_running_mean_q312.mem"),
        "bn_var": load_mem_i16(wdir / "inception_bn_running_var_q312.mem"),
    }
    for k, n in req.items():
        if weights[k].size != n:
            print(f"[ERROR] {k} size mismatch: got {weights[k].size}, expected {n}")
            return 1

    try:
        inp = load_ct_mem_as_tokens(wdir / "inception_golden_input_q312.mem", args.tokens, D_MODEL)
    except Exception as e:
        print(f"[ERROR] {e}")
        return 1

    ref = run_rtl_like_reference(inp, weights)
    m = compare_arrays(ref, rtl)
    print("[RESULTS] RTL vs RTL-like reference (debug only):")
    print(f"  MAE: {m['mae']:.6f}, Max: {m['max']}, Bad ratio: {m['bad_ratio']*100:.2f}%")
    return 0


if __name__ == "__main__":
    sys.exit(main())
