#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import numpy as np

FRAC_BITS = 12
MAX_SIGNED_16 = 32767
MIN_SIGNED_16 = -32768


def to_hex16(v: int) -> str:
    return f"{(v & 0xFFFF):04x}"


def q16_to_signed(v: int) -> int:
    v &= 0xFFFF
    return v - 0x10000 if (v & 0x8000) else v


def sat16(v: int) -> int:
    return max(MIN_SIGNED_16, min(MAX_SIGNED_16, v))


def float_to_q16(val: float) -> int:
    q = int(float(val) * (2 ** FRAC_BITS))
    q = sat16(q)
    return q & 0xFFFF


def mul_shift(a: int, b: int) -> int:
    prod = q16_to_signed(a) * q16_to_signed(b)
    return prod >> FRAC_BITS


def read_bin(path: Path) -> np.ndarray:
    return np.fromfile(path, dtype=np.float32)


def parse_tensor_txt(txt_path: Path) -> np.ndarray:
    vals: list[float] = []
    with txt_path.open("r", encoding="utf-8") as f:
        for token in f.read().split():
            vals.append(float(token))
    return np.array(vals, dtype=np.float32)


def find_one(folder: Path, suffix: str) -> Path:
    matches = sorted(folder.glob(f"*{suffix}"))
    if not matches:
        raise FileNotFoundError(f"Cannot find file with suffix: {suffix}")
    return matches[0]


def load_silu_rom(path: Path) -> np.ndarray:
    rom: list[int] = []
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            s = line.strip()
            if s:
                rom.append(int(s, 16) & 0xFFFFFFFF)
    return np.array(rom, dtype=np.uint32)


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


def write_mem16(path: Path, values: list[int]) -> None:
    with path.open("w", encoding="utf-8") as f:
        for v in values:
            f.write(to_hex16(v) + "\n")


def conv1d_lane_golden(feat_in: np.ndarray, weights: np.ndarray, bias: np.ndarray, silu_rom: np.ndarray) -> list[int]:
    feat_q = [float_to_q16(float(v)) for v in feat_in[:16]]
    w_q = [float_to_q16(float(v)) for v in weights[:64]]
    b_q = [float_to_q16(float(v)) for v in bias[:16]]
    out: list[int] = []
    for lane in range(16):
        base = lane * 4
        acc = sat16(mul_shift(b_q[lane], 0x1000))
        acc = sat16(acc + mul_shift(feat_q[lane], w_q[base + 0]))
        acc = sat16(acc + mul_shift(0, w_q[base + 1]))
        acc = sat16(acc + mul_shift(0, w_q[base + 2]))
        acc = sat16(acc + mul_shift(0, w_q[base + 3]))
        out_q = silu_pwl_model(acc & 0xFFFF, silu_rom)
        out.append(out_q & 0xFFFF)
    return out


def scan_scalar_golden(cpp_dir: Path, gv_dir: Path, silu_rom: np.ndarray) -> tuple[int, list[int], list[int], list[int], list[int]]:
    delta = parse_tensor_txt(find_one(cpp_dir, "_Mixer_delta_final.txt"))[0]
    x_act = parse_tensor_txt(find_one(cpp_dir, "_Mixer_x_activated.txt"))[0]
    b_raw = parse_tensor_txt(find_one(cpp_dir, "_Mixer_B_raw.txt"))[:16]
    c_raw = parse_tensor_txt(find_one(cpp_dir, "_Mixer_C_raw.txt"))[:16]
    xz = parse_tensor_txt(find_one(cpp_dir, "_X_after_linear.txt"))

    a_log = read_bin(gv_dir / "A_log.bin")
    _ = a_log
    d_vec = read_bin(gv_dir / "D.bin")

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
    gated = sat16(mul_shift(y_with_d & 0xFFFF, gate_val_q & 0xFFFF)) & 0xFFFF

    scalar = [delta_q, x_q, d_q, gate_q]
    a_vec = (-np.exp(read_bin(gv_dir / "A_log.bin").reshape(-1, 16)[0])).tolist()
    a_vec_q = [float_to_q16(v) for v in a_vec]
    return gated, scalar, a_vec_q, b_vec_q, c_vec_q


def merge_itm(conv_vec_q: list[int], scan_y_q: int) -> list[int]:
    out: list[int] = []
    scan_relu = scan_y_q if q16_to_signed(scan_y_q) >= 0 else 0
    for v in conv_vec_q:
        merged = sat16(q16_to_signed(v) + q16_to_signed(scan_relu))
        out.append(merged & 0xFFFF)
    return out


def main() -> None:
    root = Path(__file__).resolve().parents[3]
    cpp_dir = root / "ITMN" / "cpp_golden_files"
    gv_dir = root / "ITMN" / "golden_vectors"
    out_dir = Path(__file__).resolve().parent

    if not cpp_dir.exists() or not gv_dir.exists():
        raise FileNotFoundError("Missing ITMN/cpp_golden_files or ITMN/golden_vectors")

    feat = parse_tensor_txt(find_one(cpp_dir, "_ITMBlock_input.txt"))
    incept_branch = parse_tensor_txt(find_one(cpp_dir, "_ITMBlock_inception_branch_out.txt"))
    w = read_bin(gv_dir / "conv1d_weight.bin")
    b = read_bin(gv_dir / "conv1d_bias.bin")
    silu_rom = load_silu_rom(root / "RTL" / "code_initial" / "silu_pwl_coeffs.mem")

    _ = conv1d_lane_golden(feat, w, b, silu_rom)
    conv_q = [float_to_q16(float(v)) for v in incept_branch[:16]]
    scan_y_q, scalar_q, a_q, b_q, c_q = scan_scalar_golden(cpp_dir, gv_dir, silu_rom)
    merge_q = merge_itm(conv_q, scan_y_q)

    feat_q = conv_q
    w_q = [float_to_q16(float(v)) for v in w[:64]]
    b_conv_q = [float_to_q16(float(v)) for v in b[:16]]

    write_mem16(out_dir / "feat_in.mem", feat_q)
    write_mem16(out_dir / "weights.mem", w_q)
    write_mem16(out_dir / "bias.mem", b_conv_q)
    write_mem16(out_dir / "scalar_input.mem", scalar_q)
    write_mem16(out_dir / "A_vec.mem", a_q)
    write_mem16(out_dir / "B_vec.mem", b_q)
    write_mem16(out_dir / "C_vec.mem", c_q)

    write_mem16(out_dir / "golden_conv_branch.mem", conv_q)
    write_mem16(out_dir / "golden_scan_scalar.mem", [scan_y_q])
    write_mem16(out_dir / "golden_merge_output.mem", merge_q)
    write_mem16(out_dir / "golden_output.mem", merge_q)

    print("✓ Generated ITM stage mem files:")
    print("  - inputs/weights/scalars")
    print("  - golden_conv_branch.mem")
    print("  - golden_scan_scalar.mem")
    print("  - golden_merge_output.mem")


if __name__ == "__main__":
    main()
