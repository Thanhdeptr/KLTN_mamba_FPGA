#!/usr/bin/env python3
"""Fold Inception block BatchNorm into Conv weights and bias.

This script reads float32 .bin tensors exported from ITMN/golden_vectors,
computes the inference-time BN fold, and writes Q3.12 .mem files for RTL.

Output files are written under:
    RTL/code_AI_gen/test_BaseInceptionBlock_Full/weights_and_io_folded/
"""

from __future__ import annotations

from pathlib import Path

import numpy as np

FRAC_BITS = 12
SCALE = 1 << FRAC_BITS
EPS = 1e-5

ROOT = Path(__file__).resolve().parents[1]
GOLDEN_DIR = ROOT / "ITMN" / "golden_vectors"
OUT_DIR = ROOT / "RTL" / "code_AI_gen" / "test_BaseInceptionBlock_Full" / "weights_and_io_folded"


def load_f32(path: Path) -> np.ndarray:
    arr = np.fromfile(path, dtype=np.float32)
    if arr.size == 0:
        raise ValueError(f"{path} is empty or not a valid float32 bin")
    return arr.astype(np.float64)


def to_q312_mem(values: np.ndarray, out_path: Path) -> None:
    q = np.round(values * SCALE).astype(np.int64)
    q = np.clip(q, -32768, 32767).astype(np.int16)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w") as f:
        for v in q:
            f.write(f"{np.uint16(v):04x}\n")


def fold_branch_weights(weights: np.ndarray, scale: np.ndarray) -> np.ndarray:
    folded = np.empty_like(weights, dtype=np.float64)
    if weights.ndim == 2:
        for oc in range(weights.shape[0]):
            folded[oc, :] = weights[oc, :] * scale[oc]
    elif weights.ndim == 3:
        for oc in range(weights.shape[0]):
            folded[oc, :, :] = weights[oc, :, :] * scale[oc]
    else:
        raise ValueError(f"Unsupported weight rank: {weights.ndim}")
    return folded


def main() -> int:
    bn_weight = load_f32(GOLDEN_DIR / "inception_bn_weight.bin")
    bn_bias = load_f32(GOLDEN_DIR / "inception_bn_bias.bin")
    bn_mean = load_f32(GOLDEN_DIR / "inception_bn_running_mean.bin")
    bn_var = load_f32(GOLDEN_DIR / "inception_bn_running_var.bin")

    if not (bn_weight.size == bn_bias.size == bn_mean.size == bn_var.size == 64):
        raise ValueError("BN tensors must all have 64 channels")

    scale = bn_weight / np.sqrt(bn_var + EPS)
    fold_bias = bn_bias - scale * bn_mean

    spec = [
        ("inception_bottleneck_weight.bin", "inception_bottleneck_weight_folded_q312.mem", (16, 64), 0),
        ("inception_conv1_k1_weight.bin", "inception_conv1_k1_weight_folded_q312.mem", (16, 64), 0),
        ("inception_conv2_k9_weight.bin", "inception_conv2_k9_weight_folded_q312.mem", (16, 16, 9), 16),
        ("inception_conv3_k19_weight.bin", "inception_conv3_k19_weight_folded_q312.mem", (16, 16, 19), 32),
        ("inception_conv4_k39_weight.bin", "inception_conv4_k39_weight_folded_q312.mem", (16, 16, 39), 48),
    ]

    OUT_DIR.mkdir(parents=True, exist_ok=True)

    for src_name, dst_name, shape, offset in spec:
        raw = load_f32(GOLDEN_DIR / src_name)
        weights = raw.reshape(shape)
        folded = fold_branch_weights(weights, scale[offset:offset + shape[0]])
        to_q312_mem(folded.reshape(-1), OUT_DIR / dst_name)

    to_q312_mem(fold_bias, OUT_DIR / "inception_folded_bias_q312.mem")

    print(f"[INFO] Folded Inception BN exported to {OUT_DIR}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())