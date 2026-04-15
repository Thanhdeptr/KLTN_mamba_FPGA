# KLTN Project Architecture Guide
---

## Current Active Workspace Scope

- Active folders in this workspace: `RTL/`, `ITMN/`, `py_software/`
- Moved out (external/archive): `dataset_PTB-XL/`, `pre-train/`, `paper/`, `mamba-venv/`
- Agent default behavior: focus on active folders first; only request external folders when regenerating model assets.

## 📌 Project Overview

**Title:** ITMN FPGA Accelerator - Inception Time Mamba Network for ECG Classification

**Goal:** Design and optimize an FPGA-based hardware accelerator for multi-label ECG classification using the Mamba architecture.

**Tech Stack:**
- **Model:** Inception-Time Mamba Network (ITMN) 
- **Hardware:** Vivado RTL (Verilog), Xilinx FPGA (KRIA KV260)
- **Flow:** Design → Validation → Optimization → SoC Integration → Deployment

**Three Implementation Phases:**
1. **Phase 1:** RTL correctness validation (module-level tests)
2. **Phase 2:** Pipeline optimization (timing closure, resource reduction)
3. **Phase 3:** SoC design and deployment on KRIA KV260

---

## 📁 Detailed Folder Structure

### 🔴 CORE FPGA HARDWARE (Phase 1-3)

#### `RTL/code_initial/`
**Purpose:** Initial RTL design (Verilog HDL) for Mamba accelerator  
**Responsibility Phase:** Phase 1 (Correctness), Phase 2 (Optimization)

**Contains:**
- **Core Modules:**
  - `Mamba_Top.v` - Top-level controller with 6 operation modes (Idle, Linear, Conv, Scan, Softplus, ITM_Block)
  - `ITM_Block.v` - Inception + Mamba pathway merger (Level-B architecture from paper)
  - `Scan_Core_Engine.v` - State-Space Model (SSM) core for Mamba recurrence
  
- **Primary Computation Units:**
  - `Conv1D_Layer.v` - 1D convolution (kernel=4, 16 channels parallel)
  - `Linear_Layer.v` - Fully connected linear transformation
  - `Unified_PE.v` - Time-multiplexed Processor Element (PE) array supporting MAC/MUL/ADD operations
  
- **Activation Functions (PWL approximation):**
  - `SiLU_Unit_PWL.v` / `SiLU_Unit.v` - Sigmoid Linear Unit using piecewise-linear representation
  - `Exp_Unit_PWL.v` / `Exp_Unit.v` - Exponential function
  - `Softplus_Unit_PWL.v` - Softplus activation
  
- **Memory & Support:**
  - `Memory_System.v` - Memory controller
  - `BRAM_256b.v` - Block RAM interface
  - `Global_Controller_Full_Flow.v` - Global control FSM
  - `_parameter.v` - Global parameter defines (DATA_WIDTH=16, D_MODEL=64, SEQ_LEN=1000, etc.)

**When to Use:**
- Architecture review and understanding module interactions
- Implementing functional changes or bug fixes
- Baseline correctness validation before optimization
- Performance critical path analysis

**When to Skip:**
- SoC integration phase (if only integrating existing verified RTL)
- Deployment phase (if no functional changes needed)
- Reviewing synthesis reports without rtl changes

**Key Design Details:**
- Fixed-point arithmetic: Q16 format (16-bit signed)
- Pipelined datapath with internal PE time-multiplexing
- Support for 16 parallel lanes (SIMD-like structure)
- Recurrent state storage for Mamba SSM hidden states

---

#### `RTL/code_AI_gen/`
**Purpose:** Generated test infrastructure + golden-data validation + baseline measurements  
**Responsibility Phase:** Phase 1 (Validation) → Phase 2+ (Regression testing)

**Contains:**

