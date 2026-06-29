#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KLTN_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
RTL_DIR="${SCRIPT_DIR}/../../code_initial"
TOP="tb_outprojection_mem_unit"
SNAP="tb_outprojection_mem_unit_sim"
MODE="${1:-single}"
FLOAT_TOL="${2:-4}"

cd "${SCRIPT_DIR}"

if [ "${REGEN_MEM:-1}" = "1" ]; then
  echo "[Regen] outprojection .mem from ITMN cpp_golden_files"
  PYTHONPATH="${KLTN_ROOT}/ITMN" python3 "${KLTN_ROOT}/py_software/extract_RTL_inital_mem.py" --mode outprojection
fi

echo "=== OutProjection unit test from mem files ==="
echo "PASS criteria: RTL matches fixed-point golden (regen via extract_RTL_inital_mem.py --mode outprojection)."

xvlog -sv \
    "${RTL_DIR}/_parameter.v" \
    "${RTL_DIR}/Out_Projection_Unit.v" \
    "${SCRIPT_DIR}/tb_outprojection_mem_unit.v"

xelab -debug typical "${TOP}" -s "${SNAP}"
if [[ "${MODE}" == "full" ]]; then
    xsim "${SNAP}" --runall -testplusarg RUN_FULL -testplusarg "FLOAT_TOL=${FLOAT_TOL}"
else
    xsim "${SNAP}" --runall -testplusarg "FLOAT_TOL=${FLOAT_TOL}"
fi

echo "=== Done ==="
