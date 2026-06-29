#!/usr/bin/env bash
# Run In_Projection_Unit_Streaming_v3 multi-frame test for N timesteps (no rst_n between frames).
# Usage: ./run_v3_multiframe.sh [N]   (default N=2)
set -euo pipefail

N="${1:-2}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
RTL_DIR="$(cd "$ROOT/../../code_initial" && pwd)"
BENCH_DIR="$(cd "$ROOT/../../testbench/test_Inprojection" && pwd)"

echo "[Run] In_Projection_Unit_Streaming_v3 multi-frame test: N=$N"
cd "$ROOT"

rm -rf xsim.dir .Xil *.log *.jou *.pb "rtl_output_${N}.mem" || true

ln -sf "$BENCH_DIR/input_full.mem" input_full.mem
ln -sf "$BENCH_DIR/golden_output_full.mem" golden_output_full.mem

echo "[Step 1] Compile (NUM_VECTORS=$N)..."
/tools/Xilinx/2025.1/Vivado/bin/xvlog --sv -i . -d NUM_VECTORS="$N" \
  "$RTL_DIR/_parameter.v" \
  "$RTL_DIR/In_Projection_Unit_Streaming_v3.v" \
  tb_in_projection_unit_stream_v3_full.v 2>&1 | tail -5

echo "[Step 2] Elaborate..."
/tools/Xilinx/2025.1/Vivado/bin/xelab --relax tb_in_projection_unit_stream_v3_full \
  -s "tb_v3_n${N}_sim" 2>&1 | tail -3

echo "[Step 3] Simulate..."
/tools/Xilinx/2025.1/Vivado/bin/xsim "tb_v3_n${N}_sim" -runall 2>&1 | tail -15

mv -f rtl_output_full.mem "rtl_output_${N}.mem"

echo "[Step 4] Compare vs golden (first $((N * 256)) values)..."
python3 << PYSCRIPT
import sys, os
N = int("$N")
TOL = 256

def read_hex(path, limit=None):
    vals = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            vals.append(line)
            if limit and len(vals) >= limit:
                break
    return vals

def si(h):
    v = int(h, 16)
    return v - 0x10000 if v & 0x8000 else v

rtl = read_hex(f'rtl_output_{N}.mem', N * 256)
gold = read_hex('golden_output_full.mem', N * 256)
need = N * 256
if len(rtl) < need:
    print(f'ERROR: rtl has {len(rtl)} values, need {need}')
    sys.exit(2)
if len(gold) < need:
    print(f'ERROR: golden has {len(gold)} values, need {need}')
    sys.exit(2)

mismatch = 0
max_err = 0
per_t = [0] * N
for i in range(need):
    err = abs(si(rtl[i]) - si(gold[i]))
    max_err = max(max_err, err)
    if err > TOL:
        mismatch += 1
        per_t[i // 256] += 1
        if mismatch <= 8:
            t, lane = i // 256, i % 256
            print(f'  Mismatch [{i}] t={t} lane={lane}: RTL={si(rtl[i])} Gold={si(gold[i])} Err={err}')

print(f'\n[Results N={N}]')
print(f'  Compared: {need} values (abs_tol={TOL})')
print(f'  Mismatches: {mismatch} / {need}')
print(f'  Max error: {max_err}')
for t in range(N):
    print(f'  t={t}: {per_t[t]}/256 mismatches')

if mismatch == 0:
    print(f'\nPASS: all {N} timesteps match golden')
    sys.exit(0)
else:
    print(f'\nFAIL: {mismatch} mismatches')
    sys.exit(1)
PYSCRIPT