**Module Test Directories:**
```
test_SiLU_Unit_PWL/
test_Exp_Unit_PWL/
test_Softplus_Unit_PWL/
├── tb_*.v              - Verilog testbench
├── *.mem               - Input/weight/coefficient memory files
├── golden_output.mem   - Reference output from PyTorch model
├── rtl_output.mem      - Actual RTL simulation output
├── gen_vectors_and_compare.py - Python comparison script
└── run.sh              - Shell script to compile, simulate (xsim), and compare

test_Unified_PE/
test_Linear_Layer/
test_Conv1D_Layer/
test_Scan_Core_Engine/
test_ITM_Block/
test_Mamba_Top_ITM/    - Full integration test
```

**Synthesis & Timing Reports:**
```
synth_reports/
├── baseline/                      - Unconstrained synthesis (no clock constraint)
│   ├── *.rpt files               - Vivado reports (LUT/FF/DSP/timing)
│   └── Design without timing closure
├── constrained_ooc/               - Out-of-Context with clock constraints
│   ├── *.rpt files               - Post-route timing (WNS/TNS/Fmax)
│   ├── setup_hold reports        - Slack analysis
│   └── Design with realistic timing
```

**Analysis & Documentation:**
- `validation_and_baseline_report.md` - Summary of all test results (PASS/FAIL), resource usage (LUT/FF/DSP), and baseline measurements
- `test_inventory/README.md` - Mapping of golden vectors source (PyTorch model layer name → test input/output)
- `optimize_strategy_after_correctness.md` - Analysis of critical paths, hotspots, and optimization recommendations based on baseline

**When to Use:**
- Module-by-module correctness validation (before integration)
- Establishing baseline timing/resource measurements
- Regression testing after each RTL modification
- Benchmarking optimization impact (baseline vs. new synthesis)
- Debugging functional mismatches (compare golden vs. RTL output)

**When to Skip:**
- Pure architecture review (go to `code_initial/` instead)
- If only reading SoC integration code (not needed for SoC layout)
- During optimization phase if re-running synthesis without RTL changes

**Workflow Pattern:**
1. Extract golden vectors from PyTorch model (via `py_software/`)
2. Place in `test_*/` folders
3. Run `run.sh` → xsim compiles & simulates RTL → Python compares output
4. Record result in `validation_and_baseline_report.md`

---

#### `RTL/code_AI_gen_optimize/`
**Purpose:** Optimized RTL versions with pipeline/resource improvements (Phase 2 artifacts)  
**Responsibility Phase:** Phase 2 (Optimization) → Phase 3 (SoC integration with optimized RTL)

**Contains:**
```
scan_core_register_sum_break_path/             ← Example optimization technique
├── Scan_Core_Engine_optimized.v               - Optimized RTL (added registers to break critical path)
├── timing_out/                                - Post-route timing reports
│   ├── Scan_Core_Engine_opt_p6.667_timing_summary.rpt
│   ├── Scan_Core_Engine_opt_p6.667_utilization.rpt
│   └── opt_metrics.txt
├── golden_output.mem                          - Same golden data as Phase 1
├── rtl_output.mem                             - New RTL output (to verify correctness maintained)
├── gen_vectors_and_compare.py                 - Validation script
├── timing reports (before vs. after)
└── xsim.dir/                                  - Simulation artifacts (proof of correctness)
```

**Structure:**
- Each optimization technique gets its own subfolder
- Naming convention: `<module>_<optimization_technique>/`
- Examples: `scan_core_register_sum_break_path/`, `conv1d_output_pipeline/`, etc.

**When to Use:**
- Phase 2: After Phase 1 correctness validation PASSES completely
- Implementing pipeline improvements (adding registers to break long combinational paths)
- Resource optimization (constant folding, resource sharing)
- Timing closure attempts (meeting higher frequency targets)
- Comparing optimization effectiveness (baseline Fmax vs. optimized Fmax)

**When to Skip:**
- Phase 1: Never modify or create here until correctness fully validated
- SoC integration: Copy finalized optimized RTL from here to `code_initial/` when ready for deployment
- If optimization not yet approved by designer

