#!/usr/bin/env bash
set -euo pipefail

# Run RMSNorm full-vector simulation and compare vs golden_output_full.mem
# Usage: ./run_norm.sh

ROOT="$(cd "$(dirname "$0")" && pwd)"
RTL_DIR="$(cd "$ROOT/../../code_initial" && pwd)"
BENCH_DIR="$(cd "$ROOT/../../testbench/test_RMSNorm" && pwd)"

echo "[Run] RMSNorm_Unit_IntSqrt full test (1000 x 64-dim vectors)"
echo "  Test dir:  $ROOT"
echo "  RTL dir:   $RTL_DIR"
echo "  Bench dir: $BENCH_DIR"

cd "$ROOT"

rm -rf xsim.dir .Xil *.log *.jou *.pb rtl_output_full.mem || true

echo "[Step 0] Link test vectors..."
ln -sf "$BENCH_DIR/input_full.mem"       input_full.mem
ln -sf "$BENCH_DIR/golden_output_full.mem" golden_output_full.mem
ln -sf "$BENCH_DIR/weight.mem"           weight.mem
ln -sf "$RTL_DIR/rmsnorm_rsqrt_coeffs.mem" rmsnorm_rsqrt_coeffs.mem

echo "[Step 1] Compiling sources..."
/tools/Xilinx/2025.1/Vivado/bin/xvlog --sv -i . -d RMSNORM_FULL_RUN -d RMSNORM_QUIET \
  "$RTL_DIR/_parameter.v" \
  "$RTL_DIR/RMSNorm_Unit_IntSqrt.v" \
  tb_rmsnorm_unit.v 2>&1 | tail -20

echo "[Step 2] Elaborating design..."
/tools/Xilinx/2025.1/Vivado/bin/xelab --relax tb_rmsnorm_unit -s tb_rmsnorm_sim 2>&1 | tail -10

echo "[Step 3] Running simulation..."
/tools/Xilinx/2025.1/Vivado/bin/xsim tb_rmsnorm_sim -R -runall 2>&1 | tee xsim_run.log | tail -30

echo "[Step 4] Comparing RTL output vs golden..."
if [ ! -f rtl_output_full.mem ]; then
    echo "ERROR: rtl_output_full.mem not generated!"
    exit 1
fi

python3 << 'PYSCRIPT'
import sys

def read_hex_file(path):
    with open(path) as f:
        return [line.strip().lower() for line in f if line.strip()]

def hex_to_signed_int(h):
    v = int(h, 16)
    if v & 0x8000:
        v -= 0x10000
    return v

ABS_TOL = 256

rtl = read_hex_file("rtl_output_full.mem")
gold = read_hex_file("golden_output_full.mem")
n = min(len(rtl), len(gold))

print(f"  RTL output: {len(rtl)} values")
print(f"  Golden:     {len(gold)} values")
print(f"  Compared:   {n} values (abs_tol={ABS_TOL})")

if len(rtl) != len(gold):
    print(f"WARNING: length mismatch rtl={len(rtl)} gold={len(gold)}")

mismatch = 0
max_err = 0
for i in range(n):
    rtl_val = hex_to_signed_int(rtl[i])
    gold_val = hex_to_signed_int(gold[i])
    err = abs(rtl_val - gold_val)
    max_err = max(max_err, err)
    if err > ABS_TOL:
        mismatch += 1
        if mismatch <= 10:
            print(f"  Mismatch [{i}]: RTL={rtl_val} Gold={gold_val} Err={err}")

print(f"\n[Results]")
print(f"  Pass (error <= {ABS_TOL}): {n - mismatch} / {n} ({100.0 * (n - mismatch) / n:.2f}%)")
print(f"  Mismatches (error > {ABS_TOL}): {mismatch} / {n}")
print(f"  Max error: {max_err}")

if mismatch == 0 and len(rtl) == len(gold):
    print("\n==================================================")
    print("PASS: All full RMSNorm outputs match golden!")
    print("==================================================")
    sys.exit(0)
else:
    if len(rtl) != len(gold):
        print(f"\nFAIL: output length mismatch")
    else:
        print(f"\nFAIL: {mismatch} mismatches found")
    sys.exit(1)
PYSCRIPT

echo ""
echo "Test completed!"
