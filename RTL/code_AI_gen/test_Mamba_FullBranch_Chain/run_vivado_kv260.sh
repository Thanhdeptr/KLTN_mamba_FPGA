#!/bin/bash
# Wrapper to run Vivado TCL scripts for KV260 project
# Example:
# ./run_vivado_kv260.sh myproj mamba_ip_proj mamba_ip_top

PROJ_NAME=${1:-mamba_ip_proj}
PROJ_DIR=${2:-./vivado_${PROJ_NAME}}
TOP=${3:-mamba_ip_top}
PART=${4:-xczu3eg-sbva484-1-e}
RTL_DIR=${5:-./../../code_initial}
TB_DIR=${6:-.}
MEM_DIR=${7:-./mem}
XDC=${8:-""}

# Create project, synth, impl
vivado -mode batch -source run_vivado_kv260.tcl $PROJ_NAME $PROJ_DIR $TOP $PART $RTL_DIR $TB_DIR $MEM_DIR $XDC

# Optionally run simulation (behavioral)
# vivado -mode batch -source run_vivado_kv260_sim.tcl tb_mamba_fullbranch_chain_cu ${RTL_DIR} ${TB_DIR} ${MEM_DIR}

echo "Done. Check $PROJ_DIR for reports: utilization_rpt.txt, timing_summary_rpt.txt"
