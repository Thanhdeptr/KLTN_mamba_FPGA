#!/usr/bin/env python3

import argparse
from pathlib import Path

import numpy as np


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


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--rtl-file", type=Path, default=Path("rtl_output.mem"))
    ap.add_argument(
        "--golden-file",
        type=Path,
        default=Path("../../../ITMN/golden_vectors/rtl_mem/inception_stage/tensors/12_relu_out_q312.mem"),
    )
    ap.add_argument("--tokens", type=int, default=10)
    ap.add_argument("--channels", type=int, default=64)
    ap.add_argument("--seq-len", type=int, default=1000)
    ap.add_argument("--rtl-scale", type=float, default=1.0)
    ap.add_argument("--rtl-bias", type=float, default=0.0)
    ap.add_argument("--relu-golden", action="store_true")
    ap.add_argument("--corr-threshold", type=float, default=0.99)
    ap.add_argument("--enforce-corr", action="store_true")
    args = ap.parse_args()

    rtl_raw = load_mem_i16(args.rtl_file)
    rtl_need = args.tokens * args.channels
    if rtl_raw.size < rtl_need:
        raise ValueError(f"RTL output too small: got {rtl_raw.size}, need >= {rtl_need}")
    rtl = rtl_raw[:rtl_need].reshape(args.tokens, args.channels).astype(np.float64)
    if args.rtl_scale != 1.0 or args.rtl_bias != 0.0:
        rtl = rtl * args.rtl_scale + args.rtl_bias

    py_raw = load_mem_i16(args.golden_file)
    py_need = args.channels * args.seq_len
    if py_raw.size < py_need:
        raise ValueError(f"Golden output too small: got {py_raw.size}, need >= {py_need}")
    py = py_raw[:py_need].reshape(args.channels, args.seq_len)[:, :args.tokens].T.astype(np.float64)
    if args.relu_golden:
        py = np.maximum(py, 0.0)

    err = rtl - py
    mae = float(np.mean(np.abs(err)))
    mse = float(np.mean(err ** 2))
    rmse = float(np.sqrt(mse))

    x = rtl.reshape(-1)
    y = py.reshape(-1)
    if np.std(x) == 0.0 or np.std(y) == 0.0:
        pearson = float("nan")
    else:
        pearson = float(np.corrcoef(x, y)[0, 1])

    nx = float(np.linalg.norm(x))
    ny = float(np.linalg.norm(y))
    if nx == 0.0 or ny == 0.0:
        cosine = float("nan")
    else:
        cosine = float(np.dot(x, y) / (nx * ny))

    print("[FINAL QUALITY]")
    print(f"  Tokens: {args.tokens}")
    print(f"  Channels: {args.channels}")
    print(f"  RTL scale: {args.rtl_scale:.9f}")
    print(f"  RTL bias: {args.rtl_bias:.9f}")
    print(f"  ReLU golden: {args.relu_golden}")
    print(f"  MAE: {mae:.6f}")
    print(f"  MSE: {mse:.6f}")
    print(f"  RMSE: {rmse:.6f}")
    print(f"  Pearson: {pearson:.6f}")
    print(f"  Cosine: {cosine:.6f}")
    print(f"  Pearson threshold: {args.corr_threshold:.6f}")

    if np.isnan(pearson):
        print("[WARN] Pearson is NaN (one side has zero variance)")
        if args.enforce_corr:
            return 2
        return 0

    if pearson >= args.corr_threshold:
        print("[PASS] Correlation target met")
        return 0

    print("[FAIL] Correlation target not met")
    if args.enforce_corr:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())