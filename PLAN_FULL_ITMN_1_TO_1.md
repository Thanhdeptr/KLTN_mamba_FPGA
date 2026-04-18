# ITMN Full 1:1 Implementation Plan
## Architecture Comparison: Paper vs Current RTL

---

## 📋 ITMN Architecture (Paper - Full Implementation)

```
Input (12, 1000)
    ↓
[Conv1D k=1, c_out=64] → BatchNorm → (64, 1000)
    ↓
Encoder
    ↓
maxpool2d(2, 2) ──────────────────────────────────────┐
    ↓                                                    │
ITMBlock 1 (in=64, out=64):                            │
  ├─ Conv1D(64→64, k=1) + BatchNorm                    │
  ├─ Inception Path:                                   │
  │  └─ Bottleneck(64→16)                             │
  │     ├─ Conv(16, k=1)   → output1                  │
  │     ├─ Conv(16, k=9)   → output2                  │
  │     ├─ Conv(16, k=19)  → output3                  │
  │     ├─ Conv(16, k=39)  → output4                  │
  │     └─ Concat [o1,o2,o3,o4] → BatchNorm + ReLU   │
  ├─ Mamba Path:  (input transpose T→L)              │
  │  ├─ RMSNorm (64,)                                 │
  │  ├─ Mamba SSM (selective state-space)            │
  │  └─ Transpose back  (L→T)                        │
  ├─ Merge: x1_inception + x2_mamba                   │
  └─ ReLU                                             │
    ↓
ITMBlock 2 (same structure) → (64, 1000)
    ↓
MaxPool(2,2) → (64, 500)
    ↓
ITMBlock 3 (in=64, out=64) → (64, 250)
    ↓
[GAP + FC] → Classifier → Logits (5,)
```

---

## 🔴 Current RTL Simplified Version

```
Input (12/16 lanes parallel multiplexed over time)
    ↓
Mode 0: Idle
Mode 1: Linear_Layer
Mode 2: Conv1D_Layer (k=4 only, single path)  ← SIMPLIFICATION
Mode 3: Scan_Core_Engine (FSM-based SSM)      ← SIMPLIFICATION
Mode 4: Softplus_Unit_PWL
Mode 5: Mamba_Top -> ITM_Block -> Inception + Scan merge
    ↓
RTL Architecture Issues:
- Conv1D_Layer: Only k=4 kernel (paper has 1,9,19,39)
- No RMSNorm block (critical for Mamba path)
- Scan_Core_Engine: SSM core is there BUT no explicit pre-norm
- ITM_Block: Merges Conv+Scan but simplified structure
```

---

## ✅ Blocks to Add/Modify

### **BLOCK 1: RMSNorm_Unit** ← CRITICAL, ADD FIRST
**Status:** ❌ Missing in RTL
**Needed for:** Mamba path normalization
**Implementation:**
```verilog
module RMSNorm_Unit(
  input [15:0] x_vec[15:0],        // 16 lanes of dimension D=64
  input [15:0] scale_weight[15:0], // RMSNorm learnable weight
  output [15:0] y_vec[15:0]        // normalized output
);
// compute x^2, mean(-1), rsqrt, scale
// Output = x * rsqrt(x^2.mean + eps) * weight
```
**Golden data needed:**
- Input: `rmsn_input.npy` (1, 64)
- Weight: `rmsn_weight.npy` (64,)
- Output: `rmsn_output.npy` (1, 64)

**File:** `RTL/code_initial/RMSNorm_Unit.v`

---

### **BLOCK 2: BaseInceptionBlock_Full** ← ADD SECOND
**Status:** ❌ Missing, only Conv1D_Layer (k=4)
**Needed for:** Inception path with 4 parallel kernels
**Current:** `Conv1D_Layer.v` (single k=4)
**Paper:** 4 parallel paths (k=1, 9, 19, 39) → concat → BatchNorm + ReLU

**Implementation:**
```verilog
module BaseInceptionBlock_Full(
  input [15:0] x_vec[15:0],           // (64, L) = 16 lanes * 4 tiles
  
  // 4 parallel conv paths
  output conv_k1_mode, conv_k9_mode, conv_k19_mode, conv_k39_mode,
  input [15:0] conv_k1_out[15:0], conv_k9_out[15:0], conv_k19_out[15:0], conv_k39_out[15:0],
  
  // merge (concat)
  output [15:0] y_vec[15:0]          // (64,) output = concat 4x16
);
// Share PE array, time-mux 4 conv operations
```

**Golden data needed:**
- Input: `inception_input.npy` (1, 64)
- Weights: `inception_conv_k1_weight.npy`, `k9_weight.npy`, `k19_weight.npy`, `k39_weight.npy`
- Output: `inception_output.npy` (1, 64)

**File:** `RTL/code_initial/BaseInceptionBlock_Full.v`
**Old file:** `Conv1D_Layer.v` (keep for reference, mark as deprecated)

---

### **BLOCK 3: MambaBlock_Full** ← ADD THIRD (verify existing)
**Status:** ⚠️ Partially exists (Scan_Core_Engine exists, but might need RMSNorm + projection layers)
**Needed for:** Full Mamba block = RMSNorm(input) + SSM(x) + output_projection

**Check current `Scan_Core_Engine.v`:**
- Does it have RMSNorm before SSM? → If NO, need to add
- Does it have explicit input/output projections? → If NO, might need to add

