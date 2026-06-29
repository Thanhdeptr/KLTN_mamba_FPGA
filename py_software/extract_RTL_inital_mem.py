#!/usr/bin/env python3
"""Export RTL .mem test vectors for mixer-only testbench folders.

Sources:
- ITMN/cpp_golden_files/*.txt
- ITMN/golden_vectors/*.bin

Output root:
- RTL/testbench/
"""

from __future__ import annotations

import argparse
import re
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


def q16_to_signed(v: int) -> int:
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def sat_q16(x: int) -> int:
    return int(max(MIN_SIGNED_16, min(MAX_SIGNED_16, x)))


def save_q16_lines(path: Path, values: np.ndarray) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    flat = values.astype(np.int32).reshape(-1)
    with path.open("w", encoding="utf-8") as f:
        for v in flat:
            f.write(to_hex16(int(v)) + "\n")
    print(f"  - {path}")


def compute_outproj_fixed_golden(y_gated_cm: np.ndarray, out_w: np.ndarray) -> np.ndarray:
    """RTL-consistent OutProj: sat(sum(x_q*w_q)>>>FRAC_BITS), x_q/w_q from Q3.12."""
    y_gated_cm = as_channel_major(y_gated_cm, channels=128)
    seq_len = y_gated_cm.shape[1]
    w = out_w.astype(np.float32).reshape(64, 128)
    w_q = np.vectorize(float_to_q16)(w).astype(np.int32)
    for i in range(64):
        for j in range(128):
            w_q[i, j] = q16_to_signed(int(w_q[i, j]))

    out = np.zeros((seq_len, 64), dtype=np.int32)
    for tok in range(seq_len):
        for row in range(64):
            acc = 0
            for ch in range(128):
                x_q = q16_to_signed(float_to_q16(float(y_gated_cm[ch, tok])))
                acc += x_q * int(w_q[row, ch])
            out[tok, row] = sat_q16(acc >> FRAC_BITS)
    return out


