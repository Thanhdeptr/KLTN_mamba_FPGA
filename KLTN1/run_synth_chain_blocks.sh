#!/usr/bin/env bash
# OOC synthesis for PRODUCTION component modules (no wrappers).
#
# Modules (same as RMSNorm_InProj_Conv_Scan_Chain_Wrapper internals + OutProj v2):
#   rmsnorm      - RMSNorm_Unit_IntSqrt
#   inproj_v2    - In_Projection_Unit_Streaming_v2
#   conv1d       - Conv1D_Layer (NUM_MAC=8)
#   scan_pipe    - Scan_Core_Streaming_Pipe (NUM_EXEC=6)
#   outproj_v2   - Out_Projection_Streaming_v2 (NUM_MAC=16)
#
# Usage: ./run_synth_chain_blocks.sh [rmsnorm|inproj_v2|conv1d|scan_pipe|outproj_v2|all]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
RTL="$REPO/RTL/code_initial"
OOC="$ROOT/ooc"
WORK="$ROOT/synth_work"
VIVADO="${VIVADO:-/tools/Xilinx/2025.1/Vivado/bin/vivado}"
PART="xck26-sfvc784-2LV-c"
CLK_NS="10.0"
FILTER="${1:-all}"

mkdir -p "$WORK"
ln -sf "$RTL/silu_pwl_coeffs.mem"      "$WORK/silu_pwl_coeffs.mem"
ln -sf "$RTL/rmsnorm_rsqrt_coeffs.mem" "$WORK/rmsnorm_rsqrt_coeffs.mem"
ln -sf "$RTL/softplus_pwl_coeffs.mem"  "$WORK/softplus_pwl_coeffs.mem"
ln -sf "$RTL/exp_pwl_coeffs.mem"       "$WORK/exp_pwl_coeffs.mem"

manifest="${ROOT}/synth_chain_manifest.txt"
: > "${manifest}"
echo "# module|clk_ns|tag|note" >> "${manifest}"

run_block() {
  local name="$1"
  local top="$2"
  local tag="$3"
  local note="$4"
  shift 4
  local -a rtl_files=("$@")

  echo ""
  echo "================================================================"
  echo "[Synth] $name"
  echo "        top=$top  @ ${CLK_NS}ns  part=$PART"
  echo "        $note"
  echo "================================================================"

  local proj="/tmp/synth_comp_${tag}"
  local tcl="/tmp/synth_comp_${tag}.tcl"

  {
    echo "create_project -force ${tag} ${proj} -part ${PART}"
    for f in "${rtl_files[@]}"; do
      echo "read_verilog ${f}"
    done
    echo "read_xdc ${ROOT}/synth_ooc_common.xdc"
    echo "set_property include_dirs [list ${RTL}] [current_fileset]"
    echo "set_property top ${top} [current_fileset]"
    echo "synth_design -top ${top} -flatten_hierarchy rebuilt -mode out_of_context"
    echo "report_utilization -file ${ROOT}/synth_util_${tag}.txt -hierarchical"
    echo "report_utilization -file ${ROOT}/synth_util_${tag}_flat.txt"
    echo "report_timing_summary -file ${ROOT}/synth_timing_${tag}.txt -delay_type min_max -report_unconstrained"
    echo "report_timing -max_paths 10 -file ${ROOT}/synth_timing_${tag}_paths.txt"
    echo "close_project"
  } > "${tcl}"

  (cd "$WORK" && "${VIVADO}" -mode batch -nojournal -nolog -source "${tcl}") 2>&1 | tail -25
  echo "${name}|${CLK_NS}|${tag}|${note}" >> "${manifest}"
}

should_run() {
  [[ "${FILTER}" == "all" || "${FILTER}" == "$1" ]]
}

if should_run "rmsnorm"; then
  run_block "RMSNorm_Unit_IntSqrt" "RMSNorm_Unit_IntSqrt_ooc_top" "rmsnorm" \
    "IntSqrt RMSNorm per-token" \
    "$RTL/_parameter.v" "$RTL/RMSNorm_Unit_IntSqrt.v" "$OOC/RMSNorm_Unit_IntSqrt_ooc_top.v"
fi

if should_run "inproj_v2"; then
  run_block "In_Projection_Unit_Streaming_v2" "In_Projection_Unit_Streaming_v2_ooc_top" "inproj_v2" \
    "16-bank BRAM, 128 MAC/tap" \
    "$RTL/In_Projection_Unit_Streaming_v2.v" "$OOC/In_Projection_Unit_Streaming_v2_ooc_top.v"
fi

if should_run "conv1d"; then
  run_block "Conv1D_Layer" "Conv1D_Layer_ooc_top" "conv1d" \
    "NUM_MAC=8 depthwise k=4 + dual SiLU" \
    "$RTL/_parameter.v" "$RTL/SiLU_Unit_PWL.v" "$RTL/SiLU_Unit.v" \
    "$RTL/Conv1D_MAC.v" "$RTL/Conv1D_Layer.v" "$OOC/Conv1D_Layer_ooc_top.v"
fi

if should_run "scan_pipe"; then
  run_block "Scan_Core_Streaming_Pipe" "Scan_Core_Streaming_Pipe_ooc_top" "scan_pipe" \
    "NUM_EXEC=6 MAX_TOKENS=16 pipeline scan" \
    "$RTL/_parameter.v" "$RTL/Unified_PE.v" "$RTL/Softplus_Unit_PWL.v" \
    "$RTL/Exp_Unit.v" "$RTL/Exp_Unit_PWL.v" "$RTL/Scan_Core_Engine.v" \
    "$RTL/Scan_Channel_Exec.v" "$RTL/Scan_YPre_Slot.v" "$RTL/Scan_XZ_Engine.v" \
    "$RTL/Scan_Core_Streaming_Pipe.v" "$RTL/Scan_HMem_SubBank.v" "$RTL/Scan_HMem_Banked.v" \
    "$RTL/Scan_HState_Live.v" "$OOC/Scan_Core_Streaming_Pipe_ooc_top.v"
fi

if should_run "outproj_v2"; then
  run_block "Out_Projection_Streaming_v2" "Out_Projection_Streaming_v2_ooc_top" "outproj_v2" \
    "NUM_MAC=16 streaming OutProj" \
    "$RTL/_parameter.v" "$RTL/Out_Projection_Streaming_v2.v" "$OOC/Out_Projection_Streaming_v2_ooc_top.v"
fi

python3 "${ROOT}/parse_synth_chain_summary.py" "${ROOT}" "${manifest}"

echo ""
echo "Done. Summary: ${ROOT}/synth_chain_summary.md"
