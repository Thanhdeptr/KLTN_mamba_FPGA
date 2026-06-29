#!/usr/bin/env bash
# Unit test: Conv1D_Layer vs real PyTorch-exported vectors (test_Conv1D&Silu).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
RTL_DIR="$(cd "$ROOT/../../code_initial" && pwd)"
BENCH_DIR="$(cd "$ROOT/../../testbench/test_Conv1D&Silu" && pwd)"

echo "[Run] Conv1D_Layer unit test (real model mem, 8-PE TMUX)"
cd "$ROOT"
rm -rf xsim.dir .Xil xsim_conv1d.log 2>/dev/null || true

ln -sf "$RTL_DIR/silu_pwl_coeffs.mem" silu_pwl_coeffs.mem
ln -sf "$BENCH_DIR/x_in.mem" x_in.mem
ln -sf "$BENCH_DIR/bias.mem" bias.mem
ln -sf "$BENCH_DIR/weights.mem" weights.mem
ln -sf "$BENCH_DIR/golden_output.mem" golden_silu.mem
ln -sf "$BENCH_DIR/conv_before_silu_golden.mem" golden_pre_silu.mem
ln -sf "$BENCH_DIR/compare_tolerance.txt" compare_tolerance.txt

/tools/Xilinx/2025.1/Vivado/bin/xvlog --sv \
  "$RTL_DIR/_parameter.v" \
  "$RTL_DIR/Conv1D_MAC.v" \
  "$RTL_DIR/SiLU_Unit_PWL.v" \
  "$RTL_DIR/SiLU_Unit.v" \
  "$RTL_DIR/Conv1D_Layer.v" \
  tb_conv1d_layer.v 2>&1 | tail -12

/tools/Xilinx/2025.1/Vivado/bin/xelab --relax tb_conv1d_layer \
  -s tb_conv1d_sim 2>&1 | tail -6

/tools/Xilinx/2025.1/Vivado/bin/xsim tb_conv1d_sim -runall 2>&1 | tee xsim_conv1d.log | tail -30

python3 << PY
from pathlib import Path

ROOT = Path("$ROOT")
TOL = 8
tol_file = ROOT / "compare_tolerance.txt"
if tol_file.is_file():
    for line in tol_file.read_text().splitlines():
        if line.startswith("abs_error_lsb="):
            TOL = int(line.split("=", 1)[1].strip())

def si(h):
    if not h or "x" in h.lower():
        return None
    v = int(h, 16)
    return v - 0x10000 if v & 0x8000 else v

def readp(p):
    o = []
    with open(p) as f:
        for line in f:
            s = line.strip()
            if s:
                o.append(s)
    return o

def compare(name, rtl_path, gold_path, tol):
    rtl = readp(rtl_path)
    gold = readp(gold_path)
    n = min(len(rtl), len(gold), 16)
    bad = 0
    print(f"\n[{name}] tol>{tol} LSB")
    for i in range(n):
        rv, gv = si(rtl[i]), si(gold[i])
        if rv is None or gv is None:
            bad += 1
            print(f"  lane {i}: invalid hex")
            continue
        d = rv - gv
        if abs(d) > tol:
            bad += 1
            print(f"  lane {i}: rtl={rv:6d} gold={gv:6d} diff={d:6d}")
    print(f"  mismatches: {bad}/{n}")
    return bad

bad_pre = compare(
    "Pre-SiLU conv",
    ROOT / "rtl_pre_silu.mem",
    ROOT / "golden_pre_silu.mem",
    TOL,
)
bad_silu = compare(
    "Post-SiLU",
    ROOT / "rtl_output.mem",
    ROOT / "golden_silu.mem",
    TOL,
)

total = bad_pre + bad_silu
print(f"\n[Summary] total mismatches: {total} (pre={bad_pre}, silu={bad_silu}), tol={TOL}")
import sys
sys.exit(1 if total else 0)
PY

echo "Done. Log: $ROOT/xsim_conv1d.log"