def save_mem_file(path: Path, values: np.ndarray, count: int | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    flat = values.astype(np.float32).reshape(-1)
    if flat.size == 0:
        raise ValueError(f"Empty tensor for {path}")
    selected = flat if count is None else flat[:count]
    with path.open("w", encoding="utf-8") as f:
        for v in selected:
            f.write(to_hex16(float_to_q16(float(v))) + "\n")
    print(f"  - {path}")


def save_text_file(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    print(f"  - {path}")


def read_bin(path: Path) -> np.ndarray:
    return np.fromfile(path, dtype=np.float32)


def parse_prefix_number(path: Path) -> int:
    m = re.match(r"^(\d+)_", path.name)
    return int(m.group(1)) if m else -1


def find_latest_by_suffix(cpp_dir: Path, suffix: str) -> Path:
    candidates = sorted(cpp_dir.glob(f"*{suffix}"))
    if not candidates:
        raise FileNotFoundError(f"Missing cpp golden file suffix: {suffix}")
    return max(candidates, key=parse_prefix_number)


def load_txt_matrix(path: Path) -> np.ndarray:
    arr = np.loadtxt(path, dtype=np.float32)
    if arr.ndim == 1:
        arr = arr.reshape(1, -1)
    return arr


def load_cpp_matrix(cpp_dir: Path, suffix: str) -> np.ndarray:
    return load_txt_matrix(find_latest_by_suffix(cpp_dir, suffix))


def load_cpp_matrix_optional(cpp_dir: Path, suffix: str) -> np.ndarray | None:
    try:
        return load_cpp_matrix(cpp_dir, suffix)
    except FileNotFoundError:
        return None


def silu_np(x: np.ndarray) -> np.ndarray:
    return x / (1.0 + np.exp(-x))


def as_channel_major(arr: np.ndarray, channels: int = 128) -> np.ndarray:
    """Normalize (128, SEQ) or (SEQ, 128) to channel-major (128, SEQ)."""
    if arr.ndim != 2:
        raise ValueError(f"Expected 2-D array, got shape {arr.shape}")
    if arr.shape[0] == channels:
        return arr.astype(np.float32)
    if arr.shape[1] == channels:
        return arr.T.astype(np.float32)
    raise ValueError(f"Cannot map shape {arr.shape} to {channels} channels")


def load_xz_matrix(cpp_dir: Path) -> np.ndarray:
    xz = load_cpp_matrix_optional(cpp_dir, "_XZ_after_linear.txt")
    if xz is None:
        xz = load_cpp_matrix(cpp_dir, "_X_after_linear.txt")
    return xz


def load_z_branch_goldens(cpp_dir: Path) -> tuple[np.ndarray, np.ndarray]:
    """Return z_raw and silu(z) as (128, SEQ) channel-major float32."""
    z_before = load_cpp_matrix_optional(cpp_dir, "_Mixer_z_before_silu.txt")
    if z_before is None:
        xz = load_xz_matrix(cpp_dir)
        z_before = xz[:, 128:256]
        print("  ! Missing _Mixer_z_before_silu.txt, using X_after_linear z columns")
    z_before_cm = as_channel_major(z_before)

    silu_z = load_cpp_matrix_optional(cpp_dir, "_Mixer_Z_after_silu_golden.txt")
    if silu_z is None:
        print("  ! Missing _Mixer_Z_after_silu_golden.txt, falling back to numpy silu(z)")
        silu_z = silu_np(z_before_cm)
    else:
        print(f"  ✓ silu(z) from {find_latest_by_suffix(cpp_dir, '_Mixer_Z_after_silu_golden.txt').name}")
    silu_z_cm = as_channel_major(silu_z)
    return z_before_cm, silu_z_cm


def collect_h_state_trajectory(
    cpp_dir: Path,
    anchor_prefix: int | None = None,
) -> np.ndarray | None:
    files = sorted(cpp_dir.glob("*_Mixer_h_state_t*.txt"))
    if not files:
        return None

    best_per_timestep: dict[int, tuple[int, Path]] = {}
    pat = re.compile(r"_Mixer_h_state_t(\d+)\.txt$")

    for p in files:
        m = pat.search(p.name)
        if not m:
            continue
        prefix = parse_prefix_number(p)
        if anchor_prefix is not None and prefix != anchor_prefix:
            continue
        t = int(m.group(1))
        prev = best_per_timestep.get(t)
        if prev is None or prefix > prev[0]:
            best_per_timestep[t] = (prefix, p)

    if not best_per_timestep:
        return None

    ordered_ts = sorted(best_per_timestep.keys())
    states = []
    for t in ordered_ts:
        _, p = best_per_timestep[t]
        states.append(load_txt_matrix(p))  # (D_INNER, D_STATE)

    # (T, D_INNER, D_STATE)
    return np.stack(states, axis=0).astype(np.float32)


def export_rmsnorm(cpp_dir: Path, gv_dir: Path, out_root: Path) -> None:
    print("\n[test_RMSNorm]")
    out_dir = out_root / "test_RMSNorm"

    mamba_in = load_cpp_matrix(cpp_dir, "_MambaBlock_input.txt")       # (SEQ, 64)
    rms_out = load_cpp_matrix(cpp_dir, "_MambaBlock_after_norm.txt")    # (SEQ, 64)
    rms_w = read_bin(gv_dir / "rms_norm_weight.bin")

    save_mem_file(out_dir / "input.mem", mamba_in[0], 64)
    save_mem_file(out_dir / "weight.mem", rms_w, 64)
    save_mem_file(out_dir / "golden_output.mem", rms_out[0], 64)

    save_mem_file(out_dir / "input_full.mem", mamba_in)
    save_mem_file(out_dir / "golden_output_full.mem", rms_out)


def export_inprojection(cpp_dir: Path, gv_dir: Path, out_root: Path) -> None:
    print("\n[test_Inprojection]")
    out_dir = out_root / "test_Inprojection"

    rms_out = load_cpp_matrix(cpp_dir, "_MambaBlock_after_norm.txt")

    xz = load_cpp_matrix_optional(cpp_dir, "_XZ_after_linear.txt")
    if xz is None:
        xz = load_cpp_matrix(cpp_dir, "_X_after_linear.txt")

    w1 = read_bin(gv_dir / "in_proj1_weight.bin")
    w2 = read_bin(gv_dir / "in_proj2_weight.bin")

    save_mem_file(out_dir / "input.mem", rms_out[0], 64)
    save_mem_file(out_dir / "weight_1.mem", w1)
    save_mem_file(out_dir / "weight_2.mem", w2)
    save_mem_file(out_dir / "golden_output.mem", xz[0], 256)

    save_mem_file(out_dir / "input_full.mem", rms_out)
    save_mem_file(out_dir / "golden_output_full.mem", xz)


def export_conv1d_silu(cpp_dir: Path, gv_dir: Path, out_root: Path) -> None:
    print("\n[test_Conv1D&Silu]")
    out_dir = out_root / "test_Conv1D&Silu"

    x_before_conv = load_cpp_matrix(cpp_dir, "_Mixer_x_before_conv_silu.txt")    # (128, SEQ)
    conv_before_silu = load_cpp_matrix_optional(cpp_dir, "_Mixer_X_before_silu_after_conv.txt")
    if conv_before_silu is None:
        conv_before_silu = load_cpp_matrix(cpp_dir, "_Mixer_X_before_silu.txt")
    x_activated = load_cpp_matrix(cpp_dir, "_Mixer_x_activated.txt")              # (128, SEQ)

    w = read_bin(gv_dir / "conv1d_weight.bin")
    b = read_bin(gv_dir / "conv1d_bias.bin")

    w_lane = w.reshape(128, -1)[:, :4]
    w_lane_0_15 = w_lane[:16, :].reshape(-1)
    b_0_15 = b[:16]

    x_in_t0 = x_before_conv[:16, 0]
    conv_raw_t0 = conv_before_silu[:16, 0]
    silu_t0 = x_activated[:16, 0]

    save_mem_file(out_dir / "x_in.mem", x_in_t0, 16)
    save_mem_file(out_dir / "weights.mem", w_lane_0_15, 64)
    save_mem_file(out_dir / "bias.mem", b_0_15, 16)
    save_mem_file(out_dir / "conv_before_silu_golden.mem", conv_raw_t0, 16)
    save_mem_file(out_dir / "golden_output.mem", silu_t0, 16)

    save_mem_file(out_dir / "x_before_conv_full.mem", x_before_conv)
    save_mem_file(out_dir / "conv_before_silu_full.mem", conv_before_silu)
    save_mem_file(out_dir / "silu_golden_full.mem", x_activated)

    z_before_cm, silu_z_cm = load_z_branch_goldens(cpp_dir)
    save_mem_file(out_dir / "z_before_silu_full.mem", z_before_cm)
    save_mem_file(out_dir / "silu_z_golden_full.mem", silu_z_cm)

    save_text_file(
        out_dir / "compare_tolerance.txt",
        "abs_error_lsb=16\nabs_error_float=0.00390625\n"
    )
    save_text_file(
        out_dir / "compare_tolerance_chain.txt",
        "abs_error_lsb=48\nz_silu_lsb=48\nabs_error_float=0.01171875\n"
    )


def export_scancore(cpp_dir: Path, gv_dir: Path, out_root: Path) -> None:
    print("\n[test_Scancore]")
    out_dir = out_root / "test_Scancore"

    # Important: scan input uses delta BEFORE softplus for new pipeline test.
    delta_before = load_cpp_matrix(cpp_dir, "_Mixer_delta_before_softplus.txt")  # (128, SEQ)
    delta_final = load_cpp_matrix(cpp_dir, "_Mixer_delta_final.txt")              # (128, SEQ)
    x_activated = load_cpp_matrix(cpp_dir, "_Mixer_x_activated.txt")               # (128, SEQ)
    b_raw = load_cpp_matrix(cpp_dir, "_Mixer_B_raw.txt")                           # (SEQ, 16)
    c_raw = load_cpp_matrix(cpp_dir, "_Mixer_C_raw.txt")                           # (SEQ, 16)
    scan_out = load_cpp_matrix(cpp_dir, "_Mixer_scan_output_raw.txt")              # (128, SEQ)

    a_log = read_bin(gv_dir / "A_log.bin")
    d_vec = read_bin(gv_dir / "D.bin")
    a_vec = -np.exp(a_log.reshape(128, 16))

    seq_len = delta_before.shape[1] if delta_before.ndim == 2 else delta_before.shape[0]
    anchor_prefix = parse_prefix_number(
        find_latest_by_suffix(cpp_dir, "_Mixer_delta_final.txt")
    )
    h_state = collect_h_state_trajectory(cpp_dir, anchor_prefix=anchor_prefix)
    if h_state is None or h_state.shape[0] < seq_len:
        h_state_full = collect_h_state_trajectory(cpp_dir)
        if h_state_full is not None and (
            h_state is None or h_state_full.shape[0] > h_state.shape[0]
        ):
            h_state = h_state_full
            print(
                f"  ! h_state: using full trajectory ({h_state.shape[0]} tokens)"
                f" — anchor prefix {anchor_prefix} had too few steps"
            )
    if h_state is None:
        print("  ! h_state: no trajectory files found")

    z_before_cm, silu_z_cm = load_z_branch_goldens(cpp_dir)

    y_pre_cpp = load_cpp_matrix_optional(cpp_dir, "_Mixer_y_pre.txt")
    y_gated_cpp = as_channel_major(
        load_cpp_matrix(cpp_dir, "_Mixer_y_gated.txt"), channels=128
    )
    print("  ✓ golden_y_gated.mem from cpp float (y_pre * silu(z), includes D*x)")

    save_mem_file(out_dir / "delta_before_softplus.mem", delta_before)
    save_mem_file(out_dir / "delta_final.mem", delta_final)
    save_mem_file(out_dir / "x_activated.mem", x_activated)
    save_mem_file(out_dir / "A_vec.mem", a_vec)
    save_mem_file(out_dir / "B_vec.mem", b_raw)
    save_mem_file(out_dir / "C_vec.mem", c_raw)
    save_mem_file(out_dir / "D_vec.mem", d_vec)
    save_mem_file(out_dir / "golden_scan_output.mem", scan_out)
    save_mem_file(out_dir / "golden_y_gated.mem", y_gated_cpp)
    save_mem_file(out_dir / "silu_z_golden.mem", silu_z_cm)
    if y_pre_cpp is not None:
        save_mem_file(out_dir / "golden_y_pre.mem", y_pre_cpp)
        print("  ✓ golden_y_pre.mem from cpp (C*h + D*x)")

    save_text_file(
        out_dir / "compare_tolerance.txt",
        "abs_error_lsb=48\n"
        "y_gated_abs_error_lsb=192\n"
        "abs_error_float=0.01171875\n",
    )

    # Token-level debug slices (t=0) for quick bring-up.
    save_mem_file(out_dir / "delta_before_softplus_t0.mem", delta_before[:, 0], 128)
    save_mem_file(out_dir / "delta_final_t0.mem", delta_final[:, 0], 128)
    save_mem_file(out_dir / "x_activated_t0.mem", x_activated[:, 0], 128)
    save_mem_file(out_dir / "B_vec_t0.mem", b_raw[0], 16)
    save_mem_file(out_dir / "C_vec_t0.mem", c_raw[0], 16)

    if h_state is not None:
        save_mem_file(out_dir / "h_state.mem", h_state)
        save_mem_file(out_dir / "h_state_t0.mem", h_state[0])
        save_mem_file(out_dir / "h_state_tlast.mem", h_state[-1])


def export_outprojection(cpp_dir: Path, gv_dir: Path, out_root: Path) -> None:
    print("\n[test_Outprojection]")
    out_dir = out_root / "test_Outprojection"

    y_gated = load_cpp_matrix(cpp_dir, "_Mixer_y_gated.txt")          # (128, SEQ) or (SEQ, 128)
    out_w = read_bin(gv_dir / "out_proj_weight.bin")
    y_gated_cm = as_channel_major(y_gated, channels=128)
    out_fixed = compute_outproj_fixed_golden(y_gated_cm, out_w)

    save_mem_file(out_dir / "input.mem", y_gated_cm[:, 0], 128)
    save_mem_file(out_dir / "weight.mem", out_w)
    save_q16_lines(out_dir / "golden_output.mem", out_fixed[0])

    save_mem_file(out_dir / "input_full.mem", y_gated_cm)
    save_q16_lines(out_dir / "golden_output_full.mem", out_fixed)
    print("  ✓ golden_output*.mem = RTL fixed-point (saturated y_gated input)")

    save_text_file(
        out_dir / "compare_tolerance.txt",
        "abs_error_lsb=0\nabs_error_float=0.0\n",
    )


def export_full_mamba_branch(cpp_dir: Path, gv_dir: Path, out_root: Path) -> None:
    print("\n[test_Full_mamba_Branch]")
    out_dir = out_root / "test_Full_mamba_Branch"

    mamba_in = load_cpp_matrix(cpp_dir, "_MambaBlock_input.txt")
    rms_out = load_cpp_matrix(cpp_dir, "_MambaBlock_after_norm.txt")
    x_before_conv = load_cpp_matrix(cpp_dir, "_Mixer_x_before_conv_silu.txt")
    x_activated = load_cpp_matrix(cpp_dir, "_Mixer_x_activated.txt")
    delta_before = load_cpp_matrix(cpp_dir, "_Mixer_delta_before_softplus.txt")
    delta_final = load_cpp_matrix(cpp_dir, "_Mixer_delta_final.txt")
    b_raw = load_cpp_matrix(cpp_dir, "_Mixer_B_raw.txt")
    c_raw = load_cpp_matrix(cpp_dir, "_Mixer_C_raw.txt")
    scan_out = load_cpp_matrix(cpp_dir, "_Mixer_scan_output_raw.txt")
    y_gated = load_cpp_matrix(cpp_dir, "_Mixer_y_gated.txt")
    y_gated_cm = as_channel_major(y_gated, channels=128)
    out_w = read_bin(gv_dir / "out_proj_weight.bin")
    out_fixed = compute_outproj_fixed_golden(y_gated_cm, out_w)
    branch_out = load_cpp_matrix(cpp_dir, "_ITMBlock_mamba_branch_out_final.txt")

    z_before_cm, silu_z_cm = load_z_branch_goldens(cpp_dir)
    gate = silu_z_cm

    rms_w = read_bin(gv_dir / "rms_norm_weight.bin")
    inproj_w = read_bin(gv_dir / "in_proj1_weight.bin")
    conv_w = read_bin(gv_dir / "conv1d_weight.bin")
    conv_b = read_bin(gv_dir / "conv1d_bias.bin")
    outproj_w = read_bin(gv_dir / "out_proj_weight.bin")
    a_log = read_bin(gv_dir / "A_log.bin")
    d_vec = read_bin(gv_dir / "D.bin")
    a_vec = -np.exp(a_log.reshape(128, 16))

    h_state = collect_h_state_trajectory(cpp_dir)

    # Inputs for full-branch testbench
    save_mem_file(out_dir / "mamba_input.mem", mamba_in)
    save_mem_file(out_dir / "rms_weight.mem", rms_w)
    save_mem_file(out_dir / "inproj_weight.mem", inproj_w)
    save_mem_file(out_dir / "conv_weight.mem", conv_w)
    save_mem_file(out_dir / "conv_bias.mem", conv_b)
    save_mem_file(out_dir / "outproj_weight.mem", outproj_w)

    # Important: feed scan with delta BEFORE softplus in new pipeline design.
    save_mem_file(out_dir / "delta.mem", delta_before)
    save_mem_file(out_dir / "delta_final.mem", delta_final)
    save_mem_file(out_dir / "B_raw.mem", b_raw)
    save_mem_file(out_dir / "C_raw.mem", c_raw)
    save_mem_file(out_dir / "A_vec.mem", a_vec)
    save_mem_file(out_dir / "D_vec.mem", d_vec)
    save_mem_file(out_dir / "gate.mem", gate)
    save_mem_file(out_dir / "z_before_silu_full.mem", z_before_cm)
    save_mem_file(out_dir / "silu_z_golden_full.mem", silu_z_cm)

    # Golden checkpoints for stage-by-stage debug.
    save_mem_file(out_dir / "golden_rms.mem", rms_out)
    save_mem_file(out_dir / "golden_inproj.mem", x_before_conv)
    save_mem_file(out_dir / "golden_silu.mem", x_activated)
    save_mem_file(out_dir / "golden_scan.mem", scan_out)
    save_mem_file(out_dir / "golden_ygated.mem", y_gated_cm)
    save_q16_lines(out_dir / "golden_outproj.mem", out_fixed)
    save_mem_file(out_dir / "golden_mamba_branch.mem", branch_out)

    if h_state is not None:
        save_mem_file(out_dir / "h_state.mem", h_state)
        save_mem_file(out_dir / "h_state_t0.mem", h_state[0])
        save_mem_file(out_dir / "h_state_tlast.mem", h_state[-1])

    save_text_file(
        out_dir / "activation_tolerance.txt",
        "abs_error_lsb=8\nabs_error_float=0.001953125\n"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--mode",
        type=str,
        default="full",
        choices=[
            "full",
            "rmsnorm",
            "inprojection",
            "conv1d_silu",
            "scancore",
            "outprojection",
            "full_mamba_branch",
        ],
        help="Export one test folder or all folders (full).",
    )
    args = parser.parse_args()

    k_root = Path(__file__).resolve().parents[1]
    cpp_dir = k_root / "ITMN" / "cpp_golden_files"
    gv_dir = k_root / "ITMN" / "golden_vectors"
    out_root = k_root / "RTL" / "testbench"

    print("=" * 70)
    print("EXPORT RTL INITIAL MEM (MIXER-ONLY, PIPELINE-READY)")
    print("=" * 70)
    print(f"KLTN_ROOT: {k_root}")

    if not cpp_dir.exists():
        raise FileNotFoundError(f"Missing folder: {cpp_dir}")
    if not gv_dir.exists():
        raise FileNotFoundError(f"Missing folder: {gv_dir}")

    mode_map = {
        "rmsnorm": export_rmsnorm,
        "inprojection": export_inprojection,
        "conv1d_silu": export_conv1d_silu,
        "scancore": export_scancore,
        "outprojection": export_outprojection,
        "full_mamba_branch": export_full_mamba_branch,
    }

    if args.mode == "full":
        export_rmsnorm(cpp_dir, gv_dir, out_root)
        export_inprojection(cpp_dir, gv_dir, out_root)
        export_conv1d_silu(cpp_dir, gv_dir, out_root)
        export_scancore(cpp_dir, gv_dir, out_root)
        export_outprojection(cpp_dir, gv_dir, out_root)
        export_full_mamba_branch(cpp_dir, gv_dir, out_root)
    else:
        mode_map[args.mode](cpp_dir, gv_dir, out_root)

    print("\n" + "=" * 70)
    print(f"DONE: Generated testbench .mem vectors (mode={args.mode}) in RTL/testbench")
    print("=" * 70)


if __name__ == "__main__":
    main()
