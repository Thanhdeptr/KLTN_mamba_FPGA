# Baseline Note for Future Comparison

This file records the current rough baseline (timing + hardware resource) before optimization.

## Baseline Table

| Block | Target MHz | Period (ns) | WNS (ns) | TNS (ns) | Fmax est (MHz) | LUT | FF | DSP | BRAM18K |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `Unified_PE` | 250.000 | 4.000 | 0.564 | 0.000 | 291.036 | 86 | 16 | 1 | 0 |
| `Linear_Layer` | 149.993 | 6.667 | 3.221 | 0.000 | 290.192 | 312 | 22 | 0 | 0 |
| `Conv1D_Layer` | 149.993 | 6.667 | 3.166 | 0.000 | 285.633 | 2963 | 1297 | 16 | 0 |
| `Scan_Core_Engine` | 149.993 | 6.667 | -0.093 | -0.833 | 147.929 | 2729 | 1078 | 20 | 0 |
| `Mamba_Top` | 125.000 | 8.000 | -6.351 | -1678.542 | 69.682 | 8076 | 2688 | 53 | 0 |

## Comparison Formulas (post-optimize vs baseline)

- `Fmax_gain_% = (Fmax_post - Fmax_pre) / Fmax_pre * 100`
- `LUT_change_% = (LUT_post - LUT_pre) / LUT_pre * 100`
- `FF_change_% = (FF_post - FF_pre) / FF_pre * 100`
- `DSP_change_% = (DSP_post - DSP_pre) / DSP_pre * 100`
- `TNS_improve = TNS_post - TNS_pre` (closer to zero is better for negative TNS)

## Source

- Raw snapshot CSV: `baseline_snapshot.csv`

## Wave 1 Result (Scan_Core_Engine timing-first)

| Metric | Baseline | Wave1 | Delta |
|---|---:|---:|---:|
| WNS (ns) | -0.093 | 0.581 | +0.674 |
| TNS (ns) | -0.833 | 0.000 | +0.833 |
| Fmax est (MHz) | 147.929 | 164.312 | +11.074% |
| LUT | 2729 | 2853 | +4.544% |
| FF | 1078 | 1251 | +16.049% |
| DSP | 20 | 20 | 0.000% |
| BRAM18K | 0 | 0 | 0.000% |

## Quick Try Result (Mamba_Top PE-MUX register slice)

| Metric | Baseline | After optimize | Delta |
|---|---:|---:|---:|
| WNS (ns) | -6.351 | -4.822 | +1.529 |
| TNS (ns) | -1678.542 | -1069.576 | +608.966 |
| Fmax est (MHz) | 69.682 | 77.991 | +11.923% |
| LUT | 8076 | 8144 | +0.842% |
| FF | 2688 | 3396 | +26.339% |
| DSP | 53 | 53 | 0.000% |
| BRAM18K | 0 | 0 | 0.000% |

## Quick Try Result 3 (Scan Exp-input register slice)

| Metric | Baseline | After optimize | Delta |
|---|---:|---:|---:|
| WNS (ns) | -6.351 | -1.120 | +5.231 |
| TNS (ns) | -1678.542 | -86.480 | +1592.062 |
| Fmax est (MHz) | 69.682 | 109.649 | +57.361% |
| Note |  | Critical path still in `Exp_Unit_PWL` compute stage |  |

## Quick Try Result 4 (Perf implementation strategy on top)

| Metric | Quick Try 3 | Perf run | Delta |
|---|---:|---:|---:|
| WNS (ns) | -1.120 | 0.419 | +1.539 |
| TNS (ns) | -86.480 | 0.000 | +86.480 |
| Fmax est (MHz) | 109.649 | 131.909 | +20.301% |
| Hold WNS (ns) | 0.041 | 0.054 | +0.013 |
| Note |  | `opt/place/route/phys_opt` aggressive directives |  |

## Stability Check (Perf flow, 3 seeds)

| Seed | WNS (ns) | TNS (ns) | WHS (ns) | Fmax est (MHz) | Result |
|---:|---:|---:|---:|---:|---|
| 1 | 0.419 | 0.000 | 0.054 | 131.909 | PASS |
| 2 | 0.419 | 0.000 | 0.054 | 131.909 | PASS |
| 3 | 0.419 | 0.000 | 0.054 | 131.909 | PASS |

