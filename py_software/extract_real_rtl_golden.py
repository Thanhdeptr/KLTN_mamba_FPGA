#!/usr/bin/env python3
"""Regenerate non-trivial .mem stimuli from real ITMN artifacts.

This script only uses real sources:
- ITMN/cpp_golden_files/*.txt
- ITMN/golden_vectors/*.bin
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

FRAC_BITS = 12
MAX_SIGNED_16 = 32767
MIN_SIGNED_16 = -32768


def to_hex16(v: int) -> str:
    return f"{(v & 0xFFFF):04x}"


def float_to_q16(val: float) -> int:
    q = int(float(val) * (2 ** FRAC_BITS))
    if q > MAX_SIGNED_16:
        q = MAX_SIGNED_16
    elif q < MIN_SIGNED_16:
        q = MIN_SIGNED_16
    return q & 0xFFFF


def parse_tensor_txt(txt_path: Path) -> np.ndarray:
    vals: list[float] = []
    with txt_path.open("r", encoding="utf-8") as f:
        for token in f.read().split():
            vals.append(float(token))
    return np.array(vals, dtype=np.float32)


def read_bin(path: Path) -> np.ndarray:
    return np.fromfile(path, dtype=np.float32)


def load_silu_rom(path: Path) -> np.ndarray:
    rom: list[int] = []
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            s = line.strip()
            if s:
                rom.append(int(s, 16) & 0xFFFFFFFF)
    return np.array(rom, dtype=np.uint32)


def softplus_pwl_model(x_in: int, rom: np.ndarray) -> int:
    x = q16_to_signed(x_in)
    addr = (x_in & 0xFFFF) >> 10
    addr &= 0x3F
    word = int(rom[addr])
    slope = q16_to_signed((word >> 16) & 0xFFFF)
    intercept = q16_to_signed(word & 0xFFFF)
    prod = slope * x
    if prod >= 0x80000000:
        prod -= 0x100000000
    return sat16((prod >> FRAC_BITS) + intercept)


def find_one(folder: Path, suffix: str) -> Path:
    matches = sorted(folder.glob(f"*{suffix}"))
    if not matches:
        raise FileNotFoundError(f"Cannot find file with suffix: {suffix}")
    return matches[0]


def save_mem_file(output_path: Path, values: np.ndarray, count: int) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    flat = values.astype(np.float32).reshape(-1)
    if flat.size == 0:
        raise ValueError(f"Empty source tensor for {output_path.name}")
    selected = flat[:count]
    with output_path.open("w", encoding="utf-8") as f:
        for v in selected:
            f.write(to_hex16(float_to_q16(float(v))) + "\n")
    print(f"  ✓ {output_path.name}")


def q16_to_signed(v: int) -> int:
    v &= 0xFFFF
    return v - 0x10000 if (v & 0x8000) else v


def sat16(v: int) -> int:
    return max(MIN_SIGNED_16, min(MAX_SIGNED_16, v))


def mul_shift(a: int, b: int) -> int:
    prod = q16_to_signed(a) * q16_to_signed(b)
    return prod >> FRAC_BITS


def silu_pwl_model(x_in: int, rom: np.ndarray) -> int:
    x = q16_to_signed(x_in)
    addr = (x_in & 0xFFFF) >> 10
    addr &= 0x3F
    word = int(rom[addr])
    slope = q16_to_signed((word >> 16) & 0xFFFF)
    intercept = q16_to_signed(word & 0xFFFF)
    prod = slope * x
    if prod >= 0x80000000:
        prod -= 0x100000000
    return sat16((prod >> FRAC_BITS) + intercept)


def conv1d_lane_golden(feat_in: np.ndarray, weights: np.ndarray, bias: np.ndarray, silu_rom: np.ndarray) -> np.ndarray:
    feat_q = [float_to_q16(float(v)) for v in feat_in[:16]]
    w_q = [float_to_q16(float(v)) for v in weights[:64]]
    b_q = [float_to_q16(float(v)) for v in bias[:16]]
    out: list[float] = []
    for lane in range(16):
        base = lane * 4
        acc = sat16(mul_shift(b_q[lane], 0x1000))
        acc = sat16(acc + mul_shift(feat_q[lane], w_q[base + 0]))
        acc = sat16(acc + mul_shift(0, w_q[base + 1]))
        acc = sat16(acc + mul_shift(0, w_q[base + 2]))
        acc = sat16(acc + mul_shift(0, w_q[base + 3]))
        out_q = silu_pwl_model(acc, silu_rom)
        out.append(np.float32(q16_to_signed(out_q) / float(2 ** FRAC_BITS)))
    return np.array(out, dtype=np.float32)


def scan_scalar_golden(cpp_dir: Path, gv_dir: Path) -> np.ndarray:
    delta = parse_tensor_txt(find_one(cpp_dir, "_Mixer_delta_final.txt"))[0]
    x_act = parse_tensor_txt(find_one(cpp_dir, "_Mixer_x_activated.txt"))[0]
    b_raw = parse_tensor_txt(find_one(cpp_dir, "_Mixer_B_raw.txt"))[:16]
    c_raw = parse_tensor_txt(find_one(cpp_dir, "_Mixer_C_raw.txt"))[:16]
    xz = parse_tensor_txt(find_one(cpp_dir, "_X_after_linear.txt"))

    a_log = read_bin(gv_dir / "A_log.bin")
    d_vec = read_bin(gv_dir / "D.bin")
    silu_rom = load_silu_rom(gv_dir.parent.parent / "RTL" / "code_initial" / "silu_pwl_coeffs.mem")

    delta_q = float_to_q16(float(delta))
    x_q = float_to_q16(float(x_act))
    d_q = float_to_q16(float(d_vec[0]))
    gate_q = float_to_q16(float(xz[128] if xz.size > 128 else xz[0]))
    gate_val_q = silu_pwl_model(gate_q, silu_rom)

    b_vec_q = [float_to_q16(float(v)) for v in b_raw]
    c_vec_q = [float_to_q16(float(v)) for v in c_raw]

    sum_raw = 0
    for bj_q, cj_q in zip(b_vec_q, c_vec_q):
        delta_b = mul_shift(delta_q, bj_q)
        delta_bx = mul_shift(delta_b, x_q)
        sum_raw += mul_shift(delta_bx, cj_q)

    y_with_d = sat16(sum_raw + mul_shift(x_q, d_q))
    gated = sat16(mul_shift(y_with_d & 0xFFFF, gate_val_q & 0xFFFF))
    return np.array([np.float32(q16_to_signed(gated) / float(2 ** FRAC_BITS))], dtype=np.float32)


def softplus_vector_golden(inputs: np.ndarray, root_dir: Path) -> np.ndarray:
    rom = load_silu_rom(root_dir / "RTL" / "code_initial" / "softplus_pwl_coeffs.mem")
    outputs: list[float] = []
    for value in inputs:
        value_q = float_to_q16(float(value))
        out_q = softplus_pwl_model(value_q, rom)
        outputs.append(np.float32(q16_to_signed(out_q) / float(2 ** FRAC_BITS)))
    return np.array(outputs, dtype=np.float32)


def derive_delta_before_softplus(delta_final: np.ndarray) -> np.ndarray:
    # Inverse softplus: x = log(exp(y) - 1), with stable form.
    y = delta_final.astype(np.float32)
    tiny = np.float32(1e-6)
    y = np.maximum(y, tiny)
    x = np.where(y > 20.0, y, y + np.log1p(-np.exp(-y)))
    return x.astype(np.float32)


def load_delta_before_softplus(cpp_dir: Path) -> np.ndarray:
    try:
        return parse_tensor_txt(find_one(cpp_dir, "_Mixer_delta_before_softplus.txt"))
    except FileNotFoundError:
        delta_final = parse_tensor_txt(find_one(cpp_dir, "_Mixer_delta_final.txt"))
        print("  ! Missing _Mixer_delta_before_softplus.txt, deriving from delta_final via inverse softplus")
        return derive_delta_before_softplus(delta_final)


def itm_block_golden(cpp_dir: Path, gv_dir: Path) -> np.ndarray:
    feat = parse_tensor_txt(find_one(cpp_dir, "_ITMBlock_input.txt"))
    conv_w = read_bin(gv_dir / "conv1d_weight.bin")
    conv_b = read_bin(gv_dir / "conv1d_bias.bin")
    silu_rom = load_silu_rom(gv_dir.parent.parent / "RTL" / "code_initial" / "silu_pwl_coeffs.mem")
    conv_out = conv1d_lane_golden(feat, conv_w, conv_b, silu_rom)
    scan_scalar = scan_scalar_golden(cpp_dir, gv_dir)[0]

    scan_q = float_to_q16(float(scan_scalar))
    scan_relu_q = scan_q if q16_to_signed(scan_q) >= 0 else 0

    out: list[float] = []
    for value in conv_out[:16]:
        value_q = float_to_q16(float(value))
        merged_q = sat16(q16_to_signed(value_q) + q16_to_signed(scan_relu_q))
        out.append(np.float32(q16_to_signed(merged_q) / float(2 ** FRAC_BITS)))
    return np.array(out, dtype=np.float32)


def make_scan_payload(cpp_dir: Path, gv_dir: Path) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    delta = parse_tensor_txt(find_one(cpp_dir, "_Mixer_delta_final.txt"))
    x_act = parse_tensor_txt(find_one(cpp_dir, "_Mixer_x_activated.txt"))
    b_raw = parse_tensor_txt(find_one(cpp_dir, "_Mixer_B_raw.txt"))
    c_raw = parse_tensor_txt(find_one(cpp_dir, "_Mixer_C_raw.txt"))
    xz = parse_tensor_txt(find_one(cpp_dir, "_X_after_linear.txt"))

    a_log = read_bin(gv_dir / "A_log.bin")
        d_vec = read_bin(gv_dir / "D.bin")  # Load the real D vector
    a_vec = -np.exp(a_log.reshape(-1, 16)[0])

    z_first = xz[128] if xz.size > 128 else xz[0]
    scalar = np.array([delta[0], x_act[0], d_vec[0], z_first], dtype=np.float32)

    golden_scalar = scan_scalar_golden(cpp_dir, gv_dir)

    return scalar, a_vec, b_raw, c_raw, golden_scalar


def extract_conv1d(cpp_dir: Path, gv_dir: Path, test_dir: Path) -> None:
    print("\n[Conv1D_Layer]")
    x_in = parse_tensor_txt(find_one(cpp_dir, "_Mixer_X_before_conv_silu.txt"))
    y_out = parse_tensor_txt(find_one(cpp_dir, "_Mixer_x_activated.txt"))
    w = read_bin(gv_dir / "conv1d_weight.bin")
    b = read_bin(gv_dir / "conv1d_bias.bin")

    save_mem_file(test_dir / "x_in.mem", x_in, 128)
    save_mem_file(test_dir / "conv1d_weights.mem", w, 512)
    save_mem_file(test_dir / "conv1d_bias.mem", b, 128)
    save_mem_file(test_dir / "golden_output.mem", y_out, 128)


def extract_linear(cpp_dir: Path, gv_dir: Path, test_dir: Path) -> None:
    print("\n[Linear_Layer]")
    x_norm = parse_tensor_txt(find_one(cpp_dir, "_MambaBlock_after_norm.txt"))
    x_linear = parse_tensor_txt(find_one(cpp_dir, "_X_after_linear.txt"))
    w = read_bin(gv_dir / "in_proj1_weight.bin")
    b = read_bin(gv_dir / "dt_proj_bias.bin")

    save_mem_file(test_dir / "x_val.mem", x_norm, 1)
    save_mem_file(test_dir / "W_row.mem", w, 16)
    save_mem_file(test_dir / "bias.mem", b, 16)
    save_mem_file(test_dir / "golden_output.mem", x_linear, 16)


def extract_scan(cpp_dir: Path, gv_dir: Path, test_dir: Path) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    print("\n[Scan_Core_Engine]")
    scalar, a_vec, b_vec, c_vec, y_gold = make_scan_payload(cpp_dir, gv_dir)
    delta_before_softplus = load_delta_before_softplus(cpp_dir)

    save_mem_file(test_dir / "scalar_input.mem", scalar, 4)
    save_mem_file(test_dir / "A_vec.mem", a_vec, 16)
    save_mem_file(test_dir / "B_vec.mem", b_vec, 16)
    save_mem_file(test_dir / "C_vec.mem", c_vec, 16)
    save_mem_file(test_dir / "delta_before_softplus.mem", delta_before_softplus, int(delta_before_softplus.size))
    save_mem_file(test_dir / "golden_output.mem", y_gold, 1)
    return scalar, a_vec, b_vec, c_vec, y_gold


def extract_softplus(cpp_dir: Path, root_dir: Path, test_dir: Path) -> None:
    print("\n[Softplus_Unit_PWL]")
    delta_before_softplus = load_delta_before_softplus(cpp_dir)
    delta_after_softplus = softplus_vector_golden(delta_before_softplus, root_dir)

    save_mem_file(test_dir / "input.mem", delta_before_softplus, int(delta_before_softplus.size))
    save_mem_file(test_dir / "golden_output.mem", delta_after_softplus, int(delta_after_softplus.size))





def main() -> None:
    k_root = Path(__file__).resolve().parents[1]
    cpp_dir = k_root / "ITMN" / "cpp_golden_files"
    gv_dir = k_root / "ITMN" / "golden_vectors"

    print("=" * 70)
    print("ITMN REAL DATA EXTRACTION FOR RTL TESTS")
    print("=" * 70)
    print(f"KLTN_ROOT: {k_root}")

    if not cpp_dir.exists():
        print(f"\nERROR: Missing folder: {cpp_dir}")
        sys.exit(1)
    if not gv_dir.exists():
        print(f"\nERROR: Missing folder: {gv_dir}")
        sys.exit(1)

    try:
        extract_conv1d(cpp_dir, gv_dir, k_root / "RTL" / "code_AI_gen" / "test_Conv1D_Layer")
        extract_linear(cpp_dir, gv_dir, k_root / "RTL" / "code_AI_gen" / "test_Linear_Layer")
        scan_payload = extract_scan(cpp_dir, gv_dir, k_root / "RTL" / "code_AI_gen" / "test_Scan_Core_Engine")
        extract_softplus(cpp_dir, k_root, k_root / "RTL" / "code_AI_gen" / "test_Softplus_Unit_PWL")
        extract_itm_block(cpp_dir, gv_dir, k_root / "RTL" / "code_AI_gen" / "test_ITM_Block", scan_payload)
        extract_mamba_top(cpp_dir, gv_dir, k_root / "RTL" / "code_AI_gen" / "test_Mamba_Top_ITM", scan_payload)
        extract_new_module_vectors(cpp_dir, gv_dir, k_root)

        print("\n" + "=" * 70)
        print("DONE: Regenerated .mem from real ITMN artifacts")
        print("=" * 70)
    except Exception as exc:
        print(f"\nERROR: {exc}")
        raise


if __name__ == "__main__":
    main()
