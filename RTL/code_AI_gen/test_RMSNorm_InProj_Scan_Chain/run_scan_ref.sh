#!/usr/bin/env bash
# Conv chain x/z -> channel-major mem -> standalone SCAN_PIPE golden (y + h).
set -euo pipefail

N="${1:-1}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
CONV_DIR="$(cd "$ROOT/../test_RMSNorm_InProj_Chain" && pwd)"
SCAN_DIR="$(cd "$ROOT/../../testbench/test_Scancore" && pwd)"
REF_DIR="$ROOT/scan_ref_work"

echo "[Ref] conv chain + scan pipe reference N=$N"
mkdir -p "$REF_DIR"

cd "$CONV_DIR"
./run_conv_chain.sh "$N" 2>&1 | tail -3

python3 "$ROOT/build_scan_ref_mem.py" \
  --conv-dir "$CONV_DIR" --out-dir "$REF_DIR" --tokens "$N"

cd "$SCAN_DIR"
ln -sf "$REF_DIR/x_activated_ref.mem" x_activated.mem
ln -sf "$REF_DIR/silu_z_ref.mem" silu_z_golden.mem

SCAN_PIPE=1 NUM_TOKENS="$N" timeout 180 ./run.sh "$N" 2>&1 | tail -5

cp rtl_y_gated_stream.mem "$ROOT/rtl_y_scan_ref.mem"
cp rtl_h_state_stream.mem "$ROOT/rtl_h_scan_ref.mem"
echo "[Ref] wrote $ROOT/rtl_y_scan_ref.mem and rtl_h_scan_ref.mem"
