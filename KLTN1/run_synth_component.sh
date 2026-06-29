#!/usr/bin/env bash
# Synth ONE production component (not wrapper). Prints summary then exits.
# Usage: ./run_synth_component.sh <rmsnorm|inproj_v2|conv1d|scan_pipe|scan_ch_exec|outproj_v2>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
RTL="$REPO/RTL/code_initial"
OOC="$ROOT/ooc"
SCAN_MEM="$REPO/RTL/testbench/test_Scancore"
WORK="$ROOT/synth_work"
VIVADO="${VIVADO:-/tools/Xilinx/2025.1/Vivado/bin/vivado}"
PART="xck26-sfvc784-2LV-c"
CLK_NS="10.0"
BLOCK="${1:?usage: $0 <rmsnorm|inproj_v2|conv1d|scan_pipe|scan_ch_exec|outproj_v2>}"

PROD_SCAN_EXEC=6
PROD_MAX_TOKENS=1000
OOC_SCAN_EXEC=1
OOC_MAX_TOKENS=4
SYNTH_TIMEOUT=""
VIVADO_LOG=""

mkdir -p "$WORK"
for f in silu_pwl_coeffs.mem rmsnorm_rsqrt_coeffs.mem softplus_pwl_coeffs.mem exp_pwl_coeffs.mem \
         delta_before_softplus.mem A_vec.mem B_vec.mem C_vec.mem D_vec.mem; do
  case "$f" in
    delta*|A_vec*|B_vec*|C_vec*|D_vec*) src="$SCAN_MEM/$f" ;;
    *) src="$RTL/$f" ;;
  esac
  ln -sf "$src" "$WORK/$f"
done

declare -a RTL_FILES=()
TOP=""
NOTE=""
SYNTH_OPTS="-flatten_hierarchy rebuilt -mode out_of_context"

case "$BLOCK" in
  rmsnorm)
    TOP="RMSNorm_Unit_IntSqrt"
    NOTE="RMSNorm IntSqrt (production)"
    RTL_FILES=("$RTL/_parameter.v" "$RTL/RMSNorm_Unit_IntSqrt.v")
    ;;
  inproj_v2)
    TOP="In_Projection_Unit_Streaming_v2_ooc_top"
    NOTE="InProj streaming v2, 16-lane x 8-tap"
    RTL_FILES=("$RTL/_parameter.v" "$RTL/In_Projection_Unit_Streaming_v2.v" "$OOC/In_Projection_Unit_Streaming_v2_ooc_top.v")
    ;;
  conv1d)
    TOP="Conv1D_Layer_ooc_top"
    NOTE="Conv1D depthwise k=4, 8 MACs, FULL_WEIGHTS"
    RTL_FILES=(
      "$RTL/_parameter.v" "$RTL/Unified_PE.v" "$RTL/SiLU_Unit_PWL.v" "$RTL/SiLU_Unit.v"
      "$RTL/Conv1D_MAC.v" "$RTL/Conv1D_Layer.v" "$OOC/Conv1D_Layer_ooc_top.v"
    )
    ;;
  scan_pipe)
    TOP="Scan_Core_Streaming_Pipe_ooc_top"
    NOTE="Scan pipe NUM_EXEC=6 MAX_TOKENS=1000 h_live (H_STORE_FULL_HISTORY=0)"
    SYNTH_OPTS="-flatten_hierarchy none -directive RuntimeOptimized -mode out_of_context"
    SYNTH_TIMEOUT="90m"
    VIVADO_LOG="${ROOT}/vivado_comp_scan_pipe.log"
    RTL_FILES=(
      "$RTL/_parameter.v" "$RTL/Unified_PE.v" "$RTL/Softplus_Unit_PWL.v"
      "$RTL/SiLU_Unit_PWL.v" "$RTL/SiLU_Unit.v"
      "$RTL/Exp_Unit.v" "$RTL/Exp_Unit_PWL.v" "$RTL/Scan_Core_Engine.v"
      "$RTL/Scan_Channel_Exec.v"       "$RTL/Scan_YPre_Slot.v" "$RTL/Scan_XZ_Engine.v"
      "$RTL/Scan_Sync_Rom16.v" "$RTL/Scan_Wide_Rom256.v"
      "$RTL/Scan_Core_Streaming_Pipe.v" "$RTL/Scan_HMem_SubBank.v" "$RTL/Scan_HMem_Banked.v"
      "$RTL/Scan_HState_Live.v"
      "$OOC/Scan_Core_Streaming_Pipe_ooc_top.v"
    )
    ;;
  scan_ch_exec)
    TOP="Scan_Channel_Exec_ooc_top"
    NOTE="Scan_Channel_Exec x1 (scale x${PROD_SCAN_EXEC} for full pipe exec DSP/LUT)"
    SYNTH_OPTS="-flatten_hierarchy none -directive RuntimeOptimized -mode out_of_context"
    SYNTH_TIMEOUT="20m"
    VIVADO_LOG="${ROOT}/vivado_comp_scan_ch_exec.log"
    RTL_FILES=(
      "$RTL/_parameter.v" "$RTL/Unified_PE.v" "$RTL/Softplus_Unit_PWL.v"
      "$RTL/SiLU_Unit_PWL.v" "$RTL/SiLU_Unit.v"
      "$RTL/Exp_Unit.v" "$RTL/Exp_Unit_PWL.v" "$RTL/Scan_Core_Engine.v"
      "$RTL/Scan_Channel_Exec.v" "$OOC/Scan_Channel_Exec_ooc_top.v"
    )
    ;;
  outproj_v2)
    TOP="Out_Projection_Streaming_v2_ooc_top"
    NOTE="OutProj v2 NUM_MAC=4 USE_BRAM_WEIGHTS (OOC top)"
    SYNTH_OPTS="-flatten_hierarchy none -mode out_of_context"
    VIVADO_LOG="${ROOT}/vivado_comp_outproj_v2.log"
    RTL_FILES=("$RTL/_parameter.v" "$RTL/Out_Projection_Streaming_v2.v" "$OOC/Out_Projection_Streaming_v2_ooc_top.v")
    ;;
  *)
    echo "Unknown block: $BLOCK" >&2
    exit 1
    ;;
