#!/usr/bin/env bash
# Full Mamba streaming block: RMSNorm -> InProj -> Conv -> Scan -> OutProj.
# Usage: ./run_streaming_chain.sh [N]
set -euo pipefail

N="${1:-1}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
RTL_DIR="$(cd "$ROOT/../../code_initial" && pwd)"
SCAN_GOLD="$(cd "$ROOT/../../testbench/test_Scancore" && pwd)"
FB_BENCH="$(cd "$ROOT/../../testbench/test_Full_mamba_Branch" && pwd)"
CONV_CHAIN="$(cd "$ROOT/../test_RMSNorm_InProj_Chain" && pwd)"

echo "[Run] Mamba streaming wrapper N=$N"

echo "[Prep] RMSNorm+InProj+Conv chain vs cpp float N=$N"
bash "$CONV_CHAIN/run_conv_chain.sh" "$N"

cd "$ROOT"
rm -rf xsim.dir .Xil xsim_streaming_chain.log 2>/dev/null || true

ln -sf "$RTL_DIR/silu_pwl_coeffs.mem" silu_pwl_coeffs.mem
ln -sf "$RTL_DIR/rmsnorm_rsqrt_coeffs.mem" rmsnorm_rsqrt_coeffs.mem
ln -sf "$RTL_DIR/softplus_pwl_coeffs.mem" softplus_pwl_coeffs.mem
ln -sf "$RTL_DIR/exp_pwl_coeffs.mem" exp_pwl_coeffs.mem
ln -sf "$SCAN_GOLD/delta_before_softplus.mem" delta_before_softplus.mem
ln -sf "$SCAN_GOLD/A_vec.mem" A_vec.mem
ln -sf "$SCAN_GOLD/B_vec.mem" B_vec.mem
ln -sf "$SCAN_GOLD/C_vec.mem" C_vec.mem
ln -sf "$SCAN_GOLD/D_vec.mem" D_vec.mem
ln -sf "$FB_BENCH/outproj_weight.mem" outproj_weight.mem

XVLOG=/tools/Xilinx/2025.1/Vivado/bin/xvlog
XELAB=/tools/Xilinx/2025.1/Vivado/bin/xelab
XSIM=/tools/Xilinx/2025.1/Vivado/bin/xsim

XVLOG_FLAGS=(--sv -i . -d NUM_VECTORS="$N" -d INPROJ_CHAIN_QUIET=1)
if [ "${SCAN_H_LIVE:-1}" = "1" ]; then
  XVLOG_FLAGS+=(-d SCAN_H_LIVE=1)
fi

"$XVLOG" "${XVLOG_FLAGS[@]}" \
  "$RTL_DIR/_parameter.v" \
  "$RTL_DIR/RMSNorm_Unit_IntSqrt.v" \
  "$RTL_DIR/In_Projection_Unit_Streaming_v2.v" \
  "$RTL_DIR/Conv1D_MAC.v" \
  "$RTL_DIR/SiLU_Unit_PWL.v" \
  "$RTL_DIR/SiLU_Unit.v" \
  "$RTL_DIR/Conv1D_Layer.v" \
  "$RTL_DIR/RMSNorm_InProj_Conv_Chain_Wrapper.v" \
  "$RTL_DIR/RMSNorm_InProj_Conv_Scan_Chain_Wrapper.v" \
  "$RTL_DIR/Out_Projection_Streaming_v2.v" \
  "$RTL_DIR/Mamba_Streaming_Block_Wrapper.v" \
  "$RTL_DIR/Unified_PE.v" \
  "$RTL_DIR/Softplus_Unit_PWL.v" \
  "$RTL_DIR/Exp_Unit.v" \
  "$RTL_DIR/Exp_Unit_PWL.v" \
  "$RTL_DIR/Scan_Core_Engine.v" \
  "$RTL_DIR/Scan_Channel_Exec.v" \
  "$RTL_DIR/Scan_YPre_Slot.v" \
  "$RTL_DIR/Scan_XZ_Engine.v" \
  "$RTL_DIR/Scan_Sync_Rom16.v" \
  "$RTL_DIR/Scan_Wide_Rom256.v" \
  "$RTL_DIR/Scan_HMem_SubBank.v" \
  "$RTL_DIR/Scan_HMem_Banked.v" \
  "$RTL_DIR/Scan_HState_Live.v" \
  "$RTL_DIR/Scan_Core_Streaming_Pipe.v" \
  "$RTL_DIR/Scan_Chain_Wrapper.v" \
  tb_mamba_streaming_chain.v 2>&1 | tail -25

"$XELAB" --relax tb_mamba_streaming_chain \
  -s "tb_mamba_stream_n${N}" 2>&1 | tail -8

SIM_TIMEOUT_SEC="${SIM_TIMEOUT_SEC:-900}"
XSIM_CMD=(timeout "$SIM_TIMEOUT_SEC" "$XSIM" --maxdeltaid 10000000 "tb_mamba_stream_n${N}" -runall)

"${XSIM_CMD[@]}" 2>&1 | tee xsim_streaming_chain.log | tail -45
XSIM_RC=${PIPESTATUS[0]}
if [ "$XSIM_RC" -eq 124 ]; then
  echo "FAIL: xsim exceeded ${SIM_TIMEOUT_SEC}s timeout (N=$N)"
  exit 1
fi
if [ "$XSIM_RC" -ne 0 ]; then
  exit "$XSIM_RC"
fi

chmod +x "$ROOT/run_scan_ref_wrapper.sh"
bash "$ROOT/run_scan_ref_wrapper.sh" "$N"

python3 "$ROOT/compare_streaming_chain.py" --tokens "$N" --dir "$ROOT"

echo "[PASS] Mamba streaming wrapper N=$N"
echo "Done. Log: $ROOT/xsim_streaming_chain.log"
