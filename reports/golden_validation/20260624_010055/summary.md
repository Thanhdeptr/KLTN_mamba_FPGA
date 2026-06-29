# Golden validation summary

- Report directory: `/home/hatthanh/schoolwork/KLTN/reports/golden_validation/20260624_010055`
- Comparisons: 11
- Passed: 10/11

## Results

| ID | Name | max err | mean err | p99 | atol | pass | note |
|----|------|---------|----------|-----|------|------|------|
| L1 | live_vs_cpp_rmsnorm | 0.000e+00 | 0.000e+00 | 0.000e+00 | 1.0e-06 | PASS | extract live vs saved cpp_golden_files |
| L2 | live_vs_cpp_inproj_xz | 0.000e+00 | 0.000e+00 | 0.000e+00 | 1.0e-06 | PASS | extract live vs saved cpp_golden_files |
| L5 | live_vs_cpp_x_activated | 0.000e+00 | 0.000e+00 | 0.000e+00 | 1.0e-06 | PASS | extract live vs saved cpp_golden_files |
| L7 | live_vs_cpp_delta_final | 0.000e+00 | 0.000e+00 | 0.000e+00 | 1.0e-06 | PASS | extract live vs saved cpp_golden_files |
| L1b | rmsnorm_vs_mixer_path | 0.000e+00 | 0.000e+00 | 0.000e+00 | 1.0e-05 | PASS | same norm() call |
| L11a | manual_outproj_vs_mixer_forward | 1.431e-06 | 3.673e-08 | 2.384e-07 | 1.0e-05 | PASS | manual path with D*x skip |
| L11b | mixer_forward_vs_mamba_ssm | 0.000e+00 | 0.000e+00 | 0.000e+00 | 1.0e-05 | PASS | oracle: selective_scan_fn + out_proj |
| L9 | manual_y_pre_vs_mamba_ssm | 1.431e-06 | 1.312e-08 | 1.192e-07 | 1.0e-04 | PASS | y_pre = C*h + D*x |
| L9b | manual_ch_only_vs_mamba_ssm | 3.057e+00 | 1.382e-01 | 6.745e-01 | 1.0e-04 | FAIL | C*h only (legacy, expected FAIL) |
| L10 | manual_y_gated_vs_mamba_ssm | 2.861e-06 | 8.477e-09 | 1.192e-07 | 1.0e-04 | PASS | y_pre * silu(z); matches mamba_ssm gated output |
| Q1 | delta_q16_roundtrip | 1.221e-04 | 6.123e-05 | 1.209e-04 | 2.5e-04 | PASS | quantization grid only |

## Interpretation

- Phase 1 (`extract` vs `ITMN` module path): expect PASS for L1-L8.
- Phase 2 (`mixer.forward` vs `mamba_ssm`): expect PASS.
- Manual scan in `extract_single_sample` may FAIL vs `mamba_ssm` (missing D term / z fused in kernel).
- Use `mamba_ssm` / `mixer.forward` as golden source for scan tail, not manual loop.

