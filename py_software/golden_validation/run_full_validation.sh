#!/usr/bin/env bash
# Full golden validation pipeline (Phases 0-3).
# Phase 4 (RTL xsim) is optional — requires Vivado.

set -euo pipefail

KLTN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ITMN_ROOT="${KLTN_ROOT}/ITMN"
PY="${KLTN_ROOT}/py_software"
VAL="${PY}/golden_validation"
VENV="${KLTN_ROOT}/mamba-venv/bin/activate"

EXP_TYPE="${EXP_TYPE:-super}"
INPUT_SOURCE="${INPUT_SOURCE:-dataset}"

log() { echo "[golden_validation] $*"; }

if [[ -f "${VENV}" ]]; then
  # shellcheck disable=SC1090
  source "${VENV}"
  log "Using venv: ${VENV}"
else
  log "WARNING: ${VENV} not found; using system python"
fi

if [[ ! -d "${ITMN_ROOT}" ]]; then
  echo "ERROR: missing ITMN at ${ITMN_ROOT}" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Phase 0 — regenerate artifacts with locked input
# ---------------------------------------------------------------------------
log "Phase 0.1: extract_single_sample (profile tensors)"
(
  cd "${ITMN_ROOT}"
  PYTHONPATH="${ITMN_ROOT}" python "${PY}/extract_single_sample.py" --exp_type "${EXP_TYPE}"
)

log "Phase 0.2: extract_weight_shape (weights + module I/O, input=cpp)"
(
  cd "${ITMN_ROOT}"
  PYTHONPATH="${ITMN_ROOT}" python "${PY}/extract_weight_shape.py" --exp_type "${EXP_TYPE}" --input_source cpp
)

# ---------------------------------------------------------------------------
# Phase 1-3 — compare + plots
# ---------------------------------------------------------------------------
log "Phase 1-3: compare_and_plot (ITMN vs extract vs mamba_ssm)"
python "${VAL}/compare_and_plot.py" \
  --exp_type "${EXP_TYPE}" \
  --input_source cpp \
  --device auto

# ---------------------------------------------------------------------------
# Phase 3b — regenerate RTL .mem from cpp golden
# ---------------------------------------------------------------------------
if [[ "${SKIP_RTL_MEM:-0}" != "1" ]]; then
  log "Phase 3b: extract_real_rtl_golden (.mem files)"
  python "${PY}/extract_real_rtl_golden.py" || log "extract_real_rtl_golden failed (non-fatal)"
fi

# ---------------------------------------------------------------------------
# Phase 4 — optional RTL unit compare (needs xsim)
# ---------------------------------------------------------------------------
if [[ "${RUN_RTL:-0}" == "1" ]]; then
  TB="${KLTN_ROOT}/RTL/code_AI_gen/test_Softplus_Unit_PWL"
  if command -v xsim >/dev/null 2>&1 && [[ -d "${TB}" ]]; then
    log "Phase 4: Softplus RTL compare (example unit test)"
    (
      cd "${TB}"
      if [[ -x ./run.sh ]]; then
        ./run.sh || log "RTL run.sh failed"
      fi
      if [[ -f compare_rtl_vs_golden.py ]]; then
        python3 compare_rtl_vs_golden.py || true
      fi
    )
  else
    log "SKIP Phase 4: xsim or testbench not available"
  fi
fi

LATEST="$(ls -td "${KLTN_ROOT}/reports/golden_validation"/*/ 2>/dev/null | head -1 || true)"
if [[ -n "${LATEST}" ]]; then
  log "Done. Latest report: ${LATEST}"
  log "  summary: ${LATEST}/summary.md"
  log "  figures: ${LATEST}/figures/"
else
  log "Done (no report directory found)"
fi
