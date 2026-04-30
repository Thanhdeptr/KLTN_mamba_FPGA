#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
RTL_DIR="$(cd "$ROOT/../../code_initial" && pwd)"

cd "$ROOT"

# Prepare resources (mirror run.sh behavior)
TAIL_GOLDEN_SOURCE="${TAIL_GOLDEN_SOURCE:-rebuild}"
python3 "$ROOT/../test_Mamba_FullBranch_Chain/prepare_mem.py" --tail-golden-source "$TAIL_GOLDEN_SOURCE" || true
cp "$RTL_DIR/silu_pwl_coeffs.mem" . || true
cp "$RTL_DIR/exp_pwl_coeffs.mem" . || true

rm -rf xsim.dir .Xil *.log *.jou *.pb rtl_output.mem || true

XVLOG_LOG=/tmp/xvlog_mamba_top.out
XELAB_LOG=/tmp/xelab_mamba_top.out
XSIM_LOG=/tmp/xsim_mamba_top.out

echo "[run_mamba_top] xvlog -> $XVLOG_LOG"
xvlog \
  "$RTL_DIR/_parameter.v" \
  "$RTL_DIR/SiLU_Unit.v" \
  "$RTL_DIR/Exp_Unit_PWL.v" \
  "$RTL_DIR/Exp_Unit.v" \
  "$RTL_DIR/SiLU_Unit_PWL.v" \
  "$RTL_DIR/RMSNorm_Unit_IntSqrt.v" \
  "$RTL_DIR/Linear_Layer.v" \
  "$RTL_DIR/Conv1D_Layer.v" \
  "$RTL_DIR/Scan_Core_Engine.v" \
  "$RTL_DIR/Unified_PE.v" \
  "$RTL_DIR/Softplus_Unit_PWL.v" \
  "$RTL_DIR/ITM_Block.v" \
  "$RTL_DIR/Mamba_Top.v" \
  tb_mamba_top_itm.v > "$XVLOG_LOG" 2>&1 || true

echo "[run_mamba_top] xelab -> $XELAB_LOG"
xelab -mt off -v 1 --relax tb_mamba_top_itm -s tb_mamba_top_itm_sim > "$XELAB_LOG" 2>&1 || true

# Force headless: unset DISPLAY so xsim won't spawn GUI kernels
unset DISPLAY || true

echo "[run_mamba_top] xsim -> $XSIM_LOG"
xsim tb_mamba_top_itm_sim -runall > "$XSIM_LOG" 2>&1 || true

echo "[run_mamba_top] tail logs"
echo "=== XVLOG (last 200 lines) ==="
tail -n 200 "$XVLOG_LOG" || true
echo "=== XELAB (last 200 lines) ==="
tail -n 200 "$XELAB_LOG" || true
echo "=== XSIM (last 200 lines) ==="
tail -n 200 "$XSIM_LOG" || true

# Compare rtl_output.mem vs golden_output.mem (simple exact hex compare)
python3 - <<'PY'
from pathlib import Path
g=Path('golden_output.mem')
r=Path('rtl_output.mem')
if not g.exists():
    print('ERROR: golden_output.mem not found'); raise SystemExit(2)
if not r.exists():
    print('ERROR: rtl_output.mem not generated'); raise SystemExit(2)
gold=[l.strip().lower() for l in g.read_text().split() if l.strip()]
rtl=[l.strip().lower() for l in r.read_text().split() if l.strip()]
if len(gold)!=len(rtl):
    print(f'FAIL: length mismatch gold={len(gold)} rtl={len(rtl)}')
    raise SystemExit(3)
bad=sum(1 for a,b in zip(gold,rtl) if a!=b)
print(f'COMPARE: bad={bad}/{len(gold)}')
print('PASS' if bad==0 else 'FAIL')
raise SystemExit(0 if bad==0 else 4)
PY
