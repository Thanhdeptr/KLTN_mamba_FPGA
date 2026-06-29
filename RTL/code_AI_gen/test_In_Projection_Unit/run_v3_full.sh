#!/usr/bin/env bash
set -euo pipefail

# Run In_Projection_Unit_Streaming_v3 full-sequence test (1000 x 256 outputs).
# Usage: ./run_v3_full.sh

ROOT="$(cd "$(dirname "$0")" && pwd)"
RTL_DIR="$(cd "$ROOT/../../code_initial" && pwd)"
BENCH_DIR="$(cd "$ROOT/../../testbench/test_Inprojection" && pwd)"

echo "[Run] In_Projection_Unit_Streaming_v3 FULL test (1000 timesteps)"
echo "  Test dir:  $ROOT"
echo "  RTL dir:   $RTL_DIR"
echo "  Bench dir: $BENCH_DIR"

cd "$ROOT"

rm -rf xsim.dir .Xil *.log *.jou *.pb rtl_output_full.mem || true

echo "[Step 0] Link test vectors..."
ln -sf "$BENCH_DIR/input_full.mem" input_full.mem
ln -sf "$BENCH_DIR/golden_output_full.mem" golden_output_full.mem

echo "[Step 1] Compiling sources..."
/tools/Xilinx/2025.1/Vivado/bin/xvlog --sv -i . \
  "$RTL_DIR/_parameter.v" \
  "$RTL_DIR/In_Projection_Unit_Streaming_v3.v" \
  tb_in_projection_unit_stream_v3_full.v 2>&1 | tail -20

echo "[Step 2] Elaborating design..."
/tools/Xilinx/2025.1/Vivado/bin/xelab --relax tb_in_projection_unit_stream_v3_full -s tb_stream_v3_full_sim 2>&1 | tail -10

echo "[Step 3] Running simulation (1000 vectors, may take several minutes)..."
/tools/Xilinx/2025.1/Vivado/bin/xsim tb_stream_v3_full_sim -runall 2>&1 | tee xsim_full_run.log | tail -40

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
    if 'x' in h:
        return None
    v = int(h, 16)
    if v & 0x8000:
        v -= 0x10000
    return v

ABS_TOL = 256
EXPECTED = 256000

rtl = read_hex_file("rtl_output_full.mem")
gold = read_hex_file("golden_output_full.mem")
n = min(len(rtl), len(gold))

print(f"  RTL output: {len(rtl)} values")
print(f"  Golden:     {len(gold)} values")
print(f"  Compared:   {n} values (abs_tol={ABS_TOL})")

if len(rtl) != EXPECTED:
    print(f"WARNING: expected {EXPECTED} RTL values, got {len(rtl)}")
if len(gold) != EXPECTED:
    print(f"WARNING: expected {EXPECTED} golden values, got {len(gold)}")

mismatch = 0
max_err = 0
for i in range(n):
    rtl_val = hex_to_signed_int(rtl[i])
    gold_val = hex_to_signed_int(gold[i])
    if rtl_val is None or gold_val is None:
        mismatch += 1
        if mismatch <= 10:
            print(f"  Mismatch [{i}]: RTL={rtl[i]} Gold={gold[i]} (invalid)")
        continue
    err = abs(rtl_val - gold_val)
    max_err = max(max_err, err)
    if err > ABS_TOL:
        mismatch += 1
        if mismatch <= 10:
            t, lane = divmod(i, 256)
            print(f"  Mismatch [{i}] t={t} lane={lane}: RTL={rtl_val} Gold={gold_val} Err={err}")

print(f"\n[Results]")
print(f"  Pass (error <= {ABS_TOL}): {n - mismatch} / {n} ({100.0 * (n - mismatch) / n:.4f}%)")
print(f"  Mismatches (error > {ABS_TOL}): {mismatch} / {n}")
print(f"  Max error: {max_err}")

if mismatch == 0 and len(rtl) == len(gold) == EXPECTED:
    print("\n==================================================")
    print("PASS: All 256000 V3 full outputs match golden!")
    print("==================================================")
    sys.exit(0)
else:
    print(f"\nFAIL: {mismatch} mismatches found")
    sys.exit(1)
PYSCRIPT

echo ""
echo "Test completed!"
