#!/usr/bin/env bash
# RMSNorm -> InProj continuous chain test (1000 samples by default).
# Usage: ./run_chain_continuous.sh [N]
set -euo pipefail

N="${1:-1000}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
RTL_DIR="$(cd "$ROOT/../../code_initial" && pwd)"

echo "[Run] RMSNorm -> InProj chain CONTINUOUS test N=$N"
cd "$ROOT"
rm -rf xsim.dir .Xil xsim_chain_cont.log 2>/dev/null || true

ln -sf "$RTL_DIR/rmsnorm_rsqrt_coeffs.mem" rmsnorm_rsqrt_coeffs.mem

/tools/Xilinx/2025.1/Vivado/bin/xvlog --sv -i . -d NUM_VECTORS="$N" \
  "$RTL_DIR/_parameter.v" \
  "$RTL_DIR/RMSNorm_Unit_IntSqrt.v" \
  "$RTL_DIR/In_Projection_Unit_Streaming_v2.v" \
  "$RTL_DIR/RMSNorm_InProj_Chain_Wrapper.v" \
  tb_rmsnorm_inproj_chain_continuous.v 2>&1 | tail -12

/tools/Xilinx/2025.1/Vivado/bin/xelab --relax tb_rmsnorm_inproj_chain_continuous \
  -s "tb_chain_cont_n${N}" 2>&1 | tail -6

/tools/Xilinx/2025.1/Vivado/bin/xsim "tb_chain_cont_n${N}" -runall 2>&1 | tee xsim_chain_cont.log | tail -30

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
rtl = readp(f"{ROOT}/rtl_output_chain_continuous.mem", need)
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

print(f"\n[InProj chain vs golden] mismatches (tol>{TOL}): {bad}/{need}")
for t in range(min(N, 5)):
    print(f"  t={t}: {per_t[t]}/256 bad")
if N > 5:
    print("  ...")
    print(f"  t={N-1}: {per_t[N-1]}/256 bad")

RMS_TOL = 64
rms_rtl = readp(f"{ROOT}/rtl_norm_per_token.mem", N * 64)
rms_gold = readp("/home/hatthanh/schoolwork/KLTN/RTL/testbench/test_RMSNorm/golden_output_full.mem", N * 64)
rms_bad = 0
rms_per_t = [0] * N
for i in range(min(len(rms_rtl), N * 64)):
    rv, gv = si(rms_rtl[i]), si(rms_gold[i])
    if rv is None or gv is None:
        rms_bad += 1
        rms_per_t[i // 64] += 1
        continue
    if abs(rv - gv) > RMS_TOL:
        rms_bad += 1
        rms_per_t[i // 64] += 1

print(f"\n[RMS norm_buf vs golden] mismatches (tol>{RMS_TOL}): {rms_bad}/{N * 64}")
for t in range(min(N, 5)):
    print(f"  t={t}: {rms_per_t[t]}/64 bad")
if N > 5:
    print("  ...")
    print(f"  t={N-1}: {rms_per_t[N-1]}/64 bad")

import sys
sys.exit(1 if bad or rms_bad else 0)
PY

echo "Done. Log: $ROOT/xsim_chain_cont.log"
