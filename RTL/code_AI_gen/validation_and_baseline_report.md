# Validation and Baseline Report

This report follows a validation-first flow from small modules to larger blocks.

## Unit tests (small modules)

- `test_SiLU_Unit_PWL`: PASS (`4096` samples, mismatches `0`)
- `test_Exp_Unit_PWL`: PASS (`1024` samples, mismatches `0`)
- `test_Softplus_Unit_PWL`: PASS (`1024` samples, mismatches `0`)
- `test_Unified_PE`: PASS (`512` vectors, mismatches `0`)

## Staged integration tests (larger blocks, smoke subset)

- `test_Linear_Layer`: PASS (zero-vector smoke, 16-lane output)
- `test_Conv1D_Layer`: PASS (zero-vector smoke, 16-lane output)
- `test_Scan_Core_Engine`: PASS (zero-vector smoke, scalar output)

## Functional fixes for stability

- Added wrapper `RTL/code_initial/Exp_Unit.v` to map legacy `Exp_Unit` instantiation to `Exp_Unit_PWL`.
- Added wrapper `RTL/code_initial/SiLU_Unit.v` to map legacy `SiLU_Unit` instantiation to `SiLU_Unit_PWL`.
- These wrappers preserve behavior and remove compile-level mismatch risks.

## Baseline synthesis (Vivado 2025.1, part `xczu5ev-sfvc784-1LV-i`)

Report directory:
- `RTL/code_AI_gen/synth_reports/baseline`

Resource summary (synthesized netlist):

| Module | LUT | FF | DSP | BRAM |
|---|---:|---:|---:|---:|
| `Unified_PE` | 86 | 16 | 1 | 0 |
| `Linear_Layer` | 312 | 22 | 0 | 0 |
| `Conv1D_Layer` | 2964 | 1297 | 16 | 0 |
| `Scan_Core_Engine` | 2730 | 1078 | 20 | 0 |

Important timing note:
- Current timing reports are **unconstrained** (no clock/create_clock constraints), so Fmax is not meaningful yet.
- The generated files are still useful as a baseline for relative resource tracking.

## Next step for timing-accurate optimization

- Add proper timing constraints (`create_clock`) in a constrained synthesis/implementation flow.
- Re-run baseline to obtain valid WNS/TNS and estimated Fmax before applying pipeline optimizations.
