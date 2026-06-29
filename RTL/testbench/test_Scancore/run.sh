#!/usr/bin/env bash
set -euo pipefail

N="${1:-1}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
KLTN_ROOT="$(cd "$ROOT/../../.." && pwd)"
RTL_DIR="$(cd "$ROOT/../../code_initial" && pwd)"

echo "[Run] Scan Core Streaming standalone N=$N"
cd "$ROOT"

if [ "${REGEN_MEM:-1}" = "1" ]; then
  echo "[Regen] scancore .mem from ITMN cpp_golden_files"
  PYTHONPATH="${KLTN_ROOT}/ITMN" python3 "${KLTN_ROOT}/py_software/extract_RTL_inital_mem.py" --mode scancore
fi

rm -rf xsim.dir .Xil xsim_scan_stream.log 2>/dev/null || true

ln -sf "$RTL_DIR/softplus_pwl_coeffs.mem" softplus_pwl_coeffs.mem
ln -sf "$RTL_DIR/exp_pwl_coeffs.mem" exp_pwl_coeffs.mem
ln -sf "$RTL_DIR/silu_pwl_coeffs.mem" silu_pwl_coeffs.mem

XVLOG="${XVLOG:-/tools/Xilinx/2025.1/Vivado/bin/xvlog}"
XELAB="${XELAB:-/tools/Xilinx/2025.1/Vivado/bin/xelab}"
XSIM="${XSIM:-/tools/Xilinx/2025.1/Vivado/bin/xsim}"

XVLOG_DEFS=(-d "NUM_TOKENS=$N")
if [ "${SCAN_PIPE:-0}" = "1" ]; then
  XVLOG_DEFS+=(-d SCAN_PIPE=1)
  SCAN_RTL=(
    "$RTL_DIR/Scan_Core_Engine.v"
    "$RTL_DIR/Scan_Channel_Exec.v"
    "$RTL_DIR/Scan_Pipe_Types.vh"
    "$RTL_DIR/Scan_Vector_Mul16.v"
    "$RTL_DIR/Scan_HMem_SubBank.v"
    "$RTL_DIR/Scan_HMem_Banked.v"
    "$RTL_DIR/Scan_HState_Live.v"
    "$RTL_DIR/Scan_Sync_Rom16.v"
    "$RTL_DIR/Scan_Wide_Rom256.v"
    "$RTL_DIR/Scan_Core_Streaming_Pipe.v"
  )
else
  SCAN_RTL=(
    "$RTL_DIR/Scan_Core_Engine.v"
    "$RTL_DIR/Scan_Channel_Exec.v"
    "$RTL_DIR/Scan_Core_Streaming.v"
  )
fi
if [ "${SCAN_H_LIVE:-0}" = "1" ]; then
  XVLOG_DEFS+=(-d SCAN_H_LIVE=1)
fi
if [ "${USE_DELTA_FINAL:-0}" = "1" ]; then
  XVLOG_DEFS+=(-d BYPASS_SOFTPLUS=1 -d USE_DELTA_FINAL=1)
fi
"$XVLOG" "${XVLOG_DEFS[@]}" \
  "$RTL_DIR/_parameter.v" \
  "$RTL_DIR/Unified_PE.v" \
  "$RTL_DIR/Softplus_Unit_PWL.v" \
  "$RTL_DIR/SiLU_Unit_PWL.v" \
  "$RTL_DIR/Exp_Unit.v" \
  "$RTL_DIR/Exp_Unit_PWL.v" \
  "${SCAN_RTL[@]}" \
  "$RTL_DIR/Scan_YPre_Slot.v" \
  "$RTL_DIR/Scan_XZ_Engine.v" \
  "$RTL_DIR/Scan_BeatCtx_FIFO.v" \
  "$RTL_DIR/Scan_Delta_Engine.v" \
  tb_scan_core_streaming.v 2>&1 | tee xsim_scan_stream.log | tail -20

"$XELAB" --relax tb_scan_core_streaming -s "tb_scan_stream_n${N}" 2>&1 | tail -8
SIM_TIMEOUT_SEC="${SIM_TIMEOUT_SEC:-7200}"
XSIM_EXTRA=(--maxdeltaid 10000000)
timeout "$SIM_TIMEOUT_SEC" "$XSIM" "${XSIM_EXTRA[@]}" "tb_scan_stream_n${N}" -runall 2>&1 | tee -a xsim_scan_stream.log | tail -40
XSIM_RC=${PIPESTATUS[0]}
if [ "$XSIM_RC" -eq 124 ]; then
  echo "FAIL: xsim exceeded ${SIM_TIMEOUT_SEC}s timeout (N=$N)"
  exit 1
fi
if [ "$XSIM_RC" -ne 0 ]; then
  exit "$XSIM_RC"
fi

# PASS: RTL y_gated vs cpp float golden (golden_y_gated.mem, includes D*x).
COMPARE_ARGS=(--dir "$ROOT" --tokens "$N")
if [ "${SCAN_H_LIVE:-0}" = "1" ]; then
  COMPARE_ARGS+=(--skip-h)
fi
python3 compare_scan.py "${COMPARE_ARGS[@]}"