- Pass ratio: `3/3` (stable in this quick OOC setup).
- Raw CSV: `mamba_top_perf_multiseed.csv`.

## Quick Try Result 5 (Extra pipeline: `Exp_Unit` input register)

| Metric | Previous Perf | After extra pipeline | Delta |
|---|---:|---:|---:|
| WNS (ns) | 0.419 | 0.635 | +0.216 |
| TNS (ns) | 0.000 | 0.000 | +0.000 |
| Hold WNS (ns) | 0.054 | 0.057 | +0.003 |
| Fmax est (MHz) | 131.909 | 135.777 | +2.933% |
| LUT | 7630 | 7639 | +0.118% |
| FF | 3634 | 3504 | -3.577% |
| DSP | 53 | 53 | 0.000% |
| BRAM18K | 0 | 0 | 0.000% |

## Safe Try (DSP mapping hints: PE/Scan/Exp)

- Applied `(* use_dsp = "yes" *)` on key multiplies in:
  - `Unified_PE` (`mult_raw`)
  - `Scan_Core_Engine` (`Dx_prod`, `gated_raw_mul`)
  - `Exp_Unit_PWL` (`prod`)
- Regression: `PASS` for `Unified_PE`, `Scan_Core_Engine`, `Exp_Unit_PWL`.
- Perf timing (Mamba_Top @ 8.0ns): unchanged within this quick flow: `WNS=0.635`, `TNS=0.000`.

## Safe Try (max_fanout attributes on PE buses)

- Added `(* max_fanout = 16 *)` on `Mamba_Top` internal buses:
  - `pe_result_common`
  - `pe_op_r`, `pe_clr_r`, `pe_in_a_r`, `pe_in_b_r`
- Regression: `PASS` (`Linear_Layer`, `Conv1D_Layer`, `Scan_Core_Engine`).
- Perf timing (Mamba_Top @ 8.0ns): `WNS=0.405`, `TNS=0.000` (worse in this run).
- Utilization (Mamba_Top perf): LUT `8684`, FF `4290`, DSP `53`.

## Quick Try Result 2 (Conv1D control-path fanout reduction)

| Metric | Baseline | After optimize | Delta |
|---|---:|---:|---:|
| WNS (ns) | -6.351 | -1.728 | +4.623 |
| TNS (ns) | -1678.542 | -247.572 | +1430.970 |
| Fmax est (MHz) | 69.682 | 102.796 | +47.524% |
| LUT | 8076 | 8144 | +0.842% |
| FF | 2688 | 3396 | +26.339% |
| DSP | 53 | 53 | 0.000% |
| BRAM18K | 0 | 0 | 0.000% |

## Level-B ITM Block (RTL)

- New: `RTL/code_initial/ITM_Block.v` — Inception path (`Conv1D_Layer` k=4 + SiLU) then Mamba path (`Scan_Core_Engine`), merge `sat16(relu(incept[i]) + relu(scan_y))` with scalar `scan_y` broadcast to 16 lanes.
- `Mamba_Top`: `mode_select == 5` muxes PE to `ITM_Block`; ports `itm_*` (feat, conv w/b, scan A/B/C/delta/x/D/gate, clear_h, start/en/done/valid_out/out_vec).
- Synth scripts include `ITM_Block.v`: `run_ooc_quick.tcl`, `run_ooc_perf_top.tcl`, `run_ooc_perf_top_seed.tcl`.
- RTL cosim: `RTL/code_AI_gen/test_ITM_Block` (`run.sh`: xsim `ITM_Block` + 16×`Unified_PE`, cases `zero` / `bias_lane0`; golden = Python Conv1D+SiLU PWL + merge).
- Top-level ITM path: `RTL/code_AI_gen/test_Mamba_Top_ITM` (`run.sh`: `Mamba_Top` with `mode_select=5`, internal PE mux + register slice; same golden generator as `test_ITM_Block`). In ITM hold `itm_en` high until `itm_done`.
- Full paper fidelity still needs: Inception 9/19/39 + pool branch, vector Mamba out (not scalar broadcast), BN/RMSNorm, optional Conv1x1 front.