**Implementation:**
```verilog
module MambaBlock_Full(
  input [15:0] x_vec[15:0],         // (64,)
  
  // RMSNorm stage
  output rmsn_mode,
  input [15:0] x_normed[15:0],
  
  // SSM scan stage
  output ssm_mode,
  input [15:0] ssm_out[15:0],       // from Scan_Core_Engine
  
  output [15:0] y_vec[15:0]         // final Mamba output
);
// Flow: input → RMSNorm → SSM_core → output
```

**Decision:** Need to check if current `Scan_Core_Engine.v` already handles this.
- If YES → Just verify + write test
- If NO → Add RMSNorm + projection modules

**File:** `Scan_Core_Engine.v` (modify if needed) or create `Scan_Core_Engine_Full.v`

---

### **BLOCK 4: ITMBlock_Full** ← VERIFY/MODIFY (existing)
**Status:** ⚠️ Exists but simplifiedified
**Needed for:** Orchestrate Inception + Mamba paths

**Current issue:**
- Paper: `ITMBlock = Conv(in→out) + ReLU + Inception_path + Mamba_path + Merge + ReLU`
- RTL: `ITM_Block.v` exists but might be time-multiplexed differently

**Verification needed:**
1. Does current `ITM_Block.v` have Conv1D(64→64, k=1)?
2. Does it orchestrate Inception + Scan properly?
3. Merge logic: x_inception + x_scan, then ReLU?

**File:** `RTL/code_initial/ITM_Block.v`

---

## 📊 Testing Strategy

### **Phase 1: Validate Existing Blocks**
Test these blocks with **NEW golden data** from real ITMN:

```
Test 1: Conv1D_Layer  (current) 
  - Use Inception branch golden output from paper model
  - Expected: Conv(64→64, k=4) matches PyTorch Inception branch
  
Test 2: Scan_Core_Engine (current)
  - Use Mamba branch golden output from paper model
  - Expected: SSM output matches PyTorch Mamba branch
  
Test 3: ITM_Block (current)
  - Merge Conv+Scan output
  - Expected: Final ITMBlock output matches PyTorch
```

**Golden files location:** `/ITMN/golden_vectors_full_itmn_1_1/`

---

### **Phase 2: Add New Blocks (if existing fail)**
If Phase 1 tests PASS → Keep existing blocks
If Phase 1 tests FAIL → Add new blocks

1. **RMSNorm_Unit** - standalone test
2. **BaseInceptionBlock_Full** - test 4 kernels
3. **MambaBlock_Full** (if Scan_Core needs RMSNorm)
4. **ITMBlock_Full** - integration test

---

## 🎯 Next Steps

### **IMMEDIATE (Next Hour):**
1. ✅ Create extract_full_itmn_golden.py script
2. Run script to generate golden data
3. Create folder structure:
   ```
   RTL/code_AI_gen/
     test_Existing_Blocks/  (test Conv1D + Scan with new golden)
     test_New_Blocks/       (test RMSNorm, Inception, Mamba once added)
   ```

### **PHASE 1 (TODAY):**
1. Extract full ITMN golden
2. Test existing Conv1D_Layer, Scan_Core_Engine
3. Identify gaps/mismatches

### **PHASE 2 (IF NEEDED):**
1. Implement RMSNorm_Unit.v
2. Implement BaseInceptionBlock_Full.v (4 kernels)
3. Modify Scan_Core_Engine if needed
4. Test integration

---

## 📁 File Organization

```
RTL/code_initial/
  ├── Mamba_Top.v (top-level, unchanged)
  ├── ITM_Block.v (existing, verify)
  ├── Conv1D_Layer.v (existing, test with new golden)
  ├── Scan_Core_Engine.v (existing, test with new golden)
  ├──● RMSNorm_Unit.v (NEW if needed)
  ├──● BaseInceptionBlock_Full.v (NEW if needed)
  ├── Unified_PE.v (existing)
  ├── ... (other support modules)
  
RTL/code_AI_gen/
  ├── test_Conv1D_Layer/ (update with new golden)
  ├── test_Scan_Core_Engine/ (update with new golden)
  ├── test_ITM_Block/ (update with new golden)
  ├──● test_RMSNorm_Unit/ (NEW if adding)
  ├──● test_BaseInceptionBlock_Full/ (NEW if adding)
  
ITMN/golden_vectors_full_itmn_1_1/  ← Output of extract script
  ├── intermediates/
  ├── layers/
  ├── mamba_internals/
```

---

## ⏱️ Timeline Estimate

| Phase | Task | Duration |
|-------|------|----------|
| 0 | Extract golden data | 30 min |
| 1 | Test existing blocks | 1-2 hours |
| 2 (if fail) | Implement RMSNorm | 30 min |
| 2 (if fail) | Implement BaseInceptionBlock | 1 hour |
| 2 (if fail) | Test & integrate | 1 hour |
| 3 | Timing closure | 1-2 hours |

---

## 🔗 References

- Paper ITMN: `/home/hatthanh/schoolwork/KLTN/paper/ECG_Multilabel_Classification_manuscript.txt`
- Repo ITMN: `https://github.com/tnquoc/ITMN`
- Local PyTorch ITMN: `/home/hatthanh/schoolwork/KLTN/ITMN/ecg_models/ITMN.py`
- Current RTL: `/home/hatthanh/schoolwork/KLTN/RTL/code_initial/`
