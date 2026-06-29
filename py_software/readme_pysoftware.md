## inprojection_mem_banks
 py code for generate and check bank mem in Inprojection module 

## extract_single_sample.py
 py code using pytorch model(pretrain checkpoint,dataset) to gen txt file to cpp_golden_files for input mem, golden output mem or dynamic variable mem that change by datain and weight (EX:delta, B, C for scan)

## golden_validation/
 Cross-check `extract_single_sample` vs ITMN forward vs `mamba_ssm`, with plots and report under `reports/golden_validation/`.
 Run: `./py_software/golden_validation/run_full_validation.sh`

## extract_weight_shape.py
 py code using pytorch model(pretrain checkpoint,dataset) to gen txt file to cpp_golden_files for weight mem and static variable mem (weight and A D vec for scan)

## extract_real_rtl_golden.py
 py code using cpp_golden_files(from above pycode) to gen .mem file feeding to RTL code 


