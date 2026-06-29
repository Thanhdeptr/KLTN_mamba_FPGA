#!/usr/bin/env bash
set -euo pipefail

# Run simulation for In_Projection_Unit_Streaming_v3 (4-lane TMUX, 32 DSP)
# Usage: ./run_v3.sh

ROOT="$(cd "$(dirname "$0")" && pwd)"
RTL_DIR="$(cd "$ROOT/../../code_initial" && pwd)"

echo "[Run] In_Projection_Unit_Streaming_v3 Test (4-pass TMUX, 32 DSP)"
echo "  Test dir: $ROOT"
echo "  RTL dir:  $RTL_DIR"

cd "$ROOT"

rm -rf xsim.dir .Xil *.log *.jou *.pb rtl_output_v3.mem || true

echo "[Step 1] Compiling sources for v3 (INPROJ_V3_DEBUG)..."
/tools/Xilinx/2025.1/Vivado/bin/xvlog --sv -i . -d INPROJ_V3_DEBUG \
  "$RTL_DIR/_parameter.v" \
  "$RTL_DIR/In_Projection_Unit_Streaming_v3.v" \
  tb_in_projection_unit_stream_v3.v 2>&1 | tail -30

echo "[Step 2] Elaborating design..."
/tools/Xilinx/2025.1/Vivado/bin/xelab --relax tb_in_projection_unit_stream_v3 -s tb_stream_v3_sim 2>&1 | tail -20

echo "[Step 3] Running simulation..."
/tools/Xilinx/2025.1/Vivado/bin/xsim tb_stream_v3_sim -runall 2>&1 | tail -60

echo "[Step 4] Comparing RTL output (v3, 16 lanes) vs golden..."
if [ -f debug_v3.log ]; then
    echo "--- debug_v3.log summary ---"
    tail -5 debug_v3.log
    echo ""
fi
if [ -f rtl_output_v3.mem ]; then
    python3 << 'PYSCRIPT'
import sys, os

def read_hex_file(path):
    if not os.path.exists(path):
        print(f'Error: file not found: {path}')
        sys.exit(1)
    with open(path) as f:
        return [line.strip() for line in f if line.strip()]

def hex_to_signed_int(h):
    v = int(h, 16)
    if v & 0x8000:
        v -= 0x10000
    return v

rtl = read_hex_file('rtl_output_v3.mem')
gold = read_hex_file('golden_output.mem')[:256]

print(f"  RTL output (v3): {len(rtl)} values")
print(f"  Golden:          {len(gold)} values")

if len(rtl) < 256:
    print(f'Error: rtl_output_v3.mem has {len(rtl)} values, need 256')
    sys.exit(2)
if len(gold) < 256:
    print(f'Error: golden_output.mem has {len(gold)} values, need 256')
    sys.exit(2)

mismatch = 0
max_err = 0
for i in range(256):
    rtl_val = hex_to_signed_int(rtl[i])
    gold_val = hex_to_signed_int(gold[i])
    err = abs(rtl_val - gold_val)
    max_err = max(max_err, err)
    if err > 256:
        mismatch += 1
        if mismatch <= 5:
            print(f"  Mismatch [{i}]: RTL={rtl_val} Gold={gold_val} Err={err}")

print(f"\n[Results]")
print(f"  Values compared: 256")
print(f"  Mismatches (error > 256): {mismatch} / 256")
print(f"  Max error: {max_err}")

if mismatch == 0:
    print("\n==================================================")
    print("PASS: All 256 V3 output values match golden!")
    print("==================================================")
    sys.exit(0)
else:
    print(f"\nFAIL: {mismatch} mismatches found")
    sys.exit(1)
PYSCRIPT
else
    echo "ERROR: rtl_output_v3.mem not generated!"
    exit 1
fi

echo ""
echo "Test completed!"
