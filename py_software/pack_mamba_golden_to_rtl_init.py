#!/usr/bin/env python3
"""
Pack ITMN golden coeff (float32 .bin) -> RTL init images (256-bit Q3.12 words).

Mục tiêu: chuẩn bị dữ liệu để giả lập RTL "Mamba block" trong RTL/code_unoptimize.

Output:
  - RTL/code_unoptimize/init/coreA_init.mem
  - RTL/code_unoptimize/init/weight_init.mem
  - RTL/code_unoptimize/init/const_init.mem

Mỗi file:
  - 1 dòng = 1 word 256-bit (64 hex chars) ứng với 1 địa chỉ BRAM.

Lưu ý:
  - Thiết kế/controller trong Global_Controller_Full_Flow.v dùng fixed memory map.
  - Script này pack theo các giả định phù hợp với cách Linear/Scan/Conv unpack lane
    (lane0 nằm ở bit[15:0], lane1 ở bit[31:16], ...).
"""

from __future__ import annotations

import os
from pathlib import Path
import numpy as np


# Q3.12
FRAC_BITS = 12
SCALE = 1 << FRAC_BITS


def quant_q312(x: np.ndarray) -> np.ndarray:
    """float32 -> int16 Q3.12 (clamp to int16 range)."""
    q = np.round(x.astype(np.float64) * SCALE).astype(np.int64)
    q = np.clip(q, -32768, 32767).astype(np.int16)
    return q


def pack_lanes_q312(lanes: np.ndarray) -> int:
    """
    lanes: shape (16,) int16 signed
    Return: 256-bit word as Python int.
    """
    assert lanes.shape[0] == 16
    word = 0
    for i in range(16):
        u16 = np.uint16(lanes[i]).item()
        word |= int(u16) << (16 * i)
    return word


def write_mem_words(mem_path: Path, words: list[int], word_count: int | None = None) -> None:
    mem_path.parent.mkdir(parents=True, exist_ok=True)
    if word_count is None:
        word_count = len(words)
    with mem_path.open("w", encoding="utf8") as f:
        for i in range(word_count):
            v = words[i] if i < len(words) else 0
            f.write(f"{v & ((1 << 256) - 1):064x}\n")
    print(f"[OK] Wrote {mem_path} ({word_count} lines)")


