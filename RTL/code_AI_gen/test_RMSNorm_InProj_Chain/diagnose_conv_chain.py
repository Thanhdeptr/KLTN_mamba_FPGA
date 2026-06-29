#!/usr/bin/env python3
"""Isolate Conv chain errors: indexing, InProj input, pre-SiLU, post-SiLU."""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
KLTN = ROOT.parents[2]
CONV_DIR = KLTN / "RTL" / "testbench" / "test_Conv1D&Silu"
INPROJ_CHAIN = ROOT / "rtl_output_chain_continuous.mem"
CONV_X_CHAIN = ROOT / "rtl_output_conv_x_chain.mem"
CONV_Z_CHAIN = ROOT / "rtl_output_conv_z_chain.mem"
SILU_ROM = KLTN / "RTL" / "code_initial" / "silu_pwl_coeffs.mem"
FB_BENCH = KLTN / "RTL" / "testbench" / "test_Full_mamba_Branch"

SEQ = 1000
LANES = 16
FRAMES = 8
D_INNER = 128
TOL = 48
TOL_Z = 48

_tol_file = CONV_DIR / "compare_tolerance_chain.txt"
if _tol_file.is_file():
    for _line in _tol_file.read_text().splitlines():
        if _line.startswith("abs_error_lsb="):
            TOL = int(_line.split("=", 1)[1].strip())
        if _line.startswith("z_silu_lsb="):
            TOL_Z = int(_line.split("=", 1)[1].strip())


def si(h: str) -> int | None:
    if not h or "x" in h.lower():
        return None
    v = int(h, 16)
    return v - 0x10000 if v & 0x8000 else v


def load_mem(path: Path) -> list[int]:
    out: list[int] = []
    with path.open() as f:
        for line in f:
            s = line.strip()
            if s:
                out.append(si(s))  # type: ignore[arg-type]
    return out


def load_silu_rom(path: Path) -> list[tuple[int, int]]:
    rom: list[tuple[int, int]] = []
    for line in path.read_text().split():
        w = int(line, 16)
        slope = w >> 16
        if slope >= 0x8000:
            slope -= 0x10000
        intercept = w & 0xFFFF
        if intercept >= 0x8000:
            intercept -= 0x10000
        rom.append((slope, intercept))
    return rom


def sat16(v: int) -> int:
    return max(-32768, min(32767, int(v)))


def mul_shift(a: int, b: int) -> int:
    return (a * b) >> 12


def silu_pwl(acc: int, rom: list[tuple[int, int]]) -> int:
    addr = (acc >> 10) & 0x3F
    slope, intercept = rom[addr]
    prod = slope * acc
    if prod >= 0x80000000:
        prod -= 0x100000000
    return sat16((prod >> 12) + intercept)


def xbc_index(ch: int, t: int) -> int:
    return ch * SEQ + t


def rtl_x_index(t: int, fg: int, lane: int) -> int:
    """Layout in rtl_output_conv_x_chain.mem: (token, frame_group, lane)."""
    return (t * FRAMES + fg) * LANES + lane


def rtl_x_group0_index(t: int, ch: int) -> int:
    """Group0 (channels 0..15) first X frame per token."""
    return rtl_x_index(t, 0, ch)


def rtl_z_index(t: int, fg: int, lane: int) -> int:
    return (t * FRAMES + fg) * LANES + lane


def inproj_group0_index(t: int, ch: int) -> int:
  # rtl_output_chain_continuous: per frame 256 = 16 groups x 16 lanes
    return t * 256 + ch


def conv_pre_silu_token(
    x_hist: list[list[int]],
    t: int,
    weights: list[int],
    bias: list[int],
) -> list[int]:
    """RTL-equivalent depthwise conv pre-SiLU for 16 lanes at token t."""
    out: list[int] = []
    for ch in range(LANES):
        acc = sat16(mul_shift(bias[ch], 0x1000))
        for k in range(4):
            xt = t - k
            if xt < 0:
                xv = 0
            else:
                xv = x_hist[xt][ch]
            # Match RTL: w[3-k] pairs with x[t-k] (PyTorch depthwise conv1d)
            acc = sat16(acc + mul_shift(xv, weights[ch * 4 + (3 - k)]))
        out.append(acc)
    return out