**Important Constraint:**
- **Do NOT apply Phase 2 optimizations until Phase 1 validation PASSES completely**
- Each optimization must maintain functional correctness (compare golden output)
- Regression test must pass before considering optimization as "done"

---

#### `RTL/SOC/`
**Purpose:** System-on-Chip design - integrate RTL with AXI/APB protocols, top-level control, board interface  
**Responsibility Phase:** Phase 3 (SoC integration and deployment)

**Contains:**
```
RTL/SOC/
├── vivado_project/                   - Vivado project directory (or tcl scripts to build)
├── block_design/                     - Vivado block design (*.bd) for visual circuit composition
├── top_soc.v                         - SoC top-level wrapper integrating RTL + AXI/APB bridge
├── axi_wrapper.v                     - AXI slave wrapper for Mamba_Top RTL
├── constraints/
│   ├── kria_kv260.xdc               - Pin constraints for KRIA KV260 board
│   └── clock_constraint.xdc         - Clock definitions for SoC
├── ip_repo/                          - Custom IP definitions
├── test_soc_integration.tcl          - TCL script for SoC integration validation in Vivado
└── deployment/
    ├── bitstream/                   - Generated FPGA bitstream (.bit/.bin)
    └── device_tree/                 - Device tree for Linux kernel (if applicable)
```

**When to Use:**
- Phase 3: Only after RTL is fully optimized and validated
- Integrating RTL into larger SoC context
- Adding AXI memory-mapped interface for PS (Processing System) access
- Board-specific constraints (IO, power, cooling)
- Generating FPGA bitstream for deployment on KRIA KV260

**When to Skip:**
- Phases 1-2: Focus on RTL correctness and optimization first
- SoC layout doesn't affect RTL correctness or timing
- Iterative optimization work (stay in `code_initial/` and `code_AI_gen/`)
- If deploying on simulation-only or different target board

**Dependencies:**
- `RTL/code_initial/` (or optimized version from `code_AI_gen_optimize/`) must be finalized before SoC design
- KRIA KV260 datasheet and reference designs
- Vivado HLS or custom IP if adding PS-side accelerators

---

### 🟡 PYTHON MODEL & DATA EXTRACTION (Support across all phases)

#### `ITMN/`
**Purpose:** Official ITMN PyTorch model implementation - for generating golden vectors and understanding model behavior  
**Responsibility Phase:** All phases (especially Phase 1 for golden generation)

**Contains:**

**Core Files:**
- `main.py` - Model training script
- `test.py` - Model inference script
- `dataset.py` - Dataset loading (PTB-XL)
- `config.yaml` - Configuration (exp_type: super/sub/rhythm/all/diag/form/cpsc)
- `requirements.txt` - Python dependencies (torch, mamba-ssm, etc.)

**Model Architecture:**
- `ecg_models/` - ITMN model definitions
  - Contains Mamba blocks, Inception blocks, layer definitions
  - Read to understand forward() pass and layer order

**Golden Reference Data:**
- `golden_vectors/` - Binary golden vectors extracted from checkpoint
  - `golden_input.bin` - Input ECG signal sample
  - `golden_output.bin` - Final model output (class predictions)
  - `*_weight.bin` - Layer weights/biases
  - `A_log.bin`, `D.bin`, etc. - SSM parameters

- `cpp_golden_files/` - Intermediate layer outputs (text format)
  - Numbered by computation step: `00_input`, `01_after_encoder`, `02_after_conv`, etc.
  - Used for multi-layer validation (not just input/output)

**Supporting:**
- `data/` - Train/val/test split definitions
- `losses/` - Loss function implementations
- `utils/` - Utility functions
- `silu_golden/` - Pre-computed golden SiLU values

**When to Use:**
- Extracting golden vectors for RTL test benches
- Understanding model internal behavior (for debug)
- Validating PyTorch output matches expected behavior
- Regenerating golden data if checkpoint changes
- Understanding layer ordering and tensor dimensions

