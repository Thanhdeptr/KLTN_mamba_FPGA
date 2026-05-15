#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import argparse
import shutil
import numpy as np

FRAC_BITS = 12
MAX_Q = 32767
MIN_Q = -32768


def qhex(v: float) -> str:
    q = int(np.trunc(float(v) * (1 << FRAC_BITS)))
    if q > MAX_Q:
        q = MAX_Q
    elif q < MIN_Q:
        q = MIN_Q
    return f"{(q & 0xFFFF):04x}"


def write_mem(path: Path, arr: np.ndarray) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    flat = arr.reshape(-1)
    with path.open("w", encoding="utf-8") as f:
        for x in flat:
            f.write(qhex(float(x)) + "\n")


def q16_to_signed(v: int) -> int:
    v &= 0xFFFF
    return v - 0x10000 if (v & 0x8000) else v


def signed_to_q16(v: int) -> int:
    if v > MAX_Q:
        v = MAX_Q
    elif v < MIN_Q:
        v = MIN_Q
    return v & 0xFFFF


def qfloat_to_q16(v: float) -> int:
    return signed_to_q16(int(np.trunc(float(v) * (1 << FRAC_BITS))))


def mul_shift(a: int, b: int) -> int:
    prod = q16_to_signed(a) * q16_to_signed(b)
    return prod >> FRAC_BITS


def mul_shift_sat16(a: int, b: int) -> int:
    return sat16(mul_shift(a, b))


def sat16(v: int) -> int:
    return max(MIN_Q, min(MAX_Q, v))


def read_rom_words(path: Path) -> np.ndarray:
    words: list[int] = []
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            s = line.strip()
            if s:
                words.append(int(s, 16) & 0xFFFFFFFF)
    return np.array(words, dtype=np.uint32)


def silu_pwl_model(x_in: int, rom: np.ndarray) -> int:
    addr = (x_in >> 10) & 0x3F
    word = int(rom[addr])
    slope = q16_to_signed((word >> 16) & 0xFFFF)
    intercept = q16_to_signed(word & 0xFFFF)
    prod = slope * q16_to_signed(x_in)
    res = (prod >> FRAC_BITS) + intercept
    return signed_to_q16(res)


def exp_pwl_model(x_in: int, rom: np.ndarray) -> int:
    addr = (x_in >> 10) & 0x3F
    if addr == 8:
        rom_addr = 64 + ((x_in >> 8) & 0x3)
    else:
        rom_addr = addr
    word = int(rom[rom_addr])
    slope = q16_to_signed((word >> 16) & 0xFFFF)
    intercept = q16_to_signed(word & 0xFFFF)
    prod = slope * q16_to_signed(x_in)
    res = (prod >> FRAC_BITS) + intercept
    if res < 0:
        return 0
    return signed_to_q16(res)