def main() -> int:
    n_tokens = int(sys.argv[1]) if len(sys.argv) > 1 else 10

    need_group0 = n_tokens * LANES
    need_inproj = n_tokens * 256
    need_x = n_tokens * FRAMES * LANES
    need_z = need_x

    xbc = load_mem(CONV_DIR / "x_before_conv_full.mem")
    gold_silu = load_mem(CONV_DIR / "silu_golden_full.mem")
    gold_pre = load_mem(CONV_DIR / "conv_before_silu_full.mem")
    weights = load_mem(CONV_DIR / "weights.mem")
    bias = load_mem(CONV_DIR / "bias.mem")

    if not CONV_X_CHAIN.is_file():
        print(f"ERROR: missing {CONV_X_CHAIN} — run ./run_conv_chain.sh {n_tokens} first")
        return 1
    if not INPROJ_CHAIN.is_file():
        print(f"ERROR: missing {INPROJ_CHAIN} — run ./run_chain_continuous.sh {n_tokens} first")
        return 1

    rtl_x_raw = load_mem(CONV_X_CHAIN)
    if len(rtl_x_raw) < need_x:
        print(f"ERROR: rtl_x has {len(rtl_x_raw)} lines, need {need_x} for N={n_tokens}")
        return 1

    rtl_silu = [
        rtl_x_raw[rtl_x_group0_index(t, ch)]
        for t in range(n_tokens)
        for ch in range(LANES)
    ]
    inproj_out = load_mem(INPROJ_CHAIN)[:need_inproj]
    rom = load_silu_rom(SILU_ROM)

    print("=" * 72)
    print(f"Conv chain diagnosis (N={n_tokens}, tol={TOL} LSB)")
    print("=" * 72)

    # --- Stage 0: wrong vs correct golden indexing demo ---
    wrong_bad = sum(
        1
        for i in range(min(16, len(rtl_silu)))
        if rtl_silu[i] is not None
        and gold_silu[i] is not None
        and abs(rtl_silu[i] - gold_silu[i]) > TOL
    )
    right_bad_t0 = sum(
        1
        for ch in range(LANES)
        if abs(rtl_silu[ch] - gold_silu[xbc_index(ch, 0)]) > TOL
    )
    print("\n[Stage 0] Golden indexing")
    print(f"  Wrong flat gold[i] vs rtl[i] (t=0):  {wrong_bad}/16 bad")
    print(f"  Correct gold[ch*SEQ+t] vs rtl[t*16+ch] t=0: {right_bad_t0}/16 bad")

    # --- Stage 1: InProj group0 vs x_before_conv ---
    inproj_bad_per_t: list[int] = []
    max_inproj_diff = 0
    for t in range(n_tokens):
        bad = 0
        for ch in range(LANES):
            ip = inproj_out[inproj_group0_index(t, ch)]
            xg = gold_x = xbc[xbc_index(ch, t)]
            d = abs(ip - xg)
            max_inproj_diff = max(max_inproj_diff, d)
            if d > TOL:
                bad += 1
        inproj_bad_per_t.append(bad)
    print("\n[Stage 1] InProj group0 x (chain capture) vs x_before_conv_full")
    print(f"  Max |diff| any lane: {max_inproj_diff} LSB")
    for t in range(min(n_tokens, 5)):
        print(f"  token {t}: {inproj_bad_per_t[t]}/{LANES} lanes > tol")
    if n_tokens > 5:
        print(f"  ... token {n_tokens-1}: {inproj_bad_per_t[-1]}/{LANES} lanes > tol")

    # Build per-token input history from x_before_conv and from inproj
    xbc_hist = [[xbc[xbc_index(ch, t)] for ch in range(LANES)] for t in range(n_tokens)]
    ip_hist = [
        [inproj_out[inproj_group0_index(t, ch)] for ch in range(LANES)]
        for t in range(n_tokens)
    ]

    # --- Stage 2: pre-SiLU ---
    print("\n[Stage 2] Pre-SiLU conv (before activation)")
    pre_rtl_from_ip: list[int] = []
    pre_rtl_from_xbc: list[int] = []
    for t in range(n_tokens):
        pre_rtl_from_ip.extend(conv_pre_silu_token(ip_hist, t, weights, bias))
        pre_rtl_from_xbc.extend(conv_pre_silu_token(xbc_hist, t, weights, bias))

    pre_gold = [gold_pre[xbc_index(ch, t)] for t in range(n_tokens) for ch in range(LANES)]

    def count_bad(a: list[int], b: list[int]) -> int:
        n = min(len(a), len(b))
        return sum(1 for i in range(n) if abs(a[i] - b[i]) > TOL)

    bad_pre_gold_vs_xbc = count_bad(pre_rtl_from_xbc, pre_gold)
    bad_pre_gold_vs_ip = count_bad(pre_rtl_from_ip, pre_gold)
    bad_pre_ip_vs_xbc = count_bad(pre_rtl_from_ip, pre_rtl_from_xbc)
    bad_pre_rtl_silu_back = 0
    for i, acc in enumerate(pre_rtl_from_ip):
        if abs(silu_pwl(acc, rom) - rtl_silu[i]) > 8:
            bad_pre_rtl_silu_back += 1

    print(f"  Python conv(x_before_conv) vs golden pre-SiLU: {bad_pre_gold_vs_xbc}/{need_group0} bad")
    print(f"  Python conv(inproj chain)  vs golden pre-SiLU: {bad_pre_gold_vs_ip}/{need_group0} bad")
    print(f"  Python conv(inproj) vs conv(x_before_conv):   {bad_pre_ip_vs_xbc}/{need_group0} bad")
    print(f"  silu_pwl(conv(inproj)) vs rtl silu output:    {bad_pre_rtl_silu_back}/{need_group0} bad")

    for t in range(min(3, n_tokens)):
        print(f"  token {t} pre-SiLU sample ch0-3:")
        for ch in range(4):
            i = t * LANES + ch
            print(
                f"    ch{ch}: gold={pre_gold[i]:6d} "
                f"xbc_model={pre_rtl_from_xbc[i]:6d} "
                f"inproj_model={pre_rtl_from_ip[i]:6d} "
                f"rtl_silu_in={pre_rtl_from_ip[i]:6d}"
            )

    # --- Stage 3: post-SiLU group0 + full 128ch ---
    print("\n[Stage 3] Post-SiLU X (group0, fg=0)")
    silu_bad_per_t: list[int] = []
    for t in range(n_tokens):
        bad = 0
        for ch in range(LANES):
            i = t * LANES + ch
            g = gold_silu[xbc_index(ch, t)]
            if abs(rtl_silu[i] - g) > TOL:
                bad += 1
        silu_bad_per_t.append(bad)
    for t in range(min(n_tokens, 6)):
        print(f"  token {t}: {silu_bad_per_t[t]}/{LANES} lanes > tol")
    if n_tokens > 6:
        print(f"  ... token {n_tokens-1}: {silu_bad_per_t[-1]}/{LANES} lanes > tol")

    print("\n[Stage 4] Post-SiLU X all 128ch (8 frames/token)")
    bad_x_all = max_x = 0
    for t in range(n_tokens):
        for fg in range(FRAMES):
            for lane in range(LANES):
                ch = fg * LANES + lane
                ri = rtl_x_index(t, fg, lane)
                gi = xbc_index(ch, t)
                d = abs(rtl_x_raw[ri] - gold_silu[gi])
                max_x = max(max_x, d)
                if d > TOL:
                    bad_x_all += 1
    print(f"  bad={bad_x_all}/{need_x} max|diff|={max_x} tol={TOL}")

    if CONV_Z_CHAIN.is_file():
        gold_z_path = FB_BENCH / "silu_z_golden_full.mem"
        if not gold_z_path.is_file():
            gold_z_path = FB_BENCH / "gate.mem"
        gold_z = load_mem(gold_z_path)
        rtl_z_raw = load_mem(CONV_Z_CHAIN)
        if len(rtl_z_raw) >= need_z and len(gold_z) >= SEQ * D_INNER:
            print(f"\n[Stage 5] Post-SiLU Z vs {gold_z_path.name}")
            bad_z = max_z = 0
            for t in range(n_tokens):
                for fg in range(FRAMES):
                    for lane in range(LANES):
                        ch = fg * LANES + lane
                        ri = rtl_z_index(t, fg, lane)
                        gi = ch * SEQ + t
                        d = abs(rtl_z_raw[ri] - gold_z[gi])
                        max_z = max(max_z, d)
                        if d > TOL_Z:
                            bad_z += 1
            print(f"  bad={bad_z}/{need_z} max|diff|={max_z} tol={TOL_Z}")
        else:
            print(f"\n[Stage 5] Skipped Z: rtl_z={len(rtl_z_raw)} gold_z={len(gold_z)}")

    # --- Root cause summary ---
    print("\n" + "=" * 72)
    print("ROOT CAUSE SUMMARY")
    print("=" * 72)

    if wrong_bad > right_bad_t0 + 4:
        print("- Compare script flat indexing inflates apparent SiLU error (not RTL bug).")

    if bad_pre_rtl_silu_back == 0:
        print("- RTL SiLU output matches silu_pwl(conv(inproj)) exactly -> Conv+SiLU RTL OK.")
    else:
        print(f"- RTL SiLU differs from model in {bad_pre_rtl_silu_back} samples -> check capture timing.")

    if max_inproj_diff <= 32 and sum(inproj_bad_per_t) == 0:
        print("- InProj group0 matches x_before_conv within 32 LSB all lanes.")
    elif max_inproj_diff <= TOL:
        print(f"- InProj vs x_before_conv: small drift (max {max_inproj_diff} LSB), minor contributor.")
    else:
        print(f"- InProj vs x_before_conv: significant (max {max_inproj_diff} LSB) -> primary input error.")

    if bad_pre_gold_vs_xbc > bad_pre_ip_vs_xbc:
        print(
            "- Golden pre-SiLU disagrees with conv(x_before_conv) more than inproj drift "
            "-> golden/model mem likely inconsistent with exported x_before_conv/weights."
        )
    elif bad_pre_ip_vs_xbc > 0:
        print("- InProj input drift propagates to pre-SiLU (expected).")

    if silu_bad_per_t[0] <= 4 and n_tokens > 1 and silu_bad_per_t[1] > silu_bad_per_t[0]:
        print("- Error grows after token 0 -> conv history / per-token input alignment dominates.")

    print("=" * 72)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