esac

TAG="comp_${BLOCK}"
PROJ="${ROOT}/synth_proj/${TAG}"
TCL="/tmp/synth_${TAG}.tcl"
DCP="${ROOT}/synth_${TAG}.dcp"

echo "========================================"
echo " SYNTH COMPONENT: $BLOCK"
echo " Top: $TOP"
echo " Note: $NOTE"
echo " Synth: $SYNTH_OPTS"
echo " Clock: ${CLK_NS} ns (100 MHz)"
echo " Part: $PART"
echo "========================================"

{
  echo "create_project -force ${TAG} ${PROJ} -part ${PART}"
  for f in "${RTL_FILES[@]}"; do echo "read_verilog ${f}"; done
  echo "read_xdc ${ROOT}/synth_ooc_common.xdc"
  echo "set_property include_dirs [list ${RTL}] [current_fileset]"
  echo "set_property top ${TOP} [current_fileset]"
  echo "synth_design -top ${TOP} ${SYNTH_OPTS}"
  echo "write_checkpoint -force ${DCP}"
  echo "report_utilization -hierarchical -file ${ROOT}/synth_util_${TAG}.txt"
  echo "report_utilization -file ${ROOT}/synth_util_${TAG}_flat.txt"
  echo "report_timing_summary -file ${ROOT}/synth_timing_${TAG}.txt -delay_type min_max -report_unconstrained"
  echo "report_timing -max_paths 20 -file ${ROOT}/synth_timing_${TAG}_paths.txt"
  echo "close_project"
} > "$TCL"

VIVADO_ARGS=(-mode batch -source "$TCL")
if [[ -n "$VIVADO_LOG" ]]; then
  VIVADO_ARGS+=(-log "$VIVADO_LOG" -journal "${VIVADO_LOG%.log}.jou")
else
  VIVADO_ARGS+=(-nojournal -nolog)
fi

