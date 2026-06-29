#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
RTL_DIR="$(cd "$ROOT/../RTL/code_initial" && pwd)"
OUT="$ROOT"

echo "[Synth] RMSNorm_Unit_IntSqrt OOC on xck26-sfvc784-2LV-c @ 125 MHz (8 ns)"

cat > /tmp/synth_rmsnorm_ooc.tcl <<TCL
create_project -force rmsnorm_ooc /tmp/rmsnorm_ooc -part xck26-sfvc784-2LV-c
read_verilog ${RTL_DIR}/_parameter.v
read_verilog ${RTL_DIR}/RMSNorm_Unit_IntSqrt.v
read_xdc ${ROOT}/synth_rmsnorm_ooc.xdc
set_property top RMSNorm_Unit_IntSqrt [current_fileset]
synth_design -top RMSNorm_Unit_IntSqrt -flatten_hierarchy rebuilt -mode out_of_context
report_utilization -file ${OUT}/synth_utilization_rmsnorm.txt -hierarchical
report_utilization -file ${OUT}/synth_utilization_rmsnorm_flat.txt
report_timing_summary -file ${OUT}/synth_timing_rmsnorm.txt
report_timing -max_paths 10 -file ${OUT}/synth_timing_rmsnorm_paths.txt
TCL

cd "$RTL_DIR"
/tools/Xilinx/2025.1/Vivado/bin/vivado -mode batch -nojournal -nolog -source /tmp/synth_rmsnorm_ooc.tcl 2>&1 | tail -40

echo ""
echo "=== Utilization (top) ==="
grep -E "Slice LUTs|Slice Registers|DSPs|Block RAM|CLB LUTs" "$OUT/synth_utilization_rmsnorm_flat.txt" | head -10

echo ""
echo "=== Timing @ 125 MHz ==="
grep -E "WNS|TNS|WHS|THS|Timing" "$OUT/synth_timing_rmsnorm.txt" | head -20

echo ""
echo "Reports:"
echo "  $OUT/synth_utilization_rmsnorm.txt"
echo "  $OUT/synth_timing_rmsnorm.txt"
