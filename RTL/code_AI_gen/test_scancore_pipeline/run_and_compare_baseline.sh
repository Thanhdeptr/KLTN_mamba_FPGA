#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

echo "[run_and_compare_baseline] running baseline and normalizing rtl output"

# run baseline (capture log)
bash run_scancore_baseline.sh > /tmp/run_scancore_baseline_run.out 2>&1 || true

# candidate output files produced by various TBs
CANDIDATES=("rtl_output_baseline.mem" "rtl_output.mem" "/home/$(whoami)/schoolwork/KLTN/RTL/code_AI_gen/test_Scan_Core_Engine/rtl_output.mem")

rm -f rtl_output.mem || true
for f in "${CANDIDATES[@]}"; do
  if [ -f "$f" ]; then
    cp -v "$f" rtl_output.mem
    echo "[run_and_compare_baseline] using $f -> rtl_output.mem"
    break
  fi
done

if [ ! -f rtl_output.mem ]; then
  echo "[run_and_compare_baseline] ERROR: no rtl output found" >&2
  echo "Check /tmp/run_scancore_baseline_run.out for simulator logs." >&2
  exit 2
fi

echo "[run_and_compare_baseline] running compare script"
python3 /home/$(whoami)/schoolwork/KLTN/RTL/code_AI_gen/test_Scan_Core_Engine/gen_vectors_and_compare.py

echo "[run_and_compare_baseline] done"