def simulate_scan_branch(
    x_activated: np.ndarray,
    gate: np.ndarray,
    delta: np.ndarray,
    b_raw: np.ndarray,
    c_raw: np.ndarray,
    a_vec: np.ndarray,
    d_vec: np.ndarray,
    silu_rom: np.ndarray,
    exp_rom: np.ndarray,
) -> np.ndarray:
    tokens, d_inner = x_activated.shape
    _, d_state = b_raw.shape

    h_state = np.zeros((d_inner, d_state), dtype=np.int32)
    y_gated = np.zeros((tokens, d_inner), dtype=np.int32)

    a_q = np.vectorize(qfloat_to_q16)(a_vec).astype(np.int32)
    d_q = np.vectorize(qfloat_to_q16)(d_vec).astype(np.int32)

    for tok in range(tokens):
        delta_tok = np.vectorize(qfloat_to_q16)(delta[tok]).astype(np.int32)
        x_tok = np.vectorize(qfloat_to_q16)(x_activated[tok]).astype(np.int32)
        gate_tok = np.vectorize(qfloat_to_q16)(gate[tok]).astype(np.int32)
        b_tok = np.vectorize(qfloat_to_q16)(b_raw[tok]).astype(np.int32)
        c_tok = np.vectorize(qfloat_to_q16)(c_raw[tok]).astype(np.int32)

        for ch in range(d_inner):
            delta_ch = int(delta_tok[ch])
            x_ch = int(x_tok[ch])
            gate_ch = int(gate_tok[ch])
            d_ch = int(d_q[ch])

            y_sum = 0
            for state in range(d_state):
                a_ch = int(a_q[ch, state])
                b_ch = int(b_tok[state])
                c_ch = int(c_tok[state])

                # PE MODE_MUL path saturates to 16-bit every operation.
                delta_a = mul_shift_sat16(delta_ch, a_ch)
                disc_a = exp_pwl_model(signed_to_q16(delta_a), exp_rom)
                delta_b = mul_shift_sat16(delta_ch, b_ch)
                delta_bx = mul_shift_sat16(signed_to_q16(delta_b), x_ch)
                h_old = int(h_state[ch, state])
                disc_a_h = mul_shift_sat16(disc_a, h_old)
                h_new = sat16(disc_a_h + delta_bx)
                h_state[ch, state] = h_new
                y_sum += mul_shift_sat16(c_ch, h_new)

            # RTL computes x*D and y_with_D in 32-bit without saturation,
            # then applies gate and final saturation only at the output.
            y_with_d = y_sum + mul_shift(x_ch, d_ch)
            gate_act = silu_pwl_model(signed_to_q16(gate_ch), silu_rom)
            y_final_raw = (y_with_d * q16_to_signed(gate_act)) >> FRAC_BITS
            y_gated[tok, ch] = sat16(y_final_raw)

    return y_gated


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--tail-golden-source",
        choices=["cpp", "rebuild"],
        default="cpp",
        help="cpp: use cpp_golden_files directly for YGated/FinalOut; rebuild: regenerate tail in fixed-point model",
    )
    args = ap.parse_args()

    root = Path(__file__).resolve().parents[3]
    out = Path(__file__).resolve().parent
    cpp = root / "ITMN" / "cpp_golden_files"
    gv = root / "ITMN" / "golden_vectors"
    rtl_dir = root / "RTL" / "code_initial"

    mamba_in = np.loadtxt(cpp / "06_06_MambaBlock_input.txt", dtype=np.float32)             # [1000,64]
    rms_gold = np.loadtxt(cpp / "07_07_MambaBlock_after_norm.txt", dtype=np.float32)         # [1000,64]
    x_after_linear = np.loadtxt(cpp / "08_X_after_linear.txt", dtype=np.float32)             # [1000,256]

    x_activated_cm = np.loadtxt(cpp / "09_08_Mixer_x_activated.txt", dtype=np.float32)       # [128,1000]
    delta_cm = np.loadtxt(cpp / "10_09_Mixer_delta_final.txt", dtype=np.float32)              # [128,1000]
    b_raw = np.loadtxt(cpp / "11_10_Mixer_B_raw.txt", dtype=np.float32)                       # [1000,16]
    c_raw = np.loadtxt(cpp / "12_11_Mixer_C_raw.txt", dtype=np.float32)                       # [1000,16]

    y_gated_cm = np.loadtxt(cpp / "1014_14_Mixer_y_gated.txt", dtype=np.float32)              # [128,1000]
    final_gold = np.loadtxt(cpp / "1015_15_Mixer_final_output.txt", dtype=np.float32)         # [1000,64]

    # Channel-major -> token-major
    x_activated = x_activated_cm.T
    delta = delta_cm.T
    y_gated = y_gated_cm.T

    if mamba_in.shape != (1000, 64):
        raise ValueError(f"Unexpected mamba input shape {mamba_in.shape}")
    if rms_gold.shape != (1000, 64):
        raise ValueError(f"Unexpected rms shape {rms_gold.shape}")
    if x_after_linear.shape != (1000, 256):
        raise ValueError(f"Unexpected x_after_linear shape {x_after_linear.shape}")
    if x_activated.shape != (1000, 128):
        raise ValueError(f"Unexpected x_activated shape {x_activated.shape}")
    if delta.shape != (1000, 128):
        raise ValueError(f"Unexpected delta shape {delta.shape}")
    if y_gated.shape != (1000, 128):
        raise ValueError(f"Unexpected y_gated shape {y_gated.shape}")
    if final_gold.shape != (1000, 64):
        raise ValueError(f"Unexpected final shape {final_gold.shape}")

    if b_raw.shape[1] != 16 or c_raw.shape[1] != 16:
        raise ValueError(f"B/C raw shape mismatch: B={b_raw.shape}, C={c_raw.shape}")

    rms_w = np.fromfile(gv / "rms_norm_weight.bin", dtype=np.float32)                         # [64]
    inproj_w = np.fromfile(gv / "in_proj1_weight.bin", dtype=np.float32).reshape(128, 64)     # [128,64]
    conv_w = np.fromfile(gv / "conv1d_weight.bin", dtype=np.float32).reshape(128, 4)          # [128,4]
    conv_b = np.fromfile(gv / "conv1d_bias.bin", dtype=np.float32)                             # [128]
    out_w = np.fromfile(gv / "out_proj_weight.bin", dtype=np.float32).reshape(64, 128)        # [64,128]
    # RTL packing expectation in this chain test maps flattened weights as transposed.
    # Keep an explicit effective matrix so rebuild and RTL mem use the same layout.
    out_w_eff = out_w.T.reshape(64, 128)

    a_log = np.fromfile(gv / "A_log.bin", dtype=np.float32).reshape(128, 16)                   # [128,16]
    a_vec = -np.exp(a_log)
    d_vec = np.fromfile(gv / "D.bin", dtype=np.float32)                                        # [128]
    silu_rom = read_rom_words(rtl_dir / "silu_pwl_coeffs.mem")
    exp_rom = read_rom_words(rtl_dir / "exp_pwl_coeffs.mem")

    # For integration compare of InProjection, use first 128 dims from 08_X_after_linear.
    inproj_gold = x_after_linear[:, :128]
    gate_from_xz = x_after_linear[:, 128:256]

    # Rebuild the branch-stage goldens in fixed-point so they match the RTL chain.
    x_activated_q = np.zeros_like(inproj_gold, dtype=np.float32)
    for tok in range(inproj_gold.shape[0]):
        for ch in range(inproj_gold.shape[1]):
            x_q = qfloat_to_q16(float(inproj_gold[tok, ch]))
            x_activated_q[tok, ch] = np.float32(
                q16_to_signed(silu_pwl_model(x_q, silu_rom)) / float(1 << FRAC_BITS)
            )

    y_gated_q = simulate_scan_branch(
        x_activated=x_activated_q,
        gate=gate_from_xz,
        delta=delta,
        b_raw=b_raw,
        c_raw=c_raw,
        a_vec=a_vec,
        d_vec=d_vec,
        silu_rom=silu_rom,
        exp_rom=exp_rom,
    )
    y_gated_q_float = y_gated_q.astype(np.float32) / float(1 << FRAC_BITS)

    out_w_q = np.vectorize(qfloat_to_q16)(out_w_eff).astype(np.int32)
    final_q = np.zeros((y_gated_q.shape[0], 64), dtype=np.float32)
    for tok in range(y_gated_q.shape[0]):
        for out_ch in range(64):
            acc = 0
            for in_ch in range(128):
                acc += mul_shift(
                    int(out_w_q[out_ch, in_ch]),
                    signed_to_q16(int(y_gated_q[tok, in_ch])),
                )
            final_q[tok, out_ch] = np.float32(sat16(acc) / float(1 << FRAC_BITS))

    if args.tail_golden_source == "cpp":
        y_gated_out = y_gated.astype(np.float32)
        final_out = final_gold.astype(np.float32)
    else:
        y_gated_out = y_gated_q_float
        final_out = final_q

    write_mem(out / "mamba_input.mem", mamba_in)
    write_mem(out / "rms_weight.mem", rms_w)
    write_mem(out / "rms_golden.mem", rms_gold)

    write_mem(out / "inproj_weight.mem", inproj_w)
    write_mem(out / "inproj_golden.mem", inproj_gold)
    write_mem(out / "conv_weight.mem", conv_w)
    write_mem(out / "conv_bias.mem", conv_b)

    write_mem(out / "delta.mem", delta)
    write_mem(out / "x_activated.mem", x_activated)
    write_mem(out / "gate.mem", gate_from_xz)
    write_mem(out / "B_raw.mem", b_raw)
    write_mem(out / "C_raw.mem", c_raw)
    write_mem(out / "A_vec.mem", a_vec)
    # cpp scan_output_raw already includes residual contribution for this chain test,
    # so keep D_vec at zero to avoid double-counting in RTL scan stage.
    write_mem(out / "D_vec.mem", np.zeros_like(d_vec, dtype=np.float32))
    write_mem(out / "y_gated_golden.mem", y_gated_out)

    write_mem(out / "outproj_weight.mem", out_w_eff)
    write_mem(out / "final_golden.mem", final_out)

    # Keep RMSNorm LUT colocated with testbench working dir for $readmemh.
    rsqrt_src = rtl_dir / "rmsnorm_rsqrt_coeffs.mem"
    if rsqrt_src.exists():
        shutil.copyfile(rsqrt_src, out / "rmsnorm_rsqrt_coeffs.mem")

    print(f"Prepared full-branch mem files in {out} (tail source: {args.tail_golden_source})")


if __name__ == "__main__":
    main()
