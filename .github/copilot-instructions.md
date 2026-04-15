Response Rules:

    Fact-Checking: When providing factual information, you must verify it against specific sources (prioritizing official documentation). If data is unavailable, honestly state that you do not know instead of hallucinating or guessing.

    Workflow: Always propose the solution plan first. Wait for the user's approval before writing or updating any code.

    Communication Language: Respond and converse with the user in Vietnamese.

    Code Language: Use English for all code content (variables, comments, strings, documentation).

    File Generation: Do not generate .md (Markdown) files unless explicitly requested.

Project Architecture (KLTN ITMN FPGA Accelerator):

## 🎯 CURRENT ACTIVE SCOPE (Tập trung vào scope này)
    - Active: RTL/ (code_initial, code_AI_gen, code_AI_gen_optimize, SOC), ITMN/, py_software/
    - External (bỏ qua khi code RTL): dataset_PTB-XL/, pre-train/, paper/, mamba-venv/

## 🔴 CORE FPGA HARDWARE FOLDERS (Quan trọng chính)

    RTL/code_initial/ → RTL ban đầu (Verilog HDL)
        Chứa:
            - Mamba_Top.v (top-level, 6 mode: Idle/Linear/Conv/Scan/Softplus/ITM_Block)
            - ITM_Block.v (Inception + Mamba pathway + merge output)
            - Conv1D_Layer.v (kernel=4, 16 channels song song)
            - Scan_Core_Engine.v (SSM core - lõi Mamba)
            - Unified_PE.v (PE array - MAC/MUL/ADD time-multiplex)
            - Linear_Layer.v (fully connected)
            - SiLU_Unit_PWL.v, Exp_Unit_PWL.v, Softplus_Unit_PWL.v (activation - PWL)
            - Memory_System.v, BRAM_256b.v, Global_Controller_Full_Flow.v
            - _parameter.v (global defines: DATA_WIDTH=16, D_MODEL=64, SEQ_LEN=1000, ...)
        
        Khi nào dùng: 
            - Review kiến trúc RTL, hiểu module interaction
            - Phase 1: Validation correctness (module-level test)
            - Phase 2: Tối ưu pipeline/resource
        
        Khi nào bỏ qua: 
            - SoC integration Phase 3 (nếu không thay RTL)
            - Deployment (nếu code ổn định)

    RTL/code_AI_gen/ → Test framework + baseline measurements
        Chứa:
            - test_*/ (9 directories - từ module nhỏ → lớn):
              • test_SiLU_Unit_PWL/, test_Exp_Unit_PWL/, test_Softplus_Unit_PWL/ (activation units)
              • test_Unified_PE/ (PE array)
              • test_Linear_Layer/, test_Conv1D_Layer/, test_Scan_Core_Engine/ (main layers)
              • test_ITM_Block/, test_Mamba_Top_ITM/ (integration)
              Mỗi test có: tb_*.v, *.mem (input/weight), golden_output.mem, rtl_output.mem, compare.py, run.sh
            
            - synth_reports/baseline/ (synthesis unconstrained - chưa có clock constraint)
            - synth_reports/constrained_ooc/ (synthesis có clock - post-route Fmax thực)
            
            - validation_and_baseline_report.md (tóm tắt: test results, resource LUT/FF/DSP)
            - test_inventory/README.md (mapping golden vectors từ ITMN layers)
            - optimize_strategy_after_correctness.md (chiến lược tối ưu dựa baseline)
        
        Khi nào dùng:
            - Phase 1: Validation module từng cái một (test nhỏ → lớn)
            - Lấy baseline timing/resource trước optimize
            - Regression test sau mỗi lần sửa RTL
            - Debug functional mismatch (so sánh golden vs RTL output)
        
        Khi nào bỏ qua:
            - Architecture pure review (dùng code_initial/ thay)
            - SoC layout (Phase 3, nếu không thay RTL)

    RTL/code_AI_gen_optimize/ → RTL optimize version (Phase 2 artifacts)
        Ví dụ: scan_core_register_sum_break_path/ (thêm register để break long path)
        
        Chứa:
            - Optimized RTL versions của modules
            - timing_out/ (post-route timing reports: WNS/TNS/Fmax)
            - Test correctness (chạy lại xsim + compare)
            - xsim.dir/ (simulation artifacts - proof)
        
        Khi nào dùng:
            - CHỈ sau Phase 1 validation HOÀN TOÀN PASS
            - Implementation pipeline improvement (add register để break critical path)
            - Resource optimization
            - Timing closure attempt (meet higher frequency target)
        
        Khi nào bỏ qua:
            - Phase 1 chưa pass
            - Chưa approval tối ưu từ designer
            - Functional change (không phải optimization)

    RTL/SOC/ → System-on-Chip integration (Phase 3 - deployment)
        Sẽ chứa:
            - Vivado project / block design files
            - top_soc.v (wrapper tích hợp RTL + AXI/APB)
            - axi_wrapper.v (AXI slave interface)
            - constraints/ (KRIA KV260 pins, clock definitions)
            - bitstream/ (FPGA bitstream để nạp board)
        
        Khi nào dùng:
            - CHỈ sau Phase 2 (RTL optimize xong)
            - Tích hợp RTL vào SoC context
            - Thêm AXI memory-mapped interface
            - Board constraints (IO, power)
        
        Khi nào bỏ qua:
            - Phase 1-2 (code còn validate/optimize)
            - Iterative optimization (ở code_initial/ + code_AI_gen/)

