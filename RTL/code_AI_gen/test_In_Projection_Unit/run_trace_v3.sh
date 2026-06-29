#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
RTL_DIR="$(cd "$ROOT/../../code_initial" && pwd)"
cd "$ROOT"
rm -rf xsim.dir trace_v3.log
echo "[Trace] Compiling v3 with tb_trace_v3..."
/tools/Xilinx/2025.1/Vivado/bin/xvlog --sv -i . \
  "$RTL_DIR/_parameter.v" \
  "$RTL_DIR/In_Projection_Unit_Streaming_v3.v" \
  tb_trace_v3.v 2>&1 | tail -5
/tools/Xilinx/2025.1/Vivado/bin/xelab --relax tb_trace_v3 -s tb_trace_v3_sim 2>&1 | tail -3
/tools/Xilinx/2025.1/Vivado/bin/xsim tb_trace_v3_sim -runall 2>&1 | tail -10
echo ""
python3 parse_trace_v3.py
