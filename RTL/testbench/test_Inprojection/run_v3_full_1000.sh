#!/usr/bin/env bash
# Run In_Projection_Unit_Streaming_v3 on 1000 timesteps.
# Uses input_full.mem and golden_output_full.mem in this directory.
# Usage: ./run_v3_full_1000.sh [N]
set -euo pipefail

N="${1:-1000}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
RTL_DIR="$(cd "$ROOT/../../code_initial" && pwd)"
BANKS_SRC="$(cd "$ROOT/../../code_AI_gen/test_In_Projection_Unit/banks" && pwd)"

echo "[Run] InProjection v3 full test N=$N"
echo "  Bench: $ROOT"
echo "  RTL:   $RTL_DIR"
echo "  Banks: $BANKS_SRC"

cd "$ROOT"
rm -rf xsim.dir .Xil xsim_run.log rtl_output_full.mem 2>/dev/null || true

mkdir -p weight_banks
for i in $(seq 0 15); do
  ln -sf "$BANKS_SRC/weight_lane_${i}.mem" "weight_banks/weight_lane_${i}.mem"
done

if [ ! -f input_full.mem ] || [ ! -f golden_output_full.mem ]; then
  echo "ERROR: need input_full.mem and golden_output_full.mem in $ROOT"
  exit 1
fi

echo "[Compile] NUM_VECTORS=$N"
/tools/Xilinx/2025.1/Vivado/bin/xvlog --sv -i . -d NUM_VECTORS="$N" \
  "$RTL_DIR/_parameter.v" \
  "$RTL_DIR/In_Projection_Unit_Streaming_v3.v" \
  tb_in_projection_v3_full.v 2>&1 | tail -8

/tools/Xilinx/2025.1/Vivado/bin/xelab --relax tb_in_projection_v3_full \
  -s "tb_inproj_n${N}_sim" 2>&1 | tail -4

echo "[Simulate]"
/tools/Xilinx/2025.1/Vivado/bin/xsim "tb_inproj_n${N}_sim" -runall 2>&1 | tee xsim_run.log | tail -25

echo "[Compare]"
python3 << PY
N = int("$N")
TOL = 256
need = N * 256

def si(h):
    if not h or 'x' in h.lower():
        return None
    v = int(h, 16)
    return v - 0x10000 if v & 0x8000 else v

def readp(p, lim=None):
    o = []
    with open(p) as f:
        for line in f:
            s = line.strip()
            if s:
                o.append(s)
                if lim and len(o) >= lim:
                    break
    return o

rtl = readp('rtl_output_full.mem', need)
gold = readp('golden_output_full.mem', need)
bad = 0
mx = 0
for i in range(need):
    rv, gv = si(rtl[i]), si(gold[i])
    if rv is None or gv is None:
        bad += 1
        continue
    err = abs(rv - gv)
    mx = max(mx, err)
    if err > TOL:
        bad += 1
print(f'Compared {need}, mismatches (tol>{TOL}): {bad}, max_err={mx}')
if bad:
    raise SystemExit(1)
print(f'PASS: all {N} timesteps match golden')
PY

echo "Done."
