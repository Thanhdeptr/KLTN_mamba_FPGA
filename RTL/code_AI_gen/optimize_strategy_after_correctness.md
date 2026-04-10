# Optimize Strategy After Correctness

This strategy is proposed only after all staged tests pass.

## Objective

Balance throughput/latency/Fmax while reducing LUT/FF/DSP usage, with no functional regression.

## Priority 1: Timing-meaningful baseline

1. Add a constrained run (`create_clock`) for target frequency.
2. Capture WNS/TNS and top failing paths for:
   - `Scan_Core_Engine`
   - `Conv1D_Layer`
3. Keep resource and timing snapshots for before/after comparison.

## Priority 2: Low-risk optimizations first

1. `Scan_Core_Engine`: pipeline the 16-lane reduction (`sum_all`) into a tree of registered stages.
2. `Scan_Core_Engine`: register boundary between major FSM compute steps to reduce long combinational chains.
3. `SiLU_Unit_PWL`: remove redundant sequential ROM capture logic if not used for timing closure.

Expected impact:
- Better Fmax with minimal algorithmic changes.
- Small FF increase due to pipeline registers.

## Priority 3: Resource-oriented optimizations

1. `Conv1D_Layer`:
   - Evaluate scheduling to reduce simultaneous DSP pressure if throughput target allows.
   - Review if all 16 lanes must be fully parallel in current mode.
2. `Scan_Core_Engine`:
   - Review arithmetic width and temporary signals for safe but tighter bit-width.
3. Ensure no accidental I/O-heavy top-level synthesis when comparing module utilization.

## Priority 4: Regression gates for each optimization

For each incremental optimization:
1. Re-run unit tests:
   - `test_SiLU_Unit_PWL`
   - `test_Exp_Unit_PWL`
   - `test_Softplus_Unit_PWL`
   - `test_Unified_PE`
2. Re-run staged integration smoke tests:
   - `test_Linear_Layer`
   - `test_Conv1D_Layer`
   - `test_Scan_Core_Engine`
3. Compare resource and timing delta versus baseline reports.

## Acceptance criteria

1. No functional mismatch in all existing compare scripts.
2. Timing improves under real constraints (WNS/TNS trend positive).
3. Resource either decreases or follows an intentional trade-off documented in the report.
