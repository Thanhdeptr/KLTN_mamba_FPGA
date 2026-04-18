# Scan_Core_Engine Debug Report: Latency & Sign Issue Analysis

## Summary
Applied Exp_Unit 2-cycle latency fix (added S_STEP3W wait state). Improvement measurable but incomplete. Discovered systematic sign error in y_scan output.

## Changes Applied
1. **Added S_STEP3W state** (value=11) to wait for Exp_Unit pipeline
   - Exp_Unit has 2-cycle latency: in_data_r register + Exp_Unit_PWL calc
   - Original FSM had race condition: discA_stored read at posedge same cycle as exp_out write
   - Fix: Insert 1-cycle wait to align with actual latency

2. Files modified:
   - `/RTL/code_initial/Scan_Core_Engine.v`: 
     - Line 99: Added `localparam S_STEP3W = 11`
     - Line 159: changed S_STEP3 state transition to S_STEP3W
     - Line 161-166: Added S_STEP3W sequential case
     - Line 255: Modified combinational to handle S_STEP3, S_STEP3W together

## Results: Pre-Fix vs Post-Fix (8-token baseline)

| Metric | Pre-Fix | Post-Fix | Δ | Status |
|--------|---------|----------|---|--------|
| RMSNorm | 14.26% | 14.26% | 0% | ✓ Pass |
| InProjection | 14.55% | 14.55% | 0% | ✓ Pass |
| **SiLU** | 19.34% | 19.34% | 0% | ⚠️ FAIL (limit 20%) |
| YGated | 16.41% → 15.04% | **-1.37%** | ✓ Better |
| **FinalOut** | 53.91% | **53.12%** | **-0.79%** | ⚠️ Still critical |

## Trace Analysis: Exp_Unit output (Token 0, Channel 21)

### Golden (Q3.12)
```
h_state(t0) ≈ -23 (1011 0111 binary, Q3.12)
h_state(t1) ≈ +10 
scan_output(t0) ≈ -7
scan_output(t1) ≈ -117
```

### RTL Before Fix
```
Token0: h0=-30, y_scan=149 (wrong sign!)
Token1: h0=6,   y_scan=2589 (wrong sign!)
```

### RTL After Fix
```
Token0: h0=-8,   y_scan=131 ✓ Moving toward -23, but y_scan positive (WRONG SIGN!)
Token1: h0=1,    y_scan=2129 (sign still wrong, magnitude off)
```

## Root Cause Analysis

The latency fix successfully improved h_state accuracy:
- h0=-30 → h0=-8 (moving toward golden -23)
- Indicates exp_out (A_bar) is now being captured correctly

**BUT:** y_scan sign is still **systematically wrong** (positive instead of negative).

This suggests the issue is **downstream of Exp_Unit**, in the **C×h multiplication and/or gating logic** (S_STEP6 through S_STEP10).

### Hypothesis for y_scan sign flip

1. **C×h sign error**: When we multiply C[j] × h_reg[j], sign might be lost due to casting
   - Check: Is h_reg being preserved correctly as signed from h_new_temp?
   - Check: S_STEP6 assignment `h_reg[j] <= pe_result_vec[j]` during C×h? 
   
   Looking at S_STEP6:
   ```verilog
   S_STEP6: begin
       for(j=0; j<16; j=j+1) h_reg[j] <= pe_result_vec[j*16 +: 16];
       state <= S_STEP7;
   end
   ```
   **PROBLEM**: At S_STEP6, pe_result_vec contains **C×h** (from S_STEP5 computation), but code writes it to h_reg!
   - h_reg should hold h_new (state), not C×h
   - This corrupts state AND produces wrong scan output!

2. **Gating sign issue**: The gate multiplies y_with_D × silu_out, could lose sign

## Next Steps

### CRITICAL: Fix S_STEP6 h_reg assignment
`h_reg[j]` should NOT be updated from S_STEP6 pe_result_vec (which is C×h).
Instead:
- S_STEP5 output is h_new = exp*h + deltaBx
- S_STEP6 computes C×h_new using h_new from PREVIOUS iteration
- **h_reg should be updated AFTER S_STEP6 completes** (or in S_STEP5 before C mult)

### Verification needed
1. Trace C×h values in S_STEP6 - should they be negative?
2. Check gating logic output sign preservation
3. Review cascading 32-bit accumulator arithmetic for bit loss

## File Status
- Scan_Core_Engine.v: latency fix applied
- SiLU PWL: tuned coefficients applied (minimal benefit)
- Q-format: no changes (saturation audit showed 0% clip)

## Recommendation
The latency fix is correct and should remain. The y_scan sign error suggests a **separate, deeper logic bug in state update or output projection** that needs careful FSM and arithmetic review.
