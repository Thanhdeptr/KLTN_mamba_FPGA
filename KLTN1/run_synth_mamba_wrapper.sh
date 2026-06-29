#!/usr/bin/env bash
# OOC synthesis: full Mamba_Streaming_Block_Wrapper (production streaming path).
# Prereq: component OOC synth done (rmsnorm, inproj, conv, scan_pipe, outproj).
#
# Usage: ./run_synth_mamba_wrapper.sh [n1|n1_opt|quick|n100|prod]
#   n1     - legacy synth (flatten rebuilt)
#   n1_opt - N=1 optimized: flatten none, BRAM weights/queues, small FIFO depths
#   quick - MAX_TOKENS=16  CHAIN_Q=64   NUM_EXEC=2  (smoke)
#   n100  - MAX_TOKENS=100 CHAIN_Q=1824 NUM_EXEC=1  (fit study)
#   prod  - MAX_TOKENS=1000 CHAIN_Q=9024 NUM_EXEC=2
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
RTL="$REPO/RTL/code_initial"
OOC="$ROOT/ooc"
SCAN_MEM="$REPO/RTL/testbench/test_Scancore"
FB_MEM="$REPO/RTL/code_AI_gen/test_Mamba_FullBranch_Chain"
WORK="$ROOT/synth_work"
VIVADO="${VIVADO:-/tools/Xilinx/2025.1/Vivado/bin/vivado}"
PART="xck26-sfvc784-2LV-c"
CLK_NS="10.0"
MODE="${1:-n1}"

mkdir -p "$WORK"
for f in silu_pwl_coeffs.mem rmsnorm_rsqrt_coeffs.mem softplus_pwl_coeffs.mem exp_pwl_coeffs.mem \
         delta_before_softplus.mem A_vec.mem B_vec.mem C_vec.mem D_vec.mem; do
  case "$f" in
    delta*|A_vec*|B_vec*|C_vec*|D_vec*) src="$SCAN_MEM/$f" ;;
    *) src="$RTL/$f" ;;
  esac
  ln -sf "$src" "$WORK/$f"
done
ln -sf "$FB_MEM/outproj_weight.mem" "$WORK/outproj_weight.mem"

TOP="Mamba_Streaming_Block_Wrapper_ooc_top"
TAG="mamba_wrapper_${MODE}"
PROJ="${ROOT}/synth_proj/${TAG}"
DCP="${ROOT}/synth_${TAG}.dcp"
TCL="/tmp/synth_${TAG}.tcl"
VIVADO_LOG="${ROOT}/vivado_comp_${TAG}.log"
RUN_LOG="${ROOT}/synth_run_${TAG}.log"

if [[ "$MODE" == "n1_opt" ]]; then
  SYNTH_DEFINES='set_property verilog_define {OOC_MAX_TOKENS=1 OOC_CHAIN_Q=16 OOC_NUM_EXEC=1 OOC_Z_FIFO_DEPTH=16 OOC_BEAT_Q_DEPTH=16 OOC_BX_DEPTH=16 OOC_XP_OVF_DEPTH=8 OOC_ZP_OVF_DEPTH=8} [current_fileset]'
  SYNTH_TIMEOUT="90m"
  SYNTH_JOBS=1
  SYNTH_FLAT="-flatten_hierarchy none -directive RuntimeOptimized"
  NOTE="Mamba wrapper N1_OPT (N=1 Q=16 exec=1 BRAM+flatten_none)"
elif [[ "$MODE" == "n1" ]]; then
  SYNTH_DEFINES='set_property verilog_define {OOC_MAX_TOKENS=1 OOC_CHAIN_Q=16 OOC_NUM_EXEC=1} [current_fileset]'
  SYNTH_TIMEOUT="90m"
  SYNTH_JOBS=1
  SYNTH_FLAT="-flatten_hierarchy rebuilt -directive RuntimeOptimized"
  NOTE="Mamba wrapper N1 (N=1 CHAIN_Q=16 NUM_EXEC=1)"
