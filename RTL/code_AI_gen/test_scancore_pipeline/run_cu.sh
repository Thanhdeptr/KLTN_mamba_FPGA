#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
RTL_DIR="$(cd "$ROOT/../../code_initial" && pwd)"

cd "$ROOT"

rm -rf xsim.dir .Xil *.log *.jou *.pb || true

xvlog \
  "$RTL_DIR/_parameter.v" \
  "$RTL_DIR/Mamba_Control_Unit.v" \
  tb_mamba_cu_demo.v

xelab --relax tb_mamba_cu_demo -s tb_mamba_cu_demo_sim
xsim tb_mamba_cu_demo_sim -runall

echo "CU demo finished"
