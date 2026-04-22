#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-smoke}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
RTL_DIR="$(cd "$ROOT/../../code_initial" && pwd)"

cd "$ROOT"

CALLER_TOKENS="${TOKENS:-}"

TAIL_GOLDEN_SOURCE="${TAIL_GOLDEN_SOURCE:-rebuild}"
python3 prepare_mem.py --tail-golden-source "$TAIL_GOLDEN_SOURCE"
cp "$RTL_DIR/silu_pwl_coeffs.mem" .
cp "$RTL_DIR/exp_pwl_coeffs.mem" .

if [[ "$MODE" == "smoke" ]]; then
  TOKENS=64
  echo "[run] smoke mode (TOKENS=$TOKENS)"
else
  TOKENS=1000
  echo "[run] full mode (TOKENS=$TOKENS)"
fi

# Allow caller overrides: TOKENS=... (or TOKENS_OVERRIDE=...), TRACE=1 TRACE_CH=... TRACE_TOKEN=...
TOKENS="${TOKENS_OVERRIDE:-${CALLER_TOKENS:-$TOKENS}}"
TRACE="${TRACE:-0}"
TRACE_CH="${TRACE_CH:-0}"
TRACE_TOKEN="${TRACE_TOKEN:-0}"

rm -rf xsim.dir .Xil *.log *.jou *.pb rtl_*.mem || true

xvlog \
  "$RTL_DIR/_parameter.v" \
  "$RTL_DIR/SiLU_Unit.v" \
  "$RTL_DIR/Exp_Unit_PWL.v" \
  "$RTL_DIR/Exp_Unit.v" \
  "$RTL_DIR/SiLU_Unit_PWL.v" \
  "$RTL_DIR/RMSNorm_Unit_IntSqrt.v" \
  "$RTL_DIR/In_Projection_Unit.v" \
  "$RTL_DIR/Conv1D_Layer.v" \
  "$RTL_DIR/Scan_Core_Engine.v" \
  "$RTL_DIR/Unified_PE.v" \
  "$RTL_DIR/Out_Projection_Unit.v" \
  Mamba_Block_Wrapper.v \
  tb_mamba_fullbranch_chain.v

xelab --relax tb_mamba_fullbranch_chain -s tb_mamba_fullbranch_chain_sim
xsim tb_mamba_fullbranch_chain_sim \
  -testplusarg TOKENS=$TOKENS \
  -testplusarg TRACE=$TRACE \
  -testplusarg TRACE_CH=$TRACE_CH \
  -testplusarg TRACE_TOKEN=$TRACE_TOKEN \
  -runall

python3 compare.py --dir .