elif [[ "$MODE" == "quick" ]]; then
  SYNTH_DEFINES='set_property verilog_define {OOC_MAX_TOKENS=16 OOC_CHAIN_Q=64 OOC_NUM_EXEC=2} [current_fileset]'
  SYNTH_TIMEOUT="90m"
  SYNTH_JOBS=4
  SYNTH_FLAT="-flatten_hierarchy rebuilt -directive RuntimeOptimized"
  NOTE="Mamba wrapper QUICK (N=16 CHAIN_Q=64 NUM_EXEC=2)"
elif [[ "$MODE" == "n100" ]]; then
  SYNTH_DEFINES='set_property verilog_define {OOC_MAX_TOKENS=100 OOC_CHAIN_Q=1824 OOC_NUM_EXEC=1} [current_fileset]'
  SYNTH_TIMEOUT="180m"
  SYNTH_JOBS=2
  SYNTH_FLAT="-flatten_hierarchy rebuilt -directive RuntimeOptimized"
  NOTE="Mamba wrapper N100 (N=100 CHAIN_Q=1824 NUM_EXEC=1)"
else
  SYNTH_DEFINES='set_property verilog_define {OOC_MAX_TOKENS=1000 OOC_CHAIN_Q=9024 OOC_NUM_EXEC=2} [current_fileset]'
  SYNTH_TIMEOUT="240m"
  SYNTH_JOBS=4
  SYNTH_FLAT="-flatten_hierarchy none -directive RuntimeOptimized"
  NOTE="Mamba wrapper PROD (N=1000 CHAIN_Q=9024 NUM_EXEC=2)"
fi

SYNTH_JOBS="${SYNTH_JOBS:-4}"
SYNTH_FLAT="${SYNTH_FLAT:--flatten_hierarchy none -directive RuntimeOptimized}"

declare -a RTL_FILES=(
  "$RTL/_parameter.v"
  "$RTL/RMSNorm_Unit_IntSqrt.v"
  "$RTL/In_Projection_Unit_Streaming_v2.v"
  "$RTL/Unified_PE.v"
  "$RTL/SiLU_Unit_PWL.v"
  "$RTL/SiLU_Unit.v"
  "$RTL/Conv1D_MAC.v"
  "$RTL/Conv1D_Layer.v"
  "$RTL/RMSNorm_InProj_Conv_Chain_Wrapper.v"
  "$RTL/RMSNorm_InProj_Conv_Scan_Chain_Wrapper.v"
  "$RTL/Softplus_Unit_PWL.v"
  "$RTL/Exp_Unit.v"
  "$RTL/Exp_Unit_PWL.v"
  "$RTL/Scan_Core_Engine.v"
  "$RTL/Scan_Channel_Exec.v"
  "$RTL/Scan_YPre_Slot.v"
  "$RTL/Scan_XZ_Engine.v"
  "$RTL/Scan_Sync_Rom16.v"
  "$RTL/Scan_Wide_Rom256.v"
  "$RTL/Scan_HMem_SubBank.v"
  "$RTL/Scan_HMem_Banked.v"
  "$RTL/Scan_HState_Live.v"
  "$RTL/Scan_Core_Streaming_Pipe.v"
  "$RTL/Scan_Chain_Wrapper.v"
  "$RTL/Out_Projection_Streaming_v2.v"
  "$RTL/Mamba_Streaming_Block_Wrapper.v"
  "$OOC/Mamba_Streaming_Block_Wrapper_ooc_top.v"
)

echo "========================================"
echo " SYNTH: $NOTE"
echo " Top: $TOP"
echo " Clock: ${CLK_NS} ns (100 MHz)"
echo " Part: $PART"
echo " Timeout: $SYNTH_TIMEOUT"
echo " Log: $VIVADO_LOG"
echo "========================================"

