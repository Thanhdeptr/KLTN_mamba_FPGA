#!/usr/bin/env bash
# Scan reference from wrapper conv dumps -> standalone SCAN_PIPE sim.
set -euo pipefail

N="${1:-1}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
SCAN_DIR="$(cd "$ROOT/../../testbench/test_Scancore" && pwd)"
FULL_CHAIN="$(cd "$ROOT/../test_RMSNorm_InProj_Scan_Chain" && pwd)"
REF_DIR="$ROOT/scan_ref_work"

mkdir -p "$REF_DIR"
python3 "$FULL_CHAIN/build_scan_ref_mem.py" \
  --conv-dir "$ROOT" \
  --out-dir "$REF_DIR" \
  --tokens "$N" \
  --x-file rtl_output_conv_x_streaming.mem \
  --z-file rtl_output_conv_z_streaming.mem

cd "$SCAN_DIR"
ln -sf "$REF_DIR/x_activated_ref.mem" x_activated.mem
ln -sf "$REF_DIR/silu_z_ref.mem" silu_z_golden.mem

REF_TIMEOUT=$(( N * 30 ))
if [ "$REF_TIMEOUT" -lt 180 ]; then
  REF_TIMEOUT=180
fi

SCAN_PIPE=1 SCAN_H_LIVE=1 NUM_TOKENS="$N" timeout "$REF_TIMEOUT" ./run.sh "$N" 2>&1 | tail -8 || true

if [ ! -f rtl_y_gated_stream.mem ]; then
  echo "FAIL: scan ref sim did not produce rtl_y_gated_stream.mem"
  exit 1
fi

cp rtl_y_gated_stream.mem "$ROOT/rtl_y_scan_ref.mem"
echo "[Ref] wrapper scan ref N=$N -> $ROOT/rtl_y_scan_ref.mem"
