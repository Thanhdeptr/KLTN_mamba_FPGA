#!/usr/bin/env bash
# Continuous v2 stream test (start=1 across frames, no inter-frame reset).
# Usage: ./run_v2_continuous.sh [N]
set -euo pipefail

N="${1:-10}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
RTL_DIR="$(cd "$ROOT/../../code_initial" && pwd)"

echo "[Run] In_Projection v2 CONTINUOUS stream test N=$N"
cd "$ROOT"
rm -rf xsim.dir .Xil xsim_v2_cont.log 2>/dev/null || true

/tools/Xilinx/2025.1/Vivado/bin/xvlog --sv -i . -d NUM_VECTORS="$N" \
  "$RTL_DIR/_parameter.v" \
  "$RTL_DIR/In_Projection_Unit_Streaming_v2.v" \
  tb_in_projection_unit_stream_v2_continuous.v 2>&1 | tail -8

/tools/Xilinx/2025.1/Vivado/bin/xelab --relax tb_in_projection_unit_stream_v2_continuous \
  -s "tb_v2_cont_n${N}" 2>&1 | tail -4

/tools/Xilinx/2025.1/Vivado/bin/xsim "tb_v2_cont_n${N}" -runall 2>&1 | tee xsim_v2_cont.log | tail -25

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

ROOT = "$ROOT"
rtl = readp(f"{ROOT}/rtl_output_v2_continuous.mem", need)
gold = readp("/home/hatthanh/schoolwork/KLTN/RTL/testbench/test_Inprojection/golden_output_full.mem", need)

bad = 0
per_t = [0] * N
for i in range(min(len(rtl), need)):
    rv, gv = si(rtl[i]), si(gold[i])
    if rv is None or gv is None:
        bad += 1
        per_t[i // 256] += 1
        continue
    if abs(rv - gv) > TOL:
        bad += 1
        per_t[i // 256] += 1

print(f"\n[Compare N={N}] mismatches (tol>{TOL}): {bad}/{need}")
for t in range(min(N, 8)):
    print(f"  t={t}: {per_t[t]}/256 bad")
if N > 8:
    print("  ...")
    print(f"  t={N-1}: {per_t[N-1]}/256 bad")
PY

echo "Done. Log: $ROOT/xsim_v2_cont.log"