if [[ "$MODE" == "n1" || "$MODE" == "n1_opt" ]]; then
  SIM_DIR="$REPO/RTL/code_AI_gen/test_Mamba_Streaming_Chain"
  echo "[Pre] Sim N=1 NUM_EXEC=1 before synth..."
  if ! "$SIM_DIR/run_streaming_chain.sh" 1; then
    echo "FAIL: sim N=1 did not pass — aborting synth"
    exit 1
  fi
  echo "[Pre] Sim PASS — starting synth"
fi

{
  echo "create_project -force ${TAG} ${PROJ} -part ${PART}"
  for f in "${RTL_FILES[@]}"; do echo "read_verilog ${f}"; done
  echo "read_xdc ${ROOT}/synth_ooc_common.xdc"
  echo "set_param general.maxThreads ${SYNTH_JOBS}"
  echo "set_property include_dirs [list ${RTL}] [current_fileset]"
  echo "$SYNTH_DEFINES"
  echo "set_property top ${TOP} [current_fileset]"
  echo "synth_design -top ${TOP} ${SYNTH_FLAT} -mode out_of_context"
  echo "write_checkpoint -force ${DCP}"
  echo "report_utilization -hierarchical -file ${ROOT}/synth_util_${TAG}.txt"
  echo "report_utilization -file ${ROOT}/synth_util_${TAG}_flat.txt"
  echo "report_timing_summary -file ${ROOT}/synth_timing_${TAG}.txt -delay_type min_max -report_unconstrained"
  echo "report_timing -max_paths 20 -file ${ROOT}/synth_timing_${TAG}_paths.txt"
  echo "close_project"
} > "$TCL"

VIVADO_CMD="cd $(printf '%q' "$WORK") && $(printf '%q' "$VIVADO") -mode batch -log $(printf '%q' "$VIVADO_LOG") -journal $(printf '%q' "${VIVADO_LOG%.log}.jou") -source $(printf '%q' "$TCL")"

timeout "$SYNTH_TIMEOUT" bash -c "$VIVADO_CMD" 2>&1 | tee "$RUN_LOG" | tail -30

python3 - "$ROOT" "$TAG" "$NOTE" "$CLK_NS" <<'PY'
import re, sys
from pathlib import Path
root, tag, note, clk_ns = sys.argv[1:5]
ut = (Path(root) / f"synth_util_{tag}_flat.txt")
tm = (Path(root) / f"synth_timing_{tag}.txt")
if not ut.exists() or not tm.exists():
    print("SYNTH incomplete — missing utilization/timing reports")
    sys.exit(1)
ut = ut.read_text(errors="ignore")
tm = tm.read_text(errors="ignore")

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
wns = m.group(1) if m else "n/a"
try:
    wns_f = float(wns)
    status = "PASS" if wns_f >= 0 else "FAIL"
    fmax = 1000.0 / (float(clk_ns) - wns_f) if wns_f >= 0 else 0
except ValueError:
    status = "?"
    fmax = 0

print()
print("-------- MAMBA WRAPPER SYNTH --------")
print(f"  {note}")
print(f"  Timing : WNS={wns} ns => {status}  Est.Fmax={fmax:.1f} MHz")
print(f"  LUT={lut}  FF={ff}  DSP={dsp}  BRAM={bram}")
print(f"  DCP : {Path(root) / ('synth_' + tag + '.dcp')}")
print(f"  GUI : vivado -mode gui -source {Path(root) / 'open_synth_mamba_gui.tcl'} -tclargs {tag.replace('mamba_wrapper_', '')}")
print(f"  Note: GUI uses open_checkpoint + report_* (not open_report on .txt)")
print("-----------------------------------")
summary = Path(root) / "synth_mamba_wrapper_summary.txt"
summary.write_text(
    f"{note}\nWNS={wns} LUT={lut} FF={ff} DSP={dsp} BRAM={bram}\n",
    encoding="utf-8",
)
print(f"Wrote {summary}")
PY