def main():
    root = Path(__file__).resolve().parents[1]  # KLTN/
    golden_dir = root / "ITMN" / "golden_vectors"
    out_dir = root / "RTL" / "code_unoptimize" / "init"

    SEQ_LEN = 1000
    D_MODEL = 64
    D_INNER = 128
    D_STATE = 16
    D_CONV = 4

    # Memory bases (from Global_Controller_Full_Flow.v)
    ADDR_X_INPUT = 0
    W_BASE_INPROJ1 = 0
    W_BASE_INPROJ2 = 512
    W_BASE_CONV = 1024
    W_BASE_XPROJ = 1536
    W_BASE_DTPROJ = 1920
    W_BASE_OUTPROJ = 2432

    CONST_CONV_BIAS = 0
    CONST_DT_BIAS_BASE = 128
    ADDR_A_BASE = 1024
    ADDR_D_BASE = 1152

    # BRAM word count bounds (dense init)
    core_words = SEQ_LEN * (D_MODEL // 16)  # 1000*4 = 4000
    weight_words = 3000
    const_words = 1160

    # Load float32 bins
    def load_bin(name: str) -> np.ndarray:
        p = golden_dir / name
        if not p.exists():
            raise FileNotFoundError(p)
        return np.fromfile(str(p), dtype=np.float32)

    golden_input = load_bin("golden_input.bin")  # (1000*64)
    in_proj1_weight = load_bin("in_proj1_weight.bin")  # (128*64)
    in_proj2_weight = load_bin("in_proj2_weight.bin")  # (128*64)
    conv1d_weight = load_bin("conv1d_weight.bin")  # (128*4)
    conv1d_bias = load_bin("conv1d_bias.bin")  # (128,)
    x_proj_weight = load_bin("x_proj_weight.bin")  # (36*128)
    dt_proj_weight = load_bin("dt_proj_weight.bin")  # (128*4)
    dt_proj_bias = load_bin("dt_proj_bias.bin")  # (128,)
    out_proj_weight = load_bin("out_proj_weight.bin")  # (64*128)
    A_log = load_bin("A_log.bin")  # (128*16)
    D = load_bin("D.bin")  # (128,)

    # Shapes from mamba_ssm:
    x = golden_input.reshape(SEQ_LEN, D_MODEL)
    W_in1 = in_proj1_weight.reshape(D_INNER, D_MODEL)  # [128,64]
    W_in2 = in_proj2_weight.reshape(D_INNER, D_MODEL)  # [128,64]
    W_conv = conv1d_weight.reshape(D_INNER, D_CONV)    # [128,4] (squeeze dim=1)
    b_conv = conv1d_bias.reshape(D_INNER)               # [128]
    W_xproj = x_proj_weight.reshape(D_STATE * 2 + 4, D_INNER)  # [36,128], order (dt,B,C)
    W_dtproj = dt_proj_weight.reshape(D_INNER, 4)      # [128,4]
    b_dtproj = dt_proj_bias.reshape(D_INNER)            # [128]
    W_out = out_proj_weight.reshape(D_MODEL, D_INNER)  # [64,128]
    # In mamba_ssm: A = -exp(A_log)
    A = -np.exp(A_log.reshape(D_INNER, D_STATE))     # [128,16]
    d = D.reshape(D_INNER)                             # [128]

    # Quantize
    x_q = quant_q312(x)
    W_in1_q = quant_q312(W_in1)
    W_in2_q = quant_q312(W_in2)
    W_conv_q = quant_q312(W_conv)
    b_conv_q = quant_q312(b_conv)
    W_xproj_q = quant_q312(W_xproj)
    W_dtproj_q = quant_q312(W_dtproj)
    b_dtproj_q = quant_q312(b_dtproj)
    W_out_q = quant_q312(W_out)
    A_q = quant_q312(A)
    D_q = quant_q312(d)

    # Prepare dense init arrays (each element is one 256-bit word)
    coreA = [0] * core_words
    weight = [0] * weight_words
    const = [0] * const_words

    # ------------------------
    # Core RAM A: input x
    # Addressing: ADDR_X_INPUT + (token*4 + chunk), where chunk in 0..3.
    # Each 256-bit word packs 16 consecutive features (D_MODEL split to 4 groups).
    # ------------------------
    for t in range(SEQ_LEN):
        for chunk in range(D_MODEL // 16):  # 0..3
            addr = ADDR_X_INPUT + t * (D_MODEL // 16) + chunk
            lanes = x_q[t, chunk * 16 : (chunk + 1) * 16]
            coreA[addr] = pack_lanes_q312(lanes)

    # ------------------------
    # Weight RAM: in_proj1 / in_proj2
    # Controller: weight_read_addr = base + chunk_out*64 + input_idx + 1
    # where chunk_out in 0..7 and input_idx in 0..63.
    # Each word packs 16 output lanes for that output chunk:
    #   out_row = chunk_out*16 + lane
    # ------------------------
    def fill_linear_inproj(base: int, W_q: np.ndarray):
        for chunk_out in range(D_INNER // 16):  # 0..7
            for in_idx in range(D_MODEL):  # 0..63
                addr = base + chunk_out * D_MODEL + in_idx + 1
                lanes = np.array([W_q[chunk_out * 16 + lane, in_idx] for lane in range(16)], dtype=np.int16)
                if addr < len(weight):
                    weight[addr] = pack_lanes_q312(lanes)

    fill_linear_inproj(W_BASE_INPROJ1, W_in1_q)
    fill_linear_inproj(W_BASE_INPROJ2, W_in2_q)

    # ------------------------
    # Weight RAM: conv1d weights
    # Controller loads 4 words (w_load_cnt=0..3) into w_conv_cache blocks.
    # Based on Conv1D_Layer unpack: weights_vec[(i*4 + k)].
    # With w_conv_cache[k*256 +:256], each 256-bit word corresponds to an i-group of 4 channels.
    # So w_load_cnt (0..3) -> i_group g = 0..3, mapping i = 4*g + lane//4, tap k=lane%4.
    # ------------------------
    # Controller per conv chunk: base_weight_addr = W_BASE_CONV + chunk_cnt*4, then reads base + w_load_cnt.
    for conv_chunk in range(D_INNER // 16):  # 0..7 (16 channels each)
        base = W_BASE_CONV + conv_chunk * 4
        for g in range(4):  # w_load_cnt
            addr = base + g
            lanes = []
            for lane in range(16):  # element index within 256-bit segment
                i = 4 * g + (lane // 4)         # 0..15 within the conv chunk
                k = lane % 4                     # tap 0..3
                out_ch = conv_chunk * 16 + i     # 0..127
                lanes.append(W_conv_q[out_ch, k])
            lanes = np.array(lanes, dtype=np.int16)
            if addr < len(weight):
                weight[addr] = pack_lanes_q312(lanes)

    # ------------------------
    # Const RAM: conv bias (8 words)
    # Controller: const_read_addr = CONST_CONV_BIAS + chunk_cnt
    # ------------------------
    b_groups = b_conv_q.reshape(D_INNER // 16, 16)  # (8,16)
    for chunk_cnt in range(D_INNER // 16):  # 0..7
        addr = CONST_CONV_BIAS + chunk_cnt
        const[addr] = pack_lanes_q312(b_groups[chunk_cnt])

    # ------------------------
    # Weight RAM: x_proj weights
    # x_proj output order = (dt_rank=4, B=16, C=16). Total 36.
    # Controller uses 3 "chunk_cnt":
    #  - chunk_cnt==0 writes B (16 lanes)
    #  - chunk_cnt==1 writes C (16 lanes)
    #  - chunk_cnt==2 writes dt_raw (only first 4 lanes used; rest can be 0)
    # Controller per chunk reads lin_len=128 with weight_read_addr assumed: base + input_idx + 1
    # ------------------------
    dt_rank = 4
    B_start = dt_rank
    C_start = dt_rank + D_STATE

    for xproj_chunk in range(3):  # 0,1,2
        base = W_BASE_XPROJ + xproj_chunk * D_INNER  # *128
        for in_idx in range(D_INNER):  # 0..127
            addr = base + in_idx + 1
            lanes = np.zeros(16, dtype=np.int16)
            for lane in range(16):
                if xproj_chunk == 0:
                    out_row = B_start + lane  # B
                    lanes[lane] = W_xproj_q[out_row, in_idx]
                elif xproj_chunk == 1:
                    out_row = C_start + lane  # C
                    lanes[lane] = W_xproj_q[out_row, in_idx]
                else:
                    # dt raw only in lanes 0..3
                    if lane < dt_rank:
                        lanes[lane] = W_xproj_q[lane, in_idx]
                    else:
                        lanes[lane] = np.int16(0)
            if addr < len(weight):
                weight[addr] = pack_lanes_q312(lanes)

    # ------------------------
    # Weight RAM: dt_proj weights (8 chunks, each chunk reads 4 inputs)
    # Controller per chunk reads dt_rank=4 (len=4) with weight addresses base + dt_idx + 1
    # where dt_idx in 0..3 maps to input column.
    # ------------------------
    for dt_out_chunk in range(D_INNER // 16):  # 0..7
        base = W_BASE_DTPROJ + dt_out_chunk * 4
        for dt_in_idx in range(4):
            addr = base + dt_in_idx + 1
            lanes = np.array([W_dtproj_q[dt_out_chunk * 16 + lane, dt_in_idx] for lane in range(16)], dtype=np.int16)
            if addr < len(weight):
                weight[addr] = pack_lanes_q312(lanes)

    # Const RAM: dt bias (8 words at 128..135)
    b_dt_groups = b_dtproj_q.reshape(D_INNER // 16, 16)
    for chunk_cnt in range(D_INNER // 16):  # 0..7
        addr = CONST_DT_BIAS_BASE + chunk_cnt
        const[addr] = pack_lanes_q312(b_dt_groups[chunk_cnt])

    # ------------------------
    # Weight RAM: out_proj weights (4 chunks, 16 lanes each)
    # out_proj weight shape [64,128] => output split into 4 chunks of 16.
    # Controller assumes weight_read_addr = base + input_idx + 1.
    # ------------------------
    for out_chunk in range(D_MODEL // 16):  # 0..3
        base = W_BASE_OUTPROJ + out_chunk * D_INNER  # *128
        for in_idx in range(D_INNER):  # 0..127
            addr = base + in_idx + 1
            lanes = np.array([W_out_q[out_chunk * 16 + lane, in_idx] for lane in range(16)], dtype=np.int16)
            if addr < len(weight):
                weight[addr] = pack_lanes_q312(lanes)

    # ------------------------
    # Const RAM: A_log and D
    # A: 128 words at ADDR_A_BASE + ch, each word packs A[ch, 0..15]
    # D: 8 words at ADDR_D_BASE + (ch/16), each word packs D[16g..16g+15]
    # ------------------------
    for ch in range(D_INNER):  # 0..127
        addr = ADDR_A_BASE + ch
        if addr < len(const):
            const[addr] = pack_lanes_q312(A_q[ch, :])

    D_groups = D_q.reshape(D_INNER // 16, 16)  # (8,16)
    for g in range(D_INNER // 16):  # 0..7
        addr = ADDR_D_BASE + g
        if addr < len(const):
            const[addr] = pack_lanes_q312(D_groups[g])

    # Write mem files
    write_mem_words(out_dir / "coreA_init.mem", coreA, core_words)
    write_mem_words(out_dir / "weight_init.mem", weight, weight_words)
    write_mem_words(out_dir / "const_init.mem", const, const_words)

    print("[DONE] Generate RTL init images from golden_vectors.")


if __name__ == "__main__":
    main()

