#!/usr/bin/env python3

import argparse
from pathlib import Path

import numpy as np

FRAC_BITS = 12
QMIN = -32768
QMAX = 32767


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


def load_golden_tokens(path: Path, tokens: int, channels: int, seq_len: int = 1000) -> np.ndarray:
    raw = load_mem_i16(path)
    need = channels * seq_len
    if raw.size < need:
        raise ValueError(f"{path} too small: got {raw.size}, need >= {need}")
    ct = raw[:need].reshape(channels, seq_len)
    return ct[:, :tokens].T.copy().astype(np.int32)


def load_rtl_tokens(path: Path, tokens: int, channels: int) -> np.ndarray:
    raw = load_mem_i16(path)
    need = tokens * channels
    if raw.size < need:
        raise ValueError(f"{path} too small: got {raw.size}, need >= {need}")
    return raw[:need].reshape(tokens, channels)


def load_token_major_tokens(path: Path, tokens: int, channels: int) -> np.ndarray:
    return load_rtl_tokens(path, tokens, channels)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--rtl-file", type=Path, default=Path("rtl_output.mem"))
    ap.add_argument("--golden-file", type=Path, required=True)
    ap.add_argument("--tokens", type=int, default=10)
    ap.add_argument("--channels", type=int, required=True)
    ap.add_argument("--golden-layout", choices=["ct", "tokens"], default="ct")
    ap.add_argument("--abs-threshold", type=int, default=0)
    args = ap.parse_args()

    rtl = load_rtl_tokens(args.rtl_file, args.tokens, args.channels)
    if args.golden_layout == "ct":
        ref = load_golden_tokens(args.golden_file, args.tokens, args.channels)
    else:
        ref = load_token_major_tokens(args.golden_file, args.tokens, args.channels)

    err = np.abs(ref.astype(np.int32) - rtl.astype(np.int32))
    bad_mask = err > args.abs_threshold
    print(f"[RESULTS] {args.golden_file.name} vs RTL")
    print(f"  Tokens: {args.tokens}")
    print(f"  Channels: {args.channels}")
    print(f"  MAE: {float(err.mean()):.6f}")
    print(f"  Max error: {int(err.max())}")
    print(f"  Bad count: {int(bad_mask.sum())}")
    print(f"  Bad ratio: {float(bad_mask.mean())*100:.2f}%")

    if bad_mask.any():
        idx = np.argwhere(bad_mask)
        print("[DEBUG] First 10 mismatches [token, channel, golden, rtl, abs_err]:")
        for p in idx[:10]:
            t, c = int(p[0]), int(p[1])
            print(f"  {t:02d}, {c:02d}: {int(ref[t, c])}, {int(rtl[t, c])}, {int(err[t, c])}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())