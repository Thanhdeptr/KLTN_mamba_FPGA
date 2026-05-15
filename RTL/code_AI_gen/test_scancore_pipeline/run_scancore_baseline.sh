#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
RTL_DIR="$(cd "$ROOT/../../code_initial" && pwd)"
cd "$ROOT"

echo "[run_scancore_baseline] compiling and running baseline-instrumented Scan_Core_Engine testbench"

rm -rf xsim.dir .Xil *.log *.jou *.pb rtl_*.mem || true

xvlog \
  "$RTL_DIR/_parameter.v" \
  "$RTL_DIR/Unified_PE.v" \
  "$RTL_DIR/SiLU_Unit.v" \
  "$RTL_DIR/Exp_Unit_PWL.v" \
  "$RTL_DIR/Exp_Unit.v" \
  "$RTL_DIR/SiLU_Unit_PWL.v" \
  Scan_Core_Engine_baseline_instr.v \
  tb_scan_core_baseline.v

xelab --relax tb_scan_core_baseline -s tb_scan_core_baseline_sim

eval xsim tb_scan_core_baseline_sim -runall

echo "[run_scancore_baseline] finished"
