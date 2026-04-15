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
- `RTL/SOC` (`./run.sh`): PASS — `mamba_soc_axi_lite_wrapper` (AXI4-Lite CSR + `Mamba_Top`), TB drives ITM mode 5 via AXI, same golden as `test_ITM_Block` zero case

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
- `synth_reports/baseline/run_synth_baseline.tcl` is **synthesis-only** with **no XDC**: timing summary there is not comparable to sign-off.
- For **meaningful post-route WNS/TNS/Fmax** (same part `xczu5ev-sfvc784-1LV-i`), use `synth_reports/constrained_ooc/`:

### A) Internal-cut I/O (quick baseline)

- Script: `run_ooc_quick.tcl`
- Flow: OOC `synth_design` → `create_clock` on `clk` + `set_clock_uncertainty` → **false_path** on all data inputs/outputs (async `reset` false_path to registers kept) → `opt_design` / `place_design -directive Quick` / `route_design -directive Quick`.
- Meaning: stresses **register-to-register** paths inside the block; port-to-register and register-to-port paths are not closed (typical for a reusable RTL block before chip-top budgets exist).
- Batch driver: `run_quick_baseline.sh` → `results/quick_baseline/quick_summary.csv` (columns include `wns_ns`, `tns_ns`, `fmax_est_mhz`).

### B) Clock-relative I/O budgets (system-style)

- Script: `run_ooc_timed_io.tcl`
- Same flow as (A) but **no** false_path on data ports; instead `set_input_delay` / `set_output_delay` vs `core_clk` with `max = io_fraction × period` (default `io_fraction=0.30`, overridable 4th argument).
- Produces `timed_io_summary.csv`, full `*_timing_summary.rpt`, and `*_check_timing.rpt` (expect fewer `no_input_delay` / `no_output_delay` warnings than (A)).
- Compare (A) vs (B) for the same `module` and `period_ns` to see how much margin is consumed by I/O closure.

### Compare `Mamba_Top` under both styles

- From `synth_reports/constrained_ooc`: `./run_timing_compare_mamba.sh [period_ns] [io_fraction]`
- Writes timestamped folders under `results/timing_compare_<stamp>/` with separate CSV + reports per style.

### Before changing RTL for performance

- Stabilize **which constraint style** matches your integration (block-only vs top-level with known board delays), then use WNS/TNS and `fmax_est_mhz` from the matching flow before applying pipeline/retiming optimizations.
