#!/usr/bin/env python3

import argparse
from pathlib import Path

import numpy as np

FRAC_BITS = 12
SEQ_LEN = 1000


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


def write_mem_i16(path: Path, arr: np.ndarray) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w") as f:
        for v in arr.astype(np.int32).reshape(-1):
            u = np.uint16(np.int16(v))
            f.write(f"{u:04x}\n")


def sat16(x: np.ndarray) -> np.ndarray:
    return np.clip(x, -32768, 32767).astype(np.int32)


def qshift_sat16_rn(x: np.ndarray) -> np.ndarray:
    x64 = x.astype(np.int64)
    out = np.empty_like(x64)
    pos = x64 >= 0
    out[pos] = (x64[pos] + (1 << (FRAC_BITS - 1))) >> FRAC_BITS
    out[~pos] = -(((-x64[~pos]) + (1 << (FRAC_BITS - 1))) >> FRAC_BITS)
    return sat16(out)


def load_ct_tokens(path: Path, channels: int, tokens: int) -> np.ndarray:
    raw = load_mem_i16(path)
    need = channels * SEQ_LEN
    if raw.size < need:
        raise ValueError(f"{path} too small: got {raw.size}, need >= {need}")
    ct = raw[:need].reshape(channels, SEQ_LEN)
    return ct[:, :tokens].T.copy().astype(np.int32)


def bottleneck_ref(inp_tokens: np.ndarray, w: np.ndarray) -> np.ndarray:
    out = []
    for t in range(inp_tokens.shape[0]):
        acc = w.astype(np.int64) @ inp_tokens[t].astype(np.int64)
        out.append(qshift_sat16_rn(acc))
    return np.stack(out, axis=0)


def conv1_ref(inp_ct: np.ndarray, tokens: int, w: np.ndarray) -> np.ndarray:
    def get_x(idx: int) -> np.ndarray:
        if idx < 0 or idx >= SEQ_LEN:
            return np.zeros((64,), dtype=np.int32)
        return inp_ct[:, idx]

    out = []
    for t in range(tokens):
        pool = np.maximum(np.maximum(get_x(t - 1), get_x(t)), get_x(t + 1))
        acc = w.astype(np.int64) @ pool.astype(np.int64)
        out.append(qshift_sat16_rn(acc))
    return np.stack(out, axis=0)


def convk_ref(bottleneck_ct: np.ndarray, tokens: int, w: np.ndarray, kernel: int, center: int) -> np.ndarray:
    def get_b(idx: int) -> np.ndarray:
        if idx < 0 or idx >= SEQ_LEN:
            return np.zeros((16,), dtype=np.int32)
        return bottleneck_ct[:, idx]

    out = []
    for t in range(tokens):
        y_t = np.zeros((16,), dtype=np.int32)
        for oc in range(16):
            acc = 0
            for ic in range(16):
                for k in range(kernel):
                    idx = t - (center - 19) + k
                    acc += int(get_b(idx)[ic]) * int(w[oc, ic, k])
            y_t[oc] = qshift_sat16_rn(np.array([acc], dtype=np.int64))[0]
        out.append(y_t)
    return np.stack(out, axis=0)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--stage", required=True, choices=["bottleneck", "conv1", "conv9", "conv19", "conv39"])
    ap.add_argument("--tokens", type=int, default=10)
    ap.add_argument("--out", type=Path, default=Path("rtl_like_ref.mem"))
    args = ap.parse_args()

    repo = Path(__file__).resolve().parents[3]
    stage_dir = repo / "ITMN" / "golden_vectors" / "rtl_mem" / "inception_stage" / "tensors"
    wdir = repo / "RTL" / "code_AI_gen" / "test_BaseInceptionBlock_Full" / "weights_and_io"

    if args.stage == "bottleneck":
        inp = load_ct_tokens(stage_dir / "04_inception_input_q312.mem", 64, args.tokens)
        w = load_mem_i16(wdir / "inception_bottleneck_weight_q312.mem").reshape(16, 64)
        ref = bottleneck_ref(inp, w)
    elif args.stage == "conv1":
        inp_raw = load_mem_i16(stage_dir / "04_inception_input_q312.mem")
        inp_ct = inp_raw[:64 * SEQ_LEN].reshape(64, SEQ_LEN)
        w = load_mem_i16(wdir / "inception_conv1_k1_weight_q312.mem").reshape(16, 64)
        ref = conv1_ref(inp_ct, args.tokens, w)
    elif args.stage == "conv9":
        inp_raw = load_mem_i16(stage_dir / "05_bottleneck_out_q312.mem")
        inp_ct = inp_raw[:16 * SEQ_LEN].reshape(16, SEQ_LEN)
        w = load_mem_i16(wdir / "inception_conv2_k9_weight_q312.mem").reshape(16, 16, 9)
        ref = convk_ref(inp_ct, args.tokens, w, kernel=9, center=23)
    elif args.stage == "conv19":
        inp_raw = load_mem_i16(stage_dir / "05_bottleneck_out_q312.mem")
        inp_ct = inp_raw[:16 * SEQ_LEN].reshape(16, SEQ_LEN)
        w = load_mem_i16(wdir / "inception_conv3_k19_weight_q312.mem").reshape(16, 16, 19)
        ref = convk_ref(inp_ct, args.tokens, w, kernel=19, center=28)
    else:
        inp_raw = load_mem_i16(stage_dir / "05_bottleneck_out_q312.mem")
        inp_ct = inp_raw[:16 * SEQ_LEN].reshape(16, SEQ_LEN)
        w = load_mem_i16(wdir / "inception_conv4_k39_weight_q312.mem").reshape(16, 16, 39)
        ref = convk_ref(inp_ct, args.tokens, w, kernel=39, center=38)

    write_mem_i16(args.out, ref)
    print(f"[INFO] Wrote RTL-like reference for stage '{args.stage}' to {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())