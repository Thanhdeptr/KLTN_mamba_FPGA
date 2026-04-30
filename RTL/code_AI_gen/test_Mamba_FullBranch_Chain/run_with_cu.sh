#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
RTL_DIR="$(cd "$ROOT/../../code_initial" && pwd)"

cd "$ROOT"

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
  "$RTL_DIR/Mamba_Control_Unit.v" \
  "$RTL_DIR/mamba_ip_top.v" \
  "$RTL_DIR/Mamba_Block_Wrapper.v" \
  tb_mamba_fullbranch_chain_cu.v

xelab --relax tb_mamba_fullbranch_chain_cu -s tb_mamba_fullbranch_chain_cu_sim
# Simulation timeout (seconds). Can be overridden by env `SIM_TIMEOUT`.
SIM_TIMEOUT=${SIM_TIMEOUT:-120}

# Run xsim with a wallclock timeout to avoid very long runs
timeout ${SIM_TIMEOUT}s xsim tb_mamba_fullbranch_chain_cu_sim \
  -testplusarg TOKENS=${TOKENS:-1000} -runall

python3 compare.py --dir .
