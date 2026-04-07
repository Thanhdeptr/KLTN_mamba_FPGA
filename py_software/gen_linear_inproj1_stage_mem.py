#!/usr/bin/env python3
"""
Generate fixed-point RTL test vectors for Linear_Layer (in_proj1).

Stage: in_proj1 = x_norm (len=64) dot W_inproj1 (128x64), output channels 0..15 for chunk_out=0.

Produces:
  RTL/code_unoptimize/init/stage_linear/inproj1_chunk0_x.mem         (64 lines, 16-bit signed hex)
  RTL/code_unoptimize/init/stage_linear/inproj1_chunk0_W.mem         (64 lines, 256-bit hex)
  RTL/code_unoptimize/init/stage_linear/inproj1_chunk0_bias.mem      (1 line, 256-bit hex, all zeros)
  RTL/code_unoptimize/init/stage_linear/inproj1_chunk0_expected.mem  (1 line, 256-bit hex)
"""

from __future__ import annotations

from pathlib import Path
import numpy as np

FRAC_BITS = 12
SCALE = 1 << FRAC_BITS


def quant_q312_to_int16(x: np.ndarray) -> np.ndarray:
    q = np.round(x.astype(np.float64) * SCALE).astype(np.int64)
    q = np.clip(q, -32768, 32767).astype(np.int16)
    return q


def pack_lanes_16_i16(lanes: np.ndarray) -> int:
    """
    lanes: shape (16,), signed int16.
    Pack into 256-bit word: lane0 in bits[15:0], lane1 in bits[31:16], ...
    """
    assert lanes.shape == (16,)
    word = 0
    for i in range(16):
        u16 = np.uint16(lanes[i]).item()
        word |= int(u16) << (16 * i)
    return word


def sat_i16(x: int) -> int:
    if x > 32767:
        return 32767
    if x < -32768:
        return -32768
    return x


def main():
    root = Path(__file__).resolve().parents[1]  # KLTN/
    golden_dir = root / "ITMN" / "golden_vectors"
    out_dir = root / "RTL" / "code_unoptimize" / "init" / "stage_linear"
    out_dir.mkdir(parents=True, exist_ok=True)

    # Load float32 arrays
    golden_input = np.fromfile(golden_dir / "golden_input.bin", dtype=np.float32)
    in_proj1_weight = np.fromfile(golden_dir / "in_proj1_weight.bin", dtype=np.float32)

    SEQ_LEN = 1000
    D_MODEL = 64
    D_INNER = 128
    len_in = D_MODEL  # 64

    # Shapes
    x = golden_input.reshape(SEQ_LEN, D_MODEL)  # (1000, 64)
    W1 = in_proj1_weight.reshape(D_INNER, D_MODEL)  # (128, 64)

    token_idx = 0
    chunk_out = 0  # output channels 0..15

    # Quantize to Q3.12 int16
    x_q = quant_q312_to_int16(x[token_idx])  # (64,)
    W1_q = quant_q312_to_int16(W1)  # (128,64)

    lanes_out = W1_q[chunk_out * 16 : (chunk_out + 1) * 16, :]  # (16,64)

    # Generate x mem (16-bit signed words)
    x_mem_path = out_dir / "inproj1_chunk0_x.mem"
    with x_mem_path.open("w") as f:
        for i in range(len_in):
            u16 = np.uint16(x_q[i]).item()
            f.write(f"{u16:04x}\n")

    # Generate W mem: per cycle i, pack 16 lane weights into 256-bit word
    W_mem_path = out_dir / "inproj1_chunk0_W.mem"
    W_words: list[int] = []
    for i in range(len_in):
        lanes = lanes_out[:, i]  # (16,)
        W_words.append(pack_lanes_16_i16(lanes))
    with W_mem_path.open("w") as f:
        for w in W_words:
            f.write(f"{w:064x}\n")

    # Bias is all zero for in_proj stage in this RTL flow.
    bias_word = 0
    bias_mem_path = out_dir / "inproj1_chunk0_bias.mem"
    bias_mem_path.write_text(f"{bias_word:064x}\n", encoding="utf8")

    # Expected output from PE accumulation with saturation each step
    expected_lanes = np.zeros(16, dtype=np.int16)
    for lane in range(16):
        acc = 0
        for i in range(len_in):
            mult = int(x_q[i]) * int(lanes_out[lane, i])  # int32-ish
            mult_shifted = mult >> FRAC_BITS  # arithmetic shift
            temp = acc + mult_shifted
            acc = sat_i16(temp)
        expected_lanes[lane] = np.int16(acc)

    expected_word = pack_lanes_16_i16(expected_lanes)
    expected_path = out_dir / "inproj1_chunk0_expected.mem"
    expected_path.write_text(f"{expected_word:064x}\n", encoding="utf8")

    print("[OK] Generated stage_linear/inproj1_chunk0_*")


if __name__ == "__main__":
    main()

