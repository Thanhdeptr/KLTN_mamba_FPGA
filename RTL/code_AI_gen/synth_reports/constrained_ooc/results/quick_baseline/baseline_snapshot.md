# Baseline Snapshot (rough)

| Module | Target MHz | WNS | TNS | WHS | THS | Fmax est MHz | LUT | FF | DSP | BRAM18K |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Unified_PE | 250.000 | 0.564 | 0.000 | 0.261 | 0.000 | 291.036 | 86 | 16 | 1 | 0 |
| Linear_Layer | 149.993 | 3.221 | 0.000 | 0.053 | 0.000 | 290.192 | 312 | 22 | 0 | 0 |
| Conv1D_Layer | 149.993 | 3.166 | 0.000 | 0.054 | 0.000 | 285.633 | 2963 | 1297 | 16 | 0 |
| Scan_Core_Engine | 149.993 | -0.093 | -0.833 | 0.032 | 0.000 | 147.929 | 2729 | 1078 | 20 | 0 |
| Mamba_Top | 125.000 | -6.351 | -1678.542 | 0.018 | 0.000 | 69.682 | 8076 | 2688 | 53 | 0 |

Note: rough baseline for later before/after comparison; not signoff accuracy.