VIVADO_CMD="cd $(printf '%q' "$WORK") && $(printf '%q' "$VIVADO")"
for arg in "${VIVADO_ARGS[@]}"; do
  VIVADO_CMD+=" $(printf '%q' "$arg")"
done

RUN_LOG="${ROOT}/synth_run_${TAG}.log"
if [[ -n "$SYNTH_TIMEOUT" ]]; then
  echo " Timeout: ${SYNTH_TIMEOUT}  Log: ${VIVADO_LOG:-nolog}"
  timeout "$SYNTH_TIMEOUT" bash -c "$VIVADO_CMD" 2>&1 | tee "$RUN_LOG" | tail -20
else
  echo " Log: ${VIVADO_LOG:-nolog}  Run: ${RUN_LOG}"
  bash -c "$VIVADO_CMD" 2>&1 | tee "$RUN_LOG" | tail -20
fi

python3 - "$ROOT" "$TAG" "$BLOCK" "$NOTE" "$CLK_NS" <<'PY'
import re, sys
from pathlib import Path
root, tag, block, note, clk_ns = sys.argv[1:6]
util_p = Path(root) / f"synth_util_{tag}_flat.txt"
tim_p  = Path(root) / f"synth_timing_{tag}.txt"
ut = util_p.read_text(errors="ignore")
tm = tim_p.read_text(errors="ignore")

def grab(pat, text):
    m = re.search(pat, text)
    return m.group(1) if m else "n/a"

lut  = grab(r"\|\s*CLB LUTs\*\s*\|\s*(\d+)", ut)
ff   = grab(r"\|\s*CLB Registers\s*\|\s*(\d+)", ut)
dsp  = grab(r"\|\s*DSPs\s*\|\s*(\d+)", ut)
bram = grab(r"\|\s*Block RAM Tile\s*\|\s*(\d+)", ut)
m = re.search(
    r"Design Timing Summary[\s\S]{0,800}?\n\s+([-\d\.]+)\s+([-\d\.]+)\s+\d+\s+\d+\s+([-\d\.]+)",
    tm,
)
if m:
    wns, tns, whs = m.group(1), m.group(2), m.group(3)
else:
    wns = tns = whs = "n/a"
try:
    wns_f = float(wns)
    status = "PASS" if wns_f >= 0 else "FAIL"
    fmax = 1000.0 / (float(clk_ns) - wns_f) if wns_f >= 0 else 0
    fmax_s = f"{fmax:.1f}"
except ValueError:
    status = "?"
    fmax_s = "n/a"

print()
print("-------- RESULT:", block, "--------")
print(f"  Module : {note}")
print(f"  Timing : WNS={wns} ns  TNS={tns} ns  WHS={whs} ns  => {status}")
print(f"  Fmax   : {fmax_s} MHz (est. from WNS @ {clk_ns}ns)")
print(f"  LUT    : {lut}")
print(f"  FF     : {ff}")
print(f"  DSP    : {dsp}")
print(f"  BRAM   : {bram}")
print(f"  DCP    : {Path(root) / ('synth_' + tag + '.dcp')}")
print(f"  GUI    : vivado -mode gui -source {Path(root) / 'open_synth_component_gui.tcl'} -tclargs {block}")
print(f"  Note   : open_checkpoint + report_* in GUI; do not open_report on .txt files")
if block == "scan_ch_exec":
    try:
        lut_i, ff_i, dsp_i, bram_i = int(lut), int(ff), int(dsp), int(bram)
        scale = 6
        print(f"  Scale  : x{scale} exec -> LUT~{lut_i*scale} FF~{ff_i*scale} DSP~{dsp_i*scale} (pipe overhead extra)")
    except ValueError:
        pass
elif block == "scan_pipe":
    try:
        bram_i = int(bram)
        print(f"  Note   : h_live mode; h BRAM ~2 tiles (independent of MAX_TOKENS)")
        print(f"  Note   : delta/B/C ROM scale with MAX_TOKENS in OOC INIT_WEIGHT_MEM=1")
    except ValueError:
        pass
print("--------------------------------")
PY
