#!/usr/bin/env python3
"""Generate stimulus .mem files and golden_output.mem for tb_itm_block; compare after xsim."""
from __future__ import annotations

import argparse
import os
from pathlib import Path

FRAC_BITS = 12
ONE_FIXED = 0x1000
MAX_POS = 32767
MIN_NEG = -32768

SILU_ROM = Path(__file__).resolve().parent.parent.parent / "code_initial" / "silu_pwl_coeffs.mem"


def to_signed16(v: int) -> int:
    v &= 0xFFFF
    return v - 0x10000 if (v & 0x8000) else v


def to_hex16_signed(v: int) -> str:
    return f"{(v & 0xFFFF):04x}"


def sat_temp(tr: int) -> int:
    if tr > MAX_POS:
        return MAX_POS
    if tr < MIN_NEG:
        return MIN_NEG
    return tr


def mul_shifted(a: int, b: int) -> int:
    mr = (to_signed16(a) * to_signed16(b)) & 0xFFFFFFFF
    if mr >= 0x80000000:
        mr -= 0x100000000
    return mr >> FRAC_BITS


def load_silu_rom(path: Path) -> list[int]:
    rom: list[int] = []
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            s = line.strip()
            if not s:
                continue
            rom.append(int(s, 16) & 0xFFFFFFFF)
    return rom


def silu_pwl_model(x_in: int, rom: list[int]) -> int:
    x = to_signed16(x_in)
    addr = (x_in & 0xFFFF) >> 10
    addr &= 0x3F
    word = rom[addr]
    slope = to_signed16((word >> 16) & 0xFFFF)
    intercept = to_signed16(word & 0xFFFF)
    prod = slope * x
    mr = prod & 0xFFFFFFFF
    if mr >= 0x80000000:
        mr -= 0x100000000
    res = (mr >> FRAC_BITS) + intercept
    return sat_temp(res)


def conv_lane_acc(
    x: int, weights: list[int], bias: int, shift0: int, shift1: int, shift2: int
) -> int:
    # First input sample: shift regs zero (matches Conv1D after start).
    acc = sat_temp(mul_shifted(bias, ONE_FIXED))
    acc = sat_temp(acc + mul_shifted(x, weights[0]))
    acc = sat_temp(acc + mul_shifted(shift0, weights[1]))
    acc = sat_temp(acc + mul_shifted(shift1, weights[2]))
    acc = sat_temp(acc + mul_shifted(shift2, weights[3]))
    return acc & 0xFFFF


def merge_add_relu_scan_sat(incept: int, scan_y: int) -> int:
    a = to_signed16(incept)
    b = to_signed16(scan_y)
    ru = a
    rv = 0 if b < 0 else b
    s = ru + rv
    return sat_temp(s) & 0xFFFF


def write_mem16(path: Path, values: list[int]) -> None:
    with path.open("w", encoding="utf-8") as f:
        for v in values:
            f.write(to_hex16_signed(v) + "\n")


def read_hex_lines(path: Path) -> list[int]:
    out: list[int] = []
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            s = line.strip().lower()
            if not s or "x" in s:
                continue
            out.append(int(s, 16) & 0xFFFF)
    return out


def golden_for_case(case: str, silu_rom: list[int]) -> list[int]:
    n = 16
    if case == "zero":
        feat = [0] * n
        bias = [0] * n
        weights = [0] * (n * 4)
        scan_y = 0
    elif case == "bias_lane0":
        feat = [0] * n
        bias = [0] * n
        bias[0] = ONE_FIXED
        weights = [0] * (n * 4)
        scan_y = 0
    else:
        raise ValueError(f"Unknown case: {case}")

    out: list[int] = []
    for lane in range(n):
        wbase = lane * 4
        w = weights[wbase : wbase + 4]
        acc = conv_lane_acc(feat[lane], w, bias[lane], 0, 0, 0)
        incept = silu_pwl_model(acc, silu_rom)
        out.append(merge_add_relu_scan_sat(incept, scan_y))
    return out


def generate(case: str, silu_rom: list[int]) -> None:
    n = 16
    
    # Check if real data files exist (from extraction)
    real_data_available = Path("feat_in.mem").exists() and Path("golden_output.mem").exists()
    
    if real_data_available:
        # Use extracted real model data - don't overwrite .mem files
        pass
    else:
        raise FileNotFoundError("Real mem files are missing. Run extract_real_rtl_golden.py first.")


def compare() -> int:
    rtl = read_hex_lines(Path("rtl_output.mem"))
    golden = read_hex_lines(Path("golden_output.mem"))
    n = min(len(rtl), len(golden))
    mismatches = 0
    for i in range(n):
        if rtl[i] != golden[i]:
            mismatches += 1
            if mismatches <= 12:
                print(
                    f"idx={i} exp={golden[i]:04x} got={rtl[i]:04x} "
                    f"abs_err={abs(to_signed16(golden[i]) - to_signed16(rtl[i]))}"
                )
    print(f"Compared: {n}")
    print(f"Mismatches: {mismatches}")
    return 0 if mismatches == 0 else 1


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--generate-only", action="store_true")
    parser.add_argument("--compare-only", action="store_true")
    args = parser.parse_args()

    case = os.environ.get("ITM_TB_CASE", "zero")
    silu_path = Path(os.environ.get("SILU_ROM_PATH", str(SILU_ROM)))
    silu_rom = load_silu_rom(silu_path)

    if args.compare_only:
        raise SystemExit(compare())

    # Check if using real data
    real_data_available = Path("feat_in.mem").exists() and Path("golden_output.mem").exists()
    
    generate(case, silu_rom)
    if args.generate_only:
        if real_data_available:
            print(f"✓ Using real model data (extracted from cpp_golden_files)")
            print(f"✓ All real data files found\n")
        return

    if Path("rtl_output.mem").exists():
        raise SystemExit(compare())
    print("Generated inputs; run xsim then pass --compare-only")


if __name__ == "__main__":
    main()
