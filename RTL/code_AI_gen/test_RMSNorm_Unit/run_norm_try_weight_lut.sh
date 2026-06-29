#!/usr/bin/env bash
set -euo pipefail

# Experiment: use testbench weight.mem as FastRsqrt_NR seed LUT
# (instead of rmsnorm_rsqrt_coeffs.mem). Single-vector TB run + compare.

ROOT="$(cd "$(dirname "$0")" && pwd)"
RTL_DIR="$(cd "$ROOT/../../code_initial" && pwd)"
BENCH_DIR="$(cd "$ROOT/../../testbench/test_RMSNorm" && pwd)"

echo "[Try] RMSNorm with weight.mem as rsqrt seed LUT (1 vector)"
echo "  Test dir:  $ROOT"
echo "  Bench dir: $BENCH_DIR"

cd "$ROOT"

rm -rf xsim.dir .Xil xsim_run_weight_lut.log rtl_output_weight_lut.mem || true

ln -sf "$BENCH_DIR/input.mem" input.mem
ln -sf "$BENCH_DIR/weight.mem" weight.mem
ln -sf "$BENCH_DIR/golden_output.mem" golden_output.mem
# Experiment: gamma weights file reused as rsqrt ROM contents
ln -sf "$BENCH_DIR/weight.mem" rmsnorm_rsqrt_coeffs.mem

echo "[Step 1] Compile (single vector, no FULL_RUN)..."
/tools/Xilinx/2025.1/Vivado/bin/xvlog --sv -i . -d RMSNORM_QUIET \
  "$RTL_DIR/_parameter.v" \
  "$RTL_DIR/RMSNorm_Unit_IntSqrt.v" \
  tb_rmsnorm_unit.v 2>&1 | tail -10

echo "[Step 2] Elaborate..."
/tools/Xilinx/2025.1/Vivado/bin/xelab --relax tb_rmsnorm_unit -s tb_rmsnorm_sim 2>&1 | tail -5

echo "[Step 3] Simulate..."
/tools/Xilinx/2025.1/Vivado/bin/xsim tb_rmsnorm_sim -R -runall 2>&1 | tee xsim_run_weight_lut.log | tail -15

cp -f rtl_output.mem rtl_output_weight_lut.mem

echo "[Step 4] Compare vs golden_output.mem (C++ model)..."
python3 << 'PY'
def read_hex(path):
    with open(path) as f:
        return [int(l.strip(), 16) for l in f if l.strip()]

def to_s(v):
    return v if v < 0x8000 else v - 0x10000

ABS_TOL = 256
rtl = read_hex("rtl_output_weight_lut.mem")
gold = read_hex("golden_output.mem")
mm = mx = 0
for i in range(64):
    e = abs(to_s(rtl[i]) - to_s(gold[i]))
    mx = max(mx, e)
    if e > ABS_TOL:
        mm += 1
        if mm <= 8:
            print(f"  idx={i} rtl={rtl[i]:04x} gold={gold[i]:04x} err={e}")
print(f"Compared 64 values, tol={ABS_TOL}")
print(f"  Pass: {64-mm}/64")
print(f"  Fail: {mm}/64")
print(f"  Max err: {mx}")
print(f"  rtl[0]={to_s(rtl[0])} gold[0]={to_s(gold[0])}")
PY

echo ""
echo "Baseline reference (original rsqrt LUT): rtl_output.mem if present"
if [ -f rtl_output.mem.baseline ]; then
    python3 -c "
def q(h): v=int(h,16); return v if v<0x8000 else v-0x10000
b=open('rtl_output.mem.baseline').read().split()
w=open('rtl_output_weight_lut.mem').read().split()
print('  baseline rtl[0]=', q(b[0]), ' weight-lut rtl[0]=', q(w[0]))
"
fi