**When to Skip:**
- Pure RTL design review (architecture already understood)
- RTL synthesis optimization (no Python needed)
- SoC integration (assuming golden vectors already extracted)
- If deploying pre-validated golden data (no model code changes)

**How It Connects:**
```
ITMN/config.yaml → specify exp_type (super for FPGA)
    ↓
ITMN/checkpoint  ← select from external checkpoint archive
    ↓
py_software/extract_*.py     ← extract weights/golden
    ↓
golden_vectors/ + cpp_golden_files/
    ↓
RTL/code_AI_gen/test_*/      ← use for test benches
```

---

#### `py_software/`
**Purpose:** Utilities to convert PyTorch model → FPGA-friendly formats (weights, golden data, PWL coefficients)  
**Responsibility Phase:** Phase 1 (goldens), Phase 2 (if quantization changes)

**Contains:**

**Golden Vector Extraction:**
- `extract_weight_shape.py` - Extract layer weights/biases → `.bin` files
- `extract_single_sample.py` - Forward one sample through model → intermediate layer outputs
- `pack_mamba_golden_to_rtl_init.py` - Pack golden vectors into Verilog memory init format

**PWL Approximation Generators:**
- `gen_silu_pwl.py` - Generate PWL coefficients for SiLU activation
- `gen_softplus_exp_pwl.py` - Generate PWL for Softplus and Exp units
- `make_silu_q87_mem.py` - Quantize PWL to Q8.7 fixed-point → `.mem` file format

**Utilities:**
- `gen_rtl_mem_from_bin.py` - Convert binary weights → Verilog `.mem` format
- `silu_graph.py` - Visualize PWL accuracy vs. reference function
- `extract_single_sample.py` - Generate intermediate tensors for multi-layer validation

**Output Files:**
- `*.mem` - Verilog memory initialization files (human-readable hex format)
- `*_weight.bin` - Binary weight files
- `*.csv` - Comparison tables (e.g., `silu_y_ref_vs_rtl.csv`)
- `*.png` - Visualization plots

**When to Use:**
- Exporting golden data from checkpoint
- Regenerating `.mem` files if changing quantization or model
- Validating PWL approximation accuracy
- Understanding weight distribution / quantization effects

