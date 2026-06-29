# Golden validation pipeline

Cross-check golden extraction against ITMN PyTorch forward and `mamba_ssm` selective scan.

## Quick start

```bash
# From KLTN root (uses mamba-venv if present)
./py_software/golden_validation/run_full_validation.sh
```

Or step by step:

```bash
source mamba-venv/bin/activate
cd ITMN && python ../py_software/extract_single_sample.py --exp_type super
cd ITMN && python ../py_software/extract_weight_shape.py --exp_type super --input_source cpp
python py_software/golden_validation/compare_and_plot.py --exp_type super --input_source cpp
```

## Outputs

```
reports/golden_validation/<timestamp>/
  validation_manifest.txt   # checkpoint hash, package versions
  summary.md                # pass/fail table
  results.csv
  figures/                  # overlay, scatter, heatmap
```

## Interpretation

| Comparison | Expected |
|------------|----------|
| Live extract vs `cpp_golden_files` txt | PASS (file consistency) |
| `mixer.forward` vs `mamba_ssm` | PASS |
| Manual scan loop in `extract_single_sample` vs `mamba_ssm` (L9, L10) | PASS (`y_pre = C*h + D*x`, then gate) |

**Golden scan:** `y_pre = C*h + D*x`, then `y_gated = y_pre * silu(z)` — aligned with Mamba / RTL.

## Environment variables

| Variable | Default | Meaning |
|----------|---------|---------|
| `EXP_TYPE` | `super` | ITMN task type |
| `INPUT_SOURCE` | `dataset` in shell / `cpp` in compare | Input waveform source |
| `SKIP_RTL_MEM` | `0` | Set `1` to skip `extract_real_rtl_golden.py` |
| `RUN_RTL` | `0` | Set `1` to run example RTL compare (needs Vivado) |

## Requirements

- `ITMN/` with checkpoint path in `config.yaml`
- CUDA recommended (`mamba_ssm` selective scan)
- `matplotlib`, `numpy`, `torch`, `mamba-ssm`, `einops`
