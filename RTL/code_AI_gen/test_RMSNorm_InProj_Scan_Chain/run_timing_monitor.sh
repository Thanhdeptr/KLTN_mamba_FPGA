#!/usr/bin/env bash
# InProj <-> Conv timing monitor (N=1). Grep CHECK/SUMMARY lines in log.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
RTL_DIR="$(cd "$ROOT/../../code_initial" && pwd)"

echo "[Run] Conv timing monitor N=1"

cd "$ROOT"
rm -rf xsim.dir .Xil xsim_timing_monitor.log 2>/dev/null || true

ln -sf "$RTL_DIR/silu_pwl_coeffs.mem" silu_pwl_coeffs.mem
ln -sf "$RTL_DIR/rmsnorm_rsqrt_coeffs.mem" rmsnorm_rsqrt_coeffs.mem

XVLOG=/tools/Xilinx/2025.1/Vivado/bin/xvlog
XELAB=/tools/Xilinx/2025.1/Vivado/bin/xelab
XSIM=/tools/Xilinx/2025.1/Vivado/bin/xsim

"$XVLOG" --sv -i . -d INPROJ_CHAIN_QUIET=1 \
  "$RTL_DIR/_parameter.v" \
  "$RTL_DIR/RMSNorm_Unit_IntSqrt.v" \
  "$RTL_DIR/In_Projection_Unit_Streaming_v2.v" \
  "$RTL_DIR/Conv1D_MAC.v" \
  "$RTL_DIR/SiLU_Unit_PWL.v" \
  "$RTL_DIR/SiLU_Unit.v" \
  "$RTL_DIR/Conv1D_Layer.v" \
  "$RTL_DIR/RMSNorm_InProj_Conv_Chain_Wrapper.v" \
  tb_conv_timing_monitor.v 2>&1 | tail -15

"$XELAB" --relax tb_conv_timing_monitor -s tb_timing_n1 2>&1 | tail -5

timeout 60 "$XSIM" tb_timing_n1 -runall 2>&1 | tee xsim_timing_monitor.log

echo ""
echo "=== CHECK lines (InProj + Conv events) ==="
grep '\[CHECK' xsim_timing_monitor.log || true
echo ""
echo "=== SUMMARY lines (X-Z delta per grp) ==="
grep '\[SUMMARY' xsim_timing_monitor.log || true

echo ""
echo "Done. Log: $ROOT/xsim_timing_monitor.log"