**When to Skip:**
- RTL architecture review
- Timing optimization (Python code doesn't affect timing)
- If `.mem` files already stable and not changing checkpoint

**Key Parameter:**
- Edit scripts to change `exp_type` (super/sub/rhythm/etc.)
- Ensure `config.yaml` points to correct checkpoint file

---

### 🟢 SUPPORT & EXTERNAL DATA (Use selectively, skip for pure RTL work)

Note: The folders in this section are currently moved out of the active workspace and treated as external sources.

#### `pre-train/`
**Purpose:** Pre-trained model checkpoints (saved PyTorch weights)  
**Status:** External data (do NOT modify in this project)

**Contains:**
```
PTB-XL_SUPER_ITMN_DB.pth      ← Recommended for FPGA (simplest: 5 classes)
PTB-XL_SUB_ITMN_DB.pth         - Subordinate classification
PTB-XL_RHYTHM_ITMN_DB.pth      - Rhythm classification
PTB-XL_ALL_ITMN_DB.pth         - Combined classification
PTB-XL_DIAG_ITMN_DB.pth        - Diagnostic classification
PTB-XL_FORM_ITMN_DB.pth        - Form classification
```

**When to Use:**
- Phase 1: Loading checkpoint to generate golden vectors
- If retraining or fine-tuning model
- Reference for model performance on different tasks

**When to Skip:**
- RTL design/optimization (checkpoints not needed)
- SoC deployment (weights already extracted to `.mem` files)
- Pure architecture review

---

#### `dataset_PTB-XL/`
**Purpose:** ECG waveform dataset (raw data)  
**Status:** External research dataset

**Contains:**
- `ptbxl_database.csv` - Metadata (patient info, diagnoses, splits)
- `records100/`, `records500/` - Raw ECG signal files (WFDB format)
- Documentation & license

**When to Use:**
- Training model from scratch
- Validating dataset preprocessing

**When to Skip:**
- ✅ **SKIP FOR FPGA RTL WORK** (no ECG data processing needed in hardware initially)
- SoC deployment (datasets not used in inference)
- RTL design optimization

---

#### `mamba-venv/`
**Purpose:** Python virtual environment with all dependencies  
**Status:** Development environment

**Contains:**
- Installed packages: mamba-ssm, torch, numpy, etc.

**How to Use:**
```bash
source mamba-venv/bin/activate
cd ITMN
python extract_weight_shape.py --exp_type super
```

**When to Skip:**
- ✅ **SKIP IF ONLY REVIEWING CODE** (Venv not needed for code review)
- Hardware deployment phase
- Vivado RTL design/synthesis

---

#### `paper/`
**Purpose:** Academic paper reference  
**Status:** Documentation

**Contains:**
- `ECG_Multilabel_Classification_manuscript.txt` - Full paper text

**When to Use:**
- Understanding Mamba architecture theory
- Understanding inception module design
- Citing work

**When to Skip:**
- ✅ **SKIP FOR RTL DESIGN** (implementation details already in model code)
- Optimize phase (architecture already understood)

---

## 📊 Quick Reference: When to Use Each Folder

| **Objective** | **Folders to Use** | **Folders to Skip** |
|---|---|---|
| **Understand RTL architecture** | `RTL/code_initial/` (review `.v` files) | External/archive folders |
| **Review Mamba block design** | `RTL/code_initial/Scan_Core_Engine.v` + `ITMN/ecg_models/` | External/archive folders |
| **Extract golden vectors (Phase 1 start)** | `ITMN/` + `py_software/` | RTL optimize, SOC |
| **Run module tests** | `code_AI_gen/test_*/` + Python scripts | Large folders |
| **Validate correctness** | `RTL/code_AI_gen/` + `validation_and_baseline_report.md` | External/archive folders |
| **Analyze baseline timing/resource** | `RTL/code_AI_gen/synth_reports/baseline/` + reports | External/archive folders |
| **Optimize pipeline (Phase 2)** | `RTL/code_initial/` + `RTL/code_AI_gen_optimize/` + regression tests | External/archive folders |
| **Compare optimization impact** | `RTL/code_AI_gen/synth_reports/constrained_ooc/` vs. baseline | External/archive folders |
| **SoC integration (Phase 3)** | `RTL/SOC/` + finalized `RTL/code_initial/` | Non-RTL folders |
| **Deploy to KRIA KV260** | `RTL/SOC/` + generated bitstream | ITMN, py_software, external data |
| **Fine-tune quantization** | `py_software/gen_*_pwl.py` + `ITMN/` | RTL folders if no PWL changes |

---

## 🎯 Typical Development Workflow

### **Phase 1: Correctness Validation**
```
1. Review architecture
   └─→ code_initial/ (understand each module)

2. Extract golden vectors
   └─→ ITMN/ + py_software/ (generate .mem files)

3. Module-by-module testing
   └─→ code_AI_gen/test_*/ (run each test)

4. Record validation
   └─→ code_AI_gen/validation_and_baseline_report.md

5. Decision: ALL PASS?
   └─→ YES: Continue to Phase 2
   └─→ NO: Debug in code_initial/ + re-test
```

### **Phase 2: Optimization (After Phase 1 ✅)**
```
1. Identify hotspots
   └─→ code_AI_gen/optimize_strategy_after_correctness.md

2. Apply optimization technique
   └─→ Create subfolder in code_AI_gen_optimize/
   └─→ Modify RTL in code_initial/ (or create optimized copy)

3. Validate correctness maintained
   └─→ Re-run code_AI_gen/test_*/ (regression)

4. Measure new timing
   └─→ code_AI_gen/synth_reports/constrained_ooc/

5. Compare: Better Fmax/Resource?
   └─→ YES: Accept optimization, document in optimize_strategy
   └─→ NO: Try different technique
```

### **Phase 3: SoC & Deployment (After Phase 2 ✅)**
```
1. Prepare finalized RTL
   └─→ Ensure code_initial/ or code_AI_gen_optimize/ is production-ready

2. SoC integration
   └─→ RTL/SOC/ (add AXI wrapper, board constraints)

3. Vivado bitstream generation
   └─→ Synthesize full SoC

4. Deploy to KRIA KV260
   └─→ Load bitstream + device tree
   └─→ Test on hardware
```

---

## 🚨 Critical Path Rules

### ❌ **NEVER Skip Phase 1**
- Do not optimize before correctness is proven
- All module tests must PASS (0 mismatches)
- Golden vectors must be generated correctly

### ❌ **NEVER Modify RTL Without Testing**
- Every change → re-run module tests
- Compare golden vs. new RTL output
- Record in validation report

### ❌ **NEVER Begin Phase 3 Without Phase 2 Completion**
- SoC integration assumes RTL is final and optimized
- No major changes after SoC design (costly to redo placement/routing)

### ✅ **ALWAYS Use Binary Search for Timing**
- Don't interpolate Fmax between clock periods
- Use coarse sweep (10ns, 8ns, 6ns) to bracket pass/fail
- Binary search within bracket for accurate Fmax

### ✅ **ALWAYS Validate Multi-Seed**
- Vivado placement is non-deterministic
- Run 3-5 seeds at candidate Fmax
- Accept only if ≥80% pass

---

## 📝 File Format Reference

### Memory Files (`.mem`)
**Format:** Verilog hex memory initialization
```
// Example: 16-bit signed values, 64 entries
0x0F2A
0xFEAB
0x1234
...
```
**Usage:** Load into simulation via `$readmemh("file.mem", mem_array);`

### Comparison Script (`compare.py` / `gen_vectors_and_compare.py`)
**Outputs:**
```
Total samples: 4096
Matched: 4096
Mismatches: 0
Error rate: 0.00%
Result: PASS ✓
```

### Report Files (Vivado)
- `*_timing_summary.rpt` - Setup/hold violations, WNS, TNS, datasheet-based Fmax
- `*_utilization.rpt` - LUT/FF/DSP/BRAM usage by module
- `*_route_status.rpt` - Routing congestion, unrouted nets

---

## 🤝 For AI Agents / LLM Context

**When analyzing this repository:**

1. **Always start by reading:** `PROJECT_ARCHITECTURE.md` (this file) + `copilot-instructions.md`
2. **Ask clarifying questions:**
   - "Are we in Phase 1 (validation), Phase 2 (optimization), or Phase 3 (deployment)?"
   - "Do we need to review RTL design, extract golden data, run tests, or optimize?"
3. **Avoid unnecessary file access:**
   - If Phase 1 → don't read `optimize_strategy` or `code_AI_gen_optimize/`
   - If Phase 2 optimization → don't read training scripts or dataset code
   - If Phase 3 SoC → don't read Python model extraction code
4. **Validate before proceeding:**
   - Check `validation_and_baseline_report.md` before starting Phase 2
   - Verify previous phase completion before moving forward
5. **Document changes:**
   - Update `optimization_strategy_after_correctness.md` after Phase 2 work
   - Record timing/resource changes systematically

---

## 📚 Related Documentation

- `RTL/code_AI_gen/validation_and_baseline_report.md` - Phase 1 validation results
- `RTL/code_AI_gen/optimize_strategy_after_correctness.md` - Phase 2 optimization strategy
- `ITMN/README.md` - Model training/testing instructions
- `RTL/code_initial/_parameter.v` - Global design parameters

---
