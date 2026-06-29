#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
RTL="$REPO/RTL/code_initial"
VIVADO="${VIVADO:-/tools/Xilinx/2025.1/Vivado/bin/vivado}"

cat > "$ROOT/synth_scan.tcl" <<'TCL'
set script_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize $script_dir/..]
set rtl_dir $repo_root/RTL/code_initial
set proj_dir $script_dir/scan_synth
set part xck26-sfvc784-2LV-c
set top Scan_Core_Streaming_ooc_top
set clk_period_ns 10.0

set rtl_files [list \
  $rtl_dir/_parameter.v \
  $rtl_dir/Unified_PE.v \
  $rtl_dir/Softplus_Unit_PWL.v \
  $rtl_dir/SiLU_Unit_PWL.v \
  $rtl_dir/Exp_Unit.v \
  $rtl_dir/Exp_Unit_PWL.v \
  $rtl_dir/Scan_Core_Engine.v \
  $rtl_dir/Scan_Channel_Exec.v \
  $rtl_dir/Scan_YPre_Slot.v \
  $rtl_dir/Scan_XZ_Engine.v \
  $rtl_dir/Scan_BeatCtx_FIFO.v \
  $rtl_dir/Scan_Delta_Engine.v \
  $rtl_dir/Scan_Core_Streaming.v \
  $script_dir/Scan_Core_Streaming_ooc_top.v \
]

file mkdir $proj_dir
cd $proj_dir
create_project -force scan_synth $proj_dir -part $part
foreach f $rtl_files { read_verilog $f }
read_xdc $script_dir/synth_scan_ooc.xdc
set_property top $top [current_fileset]
synth_design -top $top -part $part -flatten_hierarchy rebuilt
report_utilization -file $script_dir/synth_utilization_scan.txt -hierarchical
report_utilization -file $script_dir/synth_utilization_scan_flat.txt
report_timing_summary -file $script_dir/synth_timing_scan.txt -delay_type min_max -report_unconstrained
report_timing -max_paths 20 -file $script_dir/synth_timing_scan_paths.txt
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set summary_fp [open $script_dir/synth_summary_scan.txt w]
puts $summary_fp "Design: $top"
puts $summary_fp "WNS: $wns ns @ ${clk_period_ns} ns"
close $summary_fp
close_project
TCL

echo "[Synth] Scan_Core_Streaming OOC"
"$VIVADO" -mode batch -source "$ROOT/synth_scan.tcl" -log "$ROOT/synth_scan.log" -journal "$ROOT/synth_scan.jou"
grep -E "DSP|Slice|LUT" "$ROOT/synth_utilization_scan_flat.txt" | head -20 || true
cat "$ROOT/synth_summary_scan.txt" 2>/dev/null || true