## 🟡 PYTHON MODEL & EXTRACTION (Support tools)

    ITMN/ → Official Mamba ECG model (PyTorch) - trích xuất weight + golden vectors
        Chứa:
            - main.py (training script)
            - test.py (inference script)
            - dataset.py (data loading)
            - config.yaml (exp_type: super/sub/rhythm/all/diag/form/cpsc)
            - ecg_models/ (ITMN architecture definition)
            - golden_vectors/ (input/output .bin, weight .bin)
            - cpp_golden_files/ (intermediate tensor outputs - txt)
            - data/, losses/, utils/, requirements.txt
        
        Khi nào dùng:
            - Trích xuất golden để test RTL testbench
            - Debug mô hình behavior
            - Validate PyTorch output đúng
            - Regenerate golden nếu thay checkpoint
        
        Khi nào bỏ qua:
            - RTL đã validate ✓
            - Ko thay checkpoint
            - Phase 3 SoC (nếu golden đã extract)

    py_software/ → Utilities convert PyTorch → FPGA formats (.mem, .bin, PWL coeffs)
        Chứa:
            - extract_weight_shape.py (weight → .bin)
            - extract_single_sample.py (forward sample → golden vectors)
            - gen_silu_pwl.py, gen_softplus_exp_pwl.py (generate PWL coefficients)
            - make_silu_q87_mem.py (quantize PWL → Q8.7 → .mem file)
            - gen_rtl_mem_from_bin.py (convert binary → Verilog .mem format)
            - pack_mamba_golden_to_rtl_init.py (pack golden → RTL testbench init)
            - silu_graph.py, silu_output_rtl.txt (validation utilities)
        
        Khi nào dùng:
            - Export golden từ checkpoint cho trước lần đầu
            - Regenerate .mem files nếu thay quantization strategy
            - Debug PWL accuracy
        
        Khi nào bỏ qua:
            - .mem files sẵn + ko thay checkpoint/quantization
            - Phase 3 SoC (golden đã fixed)

## 🟢 EXTERNAL/ARCHIVE (Bỏ qua 99% - chỉ dùng khi cần regenerate golden)

    dataset_PTB-XL/ → ECG dataset raw (WFDB format)
        Bỏ qua cho: RTL design/optimize. Chỉ dùng: training model từ đầu (ko cần cho FPGA)

    pre-train/ → Checkpoint models (PTB-XL_SUPER/SUB/RHYTHM/ALL/DIAG/FORM_ITMN_DB.pth)
        Bỏ qua cho: RTL code. Chỉ dùng: select checkpoint để extract golden (via ITMN/test.py)

    mamba-venv/ → Python virtual environment (Mamba SSM + PyTorch)
        Bỏ qua cho: RTL design. Dùng: source venv && python ITMN/test.py để extract golden

    paper/ → Paper documentation
        Bỏ qua cho: RTL code review. Reference: lý thuyết kiến trúc model

## 📊 QUICK DECISION TABLE

    Task                              | Folders cần xem             | Folders bỏ qua
    ──────────────────────────────────┼─────────────────────────────┼────────────────────────────
    Review RTL architecture           | code_initial/               | ITMN, dataset, pre-train, venv, paper
    Validate module correctness (P1)  | code_AI_gen/test_*/         | damtaset, paper, pre-train, venv
    Extract golden từ model           | ITMN/ + py_software/        | RTL optimize, dataset
    Baseline timing/resource          | code_AI_gen/synth_reports/  | ITMN, dataset, py_software
    Phase 2 optimization              | code_initial/ → code_AI_gen_optimize/ | dataset, pre-train, venv
    Regression test post-optimize     | code_AI_gen/test_*/         | (re-run tests)
    SoC integration + deployment      | SOC/ + final code_initial/  | ITMN, dataset, py_software
    Debug PWL accuracy                | py_software/ + ITMN/        | code_AI_gen (chỉ high-level)

