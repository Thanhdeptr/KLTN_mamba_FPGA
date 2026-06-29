#!/usr/bin/env bash
# Run In_Projection_Unit_Streaming_v2 full-sequence test (default 1000 timesteps).
# Usage: ./run_v2_full.sh [N]
set -euo pipefail

N="${1:-1000}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
RTL_DIR="$(cd "$ROOT/../../code_initial" && pwd)"
BENCH_DIR="$(cd "$ROOT/../../testbench/test_Inprojection" && pwd)"

echo "[Run] In_Projection_Unit_Streaming_v2 FULL test: N=$N"
echo "  Test dir:  $ROOT"
echo "  RTL dir:   $RTL_DIR"
echo "  Bench dir: $BENCH_DIR"

cd "$ROOT"

rm -rf xsim.dir .Xil xsim_v2_full_run.log rtl_output_v2_full.mem 2>/dev/null || true

echo "[Step 0] Link test vectors..."
ln -sf "$BENCH_DIR/input_full.mem" input_full.mem
ln -sf "$BENCH_DIR/golden_output_full.mem" golden_output_full.mem

echo "[Step 1] Compile (NUM_VECTORS=$N)..."
/tools/Xilinx/2025.1/Vivado/bin/xvlog --sv -i . -d NUM_VECTORS="$N" \
  "$RTL_DIR/_parameter.v" \
  "$RTL_DIR/In_Projection_Unit_Streaming_v2.v" \
  tb_in_projection_unit_stream_v2_full.v 2>&1 | tail -10

echo "[Step 2] Elaborate..."
/tools/Xilinx/2025.1/Vivado/bin/xelab --relax tb_in_projection_unit_stream_v2_full \
  -s "tb_v2_n${N}_sim" 2>&1 | tail -5

echo "[Step 3] Simulate..."
/tools/Xilinx/2025.1/Vivado/bin/xsim "tb_v2_n${N}_sim" -runall 2>&1 | tee xsim_v2_full_run.log | tail -30

echo "[Step 4] Compare vs golden (first $((N * 256)) values)..."
python3 << PYSCRIPT
import sys

N = int("$N")
TOL = 256
NEED = N * 256

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

rtl = read_hex('rtl_output_v2_full.mem', NEED)
gold = read_hex('golden_output_full.mem', NEED)

if len(rtl) < NEED:
    print(f'ERROR: rtl has {len(rtl)} values, need {NEED}')
    sys.exit(2)
if len(gold) < NEED:
    print(f'ERROR: golden has {len(gold)} values, need {NEED}')
    sys.exit(2)

mismatch = 0
max_err = 0
per_t = [0] * N
for i in range(NEED):
    err = abs(si(rtl[i]) - si(gold[i]))
    max_err = max(max_err, err)
    if err > TOL:
        mismatch += 1
        per_t[i // 256] += 1
        if mismatch <= 8:
            t, lane = i // 256, i % 256
            print(f'  Mismatch [{i}] t={t} lane={lane}: RTL={si(rtl[i])} Gold={si(gold[i])} Err={err}')

print(f'\n[Results N={N}]')
print(f'  Compared: {NEED} values (abs_tol={TOL})')
print(f'  Mismatches: {mismatch} / {NEED}')
print(f'  Max error: {max_err}')
for t in range(min(N, 5)):
    print(f'  t={t}: {per_t[t]}/256 mismatches')
if N > 5:
    print(f'  ...')
    for t in [N - 1]:
        print(f'  t={t}: {per_t[t]}/256 mismatches')

if mismatch == 0:
    print(f'\nPASS: all {N} timesteps match golden')
    sys.exit(0)
else:
    print(f'\nFAIL: {mismatch} mismatches')
    sys.exit(1)
PYSCRIPT

echo ""
echo "Done. Log: $ROOT/xsim_v2_full_run.log"
