#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
RTL_DIR="$(cd "$ROOT/../../code_initial" && pwd)"
cd "$ROOT"

echo "[run_scancore] compiling and running Scan_Core_Engine_pipe1 testbench"

rm -rf xsim.dir .Xil *.log *.jou *.pb rtl_*.mem || true

xvlog \
  "$RTL_DIR/_parameter.v" \
  "$RTL_DIR/Unified_PE.v" \
  "$RTL_DIR/SiLU_Unit.v" \
  "$RTL_DIR/Exp_Unit_PWL.v" \
  "$RTL_DIR/Exp_Unit.v" \
  "$RTL_DIR/SiLU_Unit_PWL.v" \
  Scan_Core_Engine_pipe1.v \
  Pipeline_Monitor.v \
  tb_scan_core_pipe.v

xelab --relax tb_scan_core_pipe -s tb_scan_core_pipe_sim

# run with optional TRACE/timeout
TRACE_ARG="-testplusarg TRACE=${TRACE:-0} -testplusarg TRACE_CH=${TRACE_CH:-0} -testplusarg TRACE_TOKEN=${TRACE_TOKEN:-0}"
MONITOR_DIR_ARG="-testplusarg MONITOR_DIR=${ROOT}"
TRACE_ARG="-testplusarg TRACE=${TRACE:-0} -testplusarg TRACE_CH=${TRACE_CH:-0} -testplusarg TRACE_TOKEN=${TRACE_TOKEN:-0}"
eval xsim tb_scan_core_pipe_sim $MONITOR_DIR_ARG $TRACE_ARG -runall

echo "[run_scancore] finished"
