#!/usr/bin/env bash
set -euo pipefail

# Run simulation for In_Projection_Unit_Pipelined testbench
# Usage: ./run.sh

ROOT="$(cd "$(dirname "$0")" && pwd)"
RTL_DIR="$(cd "$ROOT/../../code_initial" && pwd)"

echo "[Run] In_Projection_Unit_Pipelined Test"
echo "  Test dir: $ROOT"
echo "  RTL dir:  $RTL_DIR"

cd "$ROOT"

# Clean up previous runs
rm -rf xsim.dir .Xil *.log *.jou *.pb rtl_output_pipeline.mem || true

# Step 1: Compile sources with xvlog
echo "[Step 1] Compiling sources..."
/tools/Xilinx/2025.1/Vivado/bin/xvlog --sv -i . \
  "$RTL_DIR/_parameter.v" \
  "$RTL_DIR/In_Projection_Unit_Pipelined.v" \
  tb_in_projection_unit_pipeline.v

# Step 2: Elaborate with xelab
echo "[Step 2] Elaborating design..."
/tools/Xilinx/2025.1/Vivado/bin/xelab --relax tb_in_projection_unit_pipeline -s tb_pipeline_sim

# Step 3: Run simulation with xsim
echo "[Step 3] Running simulation..."
/tools/Xilinx/2025.1/Vivado/bin/xsim tb_pipeline_sim -runall

# Step 4: Compare outputs
echo "[Step 4] Comparing RTL output vs golden..."
if [ -f rtl_output_pipeline.mem ]; then
    python3 compare_rtl_vs_golden.py
else
    echo "ERROR: rtl_output_pipeline.mem not generated!"
    exit 1
fi

echo ""
echo "Test completed!"
