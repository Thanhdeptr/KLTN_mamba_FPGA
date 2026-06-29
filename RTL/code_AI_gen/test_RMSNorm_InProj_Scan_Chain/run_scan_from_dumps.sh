#!/usr/bin/env bash
# Build scan reference from conv x/z dumps already in this directory.
set -euo pipefail

N="${1:-1}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
SCAN_DIR="$(cd "$ROOT/../../testbench/test_Scancore" && pwd)"
REF_DIR="$ROOT/scan_ref_work"

mkdir -p "$REF_DIR"
python3 "$ROOT/build_scan_ref_mem.py" \
  --conv-dir "$ROOT" --out-dir "$REF_DIR" --tokens "$N"

cd "$SCAN_DIR"
ln -sf "$REF_DIR/x_activated_ref.mem" x_activated.mem
ln -sf "$REF_DIR/silu_z_ref.mem" silu_z_golden.mem

REF_TIMEOUT=$(( N * 30 ))
if [ "$REF_TIMEOUT" -lt 180 ]; then
  REF_TIMEOUT=180
fi

SCAN_PIPE=1 SCAN_H_LIVE=1 NUM_TOKENS="$N" timeout "$REF_TIMEOUT" ./run.sh "$N" 2>&1 | tail -5

cp rtl_y_gated_stream.mem "$ROOT/rtl_y_scan_ref.mem"
cp rtl_h_state_stream.mem "$ROOT/rtl_h_scan_ref.mem"
echo "[Ref] scan ref from local dumps N=$N"
