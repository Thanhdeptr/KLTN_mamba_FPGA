#!/usr/bin/env bash
set -euo pipefail

N="${1:-1}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
RTL_DIR="$(cd "$ROOT/../../code_initial" && pwd)"
GOLD="$(cd "$ROOT/../../testbench/test_Scancore" && pwd)"

echo "[Chain] RMSNorm+InProj+Conv+Scan bring-up N=$N (scan tap only in this tb)"
cd "$ROOT"
ln -sf "$GOLD"/*.mem .
ln -sf "$RTL_DIR/softplus_pwl_coeffs.mem" softplus_pwl_coeffs.mem
ln -sf "$RTL_DIR/exp_pwl_coeffs.mem" exp_pwl_coeffs.mem

XVLOG=/tools/Xilinx/2025.1/Vivado/bin/xvlog
XELAB=/tools/Xilinx/2025.1/Vivado/bin/xelab
XSIM=/tools/Xilinx/2025.1/Vivado/bin/xsim

"$XVLOG" --sv -d NUM_TOKENS="$N" \
  "$RTL_DIR/_parameter.v" \
  "$RTL_DIR/Unified_PE.v" \
  "$RTL_DIR/Softplus_Unit_PWL.v" \
  "$RTL_DIR/SiLU_Unit_PWL.v" \
  "$RTL_DIR/Exp_Unit.v" \
  "$RTL_DIR/Exp_Unit_PWL.v" \
  "$RTL_DIR/Scan_Core_Engine.v" \
  "$RTL_DIR/Scan_Channel_Exec.v" \
  "$RTL_DIR/Scan_YPre_Slot.v" \
  "$RTL_DIR/Scan_XZ_Engine.v" \
  "$RTL_DIR/Scan_HMem_SubBank.v" \
  "$RTL_DIR/Scan_HMem_Banked.v" \
  "$RTL_DIR/Scan_HState_Live.v" \
  "$RTL_DIR/Scan_Sync_Rom16.v" \
  "$RTL_DIR/Scan_Wide_Rom256.v" \
  "$RTL_DIR/Scan_Core_Streaming_Pipe.v" \
  "$RTL_DIR/Scan_Chain_Wrapper.v" \
  tb_scan_chain_tap.v

"$XELAB" --relax tb_scan_chain_tap -s "tb_scan_chain_n${N}"
"$XSIM" "tb_scan_chain_n${N}" -runall | tail -20
