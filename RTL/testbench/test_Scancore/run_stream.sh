#!/usr/bin/env bash
set -euo pipefail

N="${1:-1}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
KLTN_ROOT="$(cd "$ROOT/../../.." && pwd)"
RTL_DIR="$(cd "$ROOT/../../code_initial" && pwd)"

echo "[Run] Scan Core Streaming (legacy path) N=$N"
cd "$ROOT"

if [ "${REGEN_MEM:-1}" = "1" ]; then
  echo "[Regen] scancore .mem from ITMN cpp_golden_files"
  PYTHONPATH="${KLTN_ROOT}/ITMN" python3 "${KLTN_ROOT}/py_software/extract_RTL_inital_mem.py" --mode scancore
fi

rm -rf xsim.dir .Xil xsim_scan_stream.log 2>/dev/null || true

ln -sf "$RTL_DIR/softplus_pwl_coeffs.mem" softplus_pwl_coeffs.mem
ln -sf "$RTL_DIR/exp_pwl_coeffs.mem" exp_pwl_coeffs.mem

XVLOG="${XVLOG:-/tools/Xilinx/2025.1/Vivado/bin/xvlog}"
XELAB="${XELAB:-/tools/Xilinx/2025.1/Vivado/bin/xelab}"
XSIM="${XSIM:-/tools/Xilinx/2025.1/Vivado/bin/xsim}"

"$XVLOG" -d NUM_TOKENS="$N" \
  "$RTL_DIR/_parameter.v" \
  "$RTL_DIR/Unified_PE.v" \
  "$RTL_DIR/Softplus_Unit_PWL.v" \
  "$RTL_DIR/Exp_Unit.v" \
  "$RTL_DIR/Exp_Unit_PWL.v" \
  "$RTL_DIR/Scan_Channel_Exec.v" \
  "$RTL_DIR/Scan_YPre_Slot.v" \
  "$RTL_DIR/Scan_XZ_Engine.v" \
  "$RTL_DIR/Scan_Core_Streaming.v" \
  tb_scan_core_streaming.v 2>&1 | tee xsim_scan_stream.log | tail -20

"$XELAB" --relax tb_scan_core_streaming -s "tb_scan_stream_n${N}" 2>&1 | tail -8
"$XSIM" "tb_scan_stream_n${N}" -runall 2>&1 | tee -a xsim_scan_stream.log | tail -30

python3 compare_scan.py --dir "$ROOT" --tokens "$N"
