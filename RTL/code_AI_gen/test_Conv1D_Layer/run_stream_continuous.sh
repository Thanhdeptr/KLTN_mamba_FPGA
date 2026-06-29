#!/usr/bin/env bash
# Continuous stream unit test: 8 x + 8 z frames per token.
set -euo pipefail

N="${1:-1}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
RTL_DIR="$(cd "$ROOT/../../code_initial" && pwd)"
BENCH_X="$(cd "$ROOT/../../testbench/test_Conv1D&Silu" && pwd)"
BENCH_FB="$(cd "$ROOT/../../testbench/test_Full_mamba_Branch" && pwd)"

echo "[Run] Conv1D stream continuous unit test N=$N"
cd "$ROOT"
rm -rf xsim.dir .Xil xsim_stream.log 2>/dev/null || true

ln -sf "$RTL_DIR/silu_pwl_coeffs.mem" silu_pwl_coeffs.mem

/tools/Xilinx/2025.1/Vivado/bin/xvlog --sv -d NUM_TOKENS="$N" \
  "$RTL_DIR/_parameter.v" \
  "$RTL_DIR/Conv1D_MAC.v" \
  "$RTL_DIR/SiLU_Unit_PWL.v" \
  "$RTL_DIR/SiLU_Unit.v" \
  "$RTL_DIR/Conv1D_Layer.v" \
  tb_conv1d_stream_continuous.v 2>&1 | tail -15

/tools/Xilinx/2025.1/Vivado/bin/xelab --relax tb_conv1d_stream_continuous \
  -s "tb_stream_n${N}" 2>&1 | tail -6

/tools/Xilinx/2025.1/Vivado/bin/xsim "tb_stream_n${N}" -runall 2>&1 | tee xsim_stream.log | tail -25

python3 << PY
from pathlib import Path

N = int("$N")
SEQ = 1000
LANES = 16
D_INNER = 128
TOL = 16
need_x = N * 8 * LANES
need_z = N * 8 * LANES

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

ROOT = "$ROOT"
rtl_x = [si(x) for x in readp(f"{ROOT}/rtl_x_stream.mem")]
rtl_z = [si(x) for x in readp(f"{ROOT}/rtl_z_stream.mem")]
gold_x = readp("$BENCH_X/silu_golden_full.mem")
gold_z_path = "$BENCH_FB/silu_z_golden_full.mem"
if not Path(gold_z_path).is_file():
    gold_z_path = "$BENCH_FB/gate.mem"
gold_z = readp(gold_z_path)

if len(rtl_x) < need_x or len(rtl_z) < need_z:
    print(f"FAIL: rtl_x={len(rtl_x)}/{need_x} rtl_z={len(rtl_z)}/{need_z}")
    import sys
    sys.exit(1)

bad_x = bad_z = 0
max_x = max_z = 0
for t in range(N):
    for fg in range(8):
        for lane in range(LANES):
            ch = fg * LANES + lane
            gi = ch * SEQ + t
            ri = (t * 8 + fg) * LANES + lane
            dx = abs(rtl_x[ri] - si(gold_x[gi]))
            max_x = max(max_x, dx)
            if dx > TOL:
                bad_x += 1
    for fg in range(8):
        for lane in range(LANES):
            ch = fg * LANES + lane
            gi = ch * SEQ + t
            ri = (t * 8 + fg) * LANES + lane
            dz = abs(rtl_z[ri] - si(gold_z[gi]))
            max_z = max(max_z, dz)
            if dz > TOL:
                bad_z += 1

print(f"\n[X activated] bad={bad_x}/{need_x} max|diff|={max_x} tol={TOL}")
print(f"[Z activated] vs {Path(gold_z_path).name} bad={bad_z}/{need_z} max|diff|={max_z} tol={TOL}")
import sys
sys.exit(1 if (bad_x or bad_z) else 0)
PY

echo "[Run] Legacy single-frame regression"
bash "$ROOT/run.sh"

echo "[PASS] stream continuous N=$N"
