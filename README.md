# KLTN - ITMN Pretrain & Xuất Weight/Golden

Trích xuất weight và golden vectors từ mô hình ITMN (ECG classification) để port sang C++/FPGA.

## Current Active Workspace Scope

- Active folders: `RTL/`, `ITMN/`, `py_software/`
- Moved out of current workspace (external/archive): `dataset_PTB-XL/`, `pre-train/`, `paper/`, `mamba-venv/`
- Agent note: ưu tiên đọc các folder active trước, chỉ dùng dữ liệu external khi cần regenerate weight/golden.

## Checkpoint (external archive)

| File | exp_type | Số lớp |
|------|----------|--------|
| PTB-XL_SUPER_ITMN_DB.pth | super | 5 |
| PTB-XL_SUB_ITMN_DB.pth | sub | 23 |
| PTB-XL_DIAG_ITMN_DB.pth | diag | 44 |
| PTB-XL_FORM_ITMN_DB.pth | form | 19 |
| PTB-XL_RHYTHM_ITMN_DB.pth | rhythm | 12 |
| PTB-XL_ALL_ITMN_DB.pth | all | 71 |

**FPGA/Verilog:** dùng **SUPER** (đơn giản nhất, 5 lớp).

## Xuất weight & golden

Trích từ **MambaBlock đầu tiên** (`layers.0.mamba_block`).

```bash
source mamba-venv/bin/activate
cd ITMN
```

```bash
# Weight + golden I/O → golden_vectors/
PYTHONPATH=. python ../py_software/extract_weight_shape.py --exp_type super

# Tensor trung gian → cpp_golden_files/
PYTHONPATH=. python ../py_software/extract_single_sample.py --exp_type super
```

**Lưu ý:** Sửa `test_ckpt_path` trong `ITMN/config.yaml` khớp với checkpoint muốn dùng.

## Output

- `golden_vectors/`: `golden_input.bin`, `golden_output.bin`, các `*_weight.bin`, `A_log.bin`, `D.bin`
- `cpp_golden_files/`: tensor txt theo từng bước forward
