#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
VIVADO="${VIVADO:-/tools/Xilinx/2025.1/Vivado/bin/vivado}"
echo "[Synth] In_Projection_Unit_Streaming_v3 on xck26-sfvc784-2LV-c"
"$VIVADO" -mode batch -source "$ROOT/synth_inproj_v3.tcl" -log "$ROOT/synth_v3.log" -journal "$ROOT/synth_v3.jou"
echo ""
echo "=== DSP / Utilization (grep) ==="
grep -A3 "ARITHMETIC" "$ROOT/synth_utilization_v3_flat.txt" || true
grep "DSPs" "$ROOT/synth_utilization_v3_flat.txt" || true
grep "DSP Blocks" "$ROOT/synth_utilization_v3.txt" || true
echo ""
echo "=== Timing summary ==="
cat "$ROOT/synth_summary_v3.txt"
