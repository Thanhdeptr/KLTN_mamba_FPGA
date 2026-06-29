#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RTL_DIR="${SCRIPT_DIR}/../../code_initial"
TB_NAME="tb_out_proj_stream_v2"
TOP="tb_out_projection_streaming_v2"

NUM_MAC="${1:-16}"

cd "${SCRIPT_DIR}"

echo "=== Out_Projection_Streaming_v2 sim NUM_MAC=${NUM_MAC} ==="

xvlog -sv -define NUM_MAC="${NUM_MAC}" \
    "${RTL_DIR}/_parameter.v" \
    "${RTL_DIR}/Out_Projection_Streaming_v2.v" \
    "${SCRIPT_DIR}/tb_out_projection_streaming_v2.v"

xelab -debug typical "${TOP}" -s "${TB_NAME}"

xsim "${TB_NAME}" --runall

echo "=== Done ==="
