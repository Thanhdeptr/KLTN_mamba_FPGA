import re
from pathlib import Path

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt


def hex_to_q87(s: str) -> float:
    v = int(s, 16)
    if v >= 0x8000:
        v -= 0x10000
    return v / 128.0  # Q8.7


def main():
    rtl_path = Path("py_software/silu_ouput_rtl.txt")
    ref_path = Path("ITMN/silu_golden/silu1_y_output_conv_branch_q87.mem")

    with rtl_path.open() as f:
        rtl_lines = [ln.strip() for ln in f if ln.strip()]

    with ref_path.open() as f:
        ref_lines = [ln.strip() for ln in f if ln.strip()]

    # Bỏ header không phải hex ở RTL (ví dụ 'xxxx')
    hex_re = re.compile(r"^[0-9a-fA-F]{1,4}$")
    if not hex_re.match(rtl_lines[0]):
        rtl_lines = rtl_lines[1:]

    n = min(len(rtl_lines), len(ref_lines))
    rtl_lines = rtl_lines[:n]
    ref_lines = ref_lines[:n]
    print(f"Using N = {n} samples")

    rtl = np.array([hex_to_q87(s) for s in rtl_lines], dtype=np.float64)
    ref = np.array([hex_to_q87(s) for s in ref_lines], dtype=np.float64)

    out_dir = Path("py_software")
    out_dir.mkdir(parents=True, exist_ok=True)

    # Vẽ 2 đường y_golden và y_RTL
    idx = np.arange(n)
    plt.figure(figsize=(10, 4))
    plt.plot(idx, ref, label="golden (Python)", linewidth=0.8)
    plt.plot(idx, rtl, label="RTL (silu.v)", linewidth=0.8, alpha=0.7)
    plt.xlabel("Sample index")
    plt.ylabel("y (Q8.7 -> float)")
    plt.title("SiLU output: RTL vs golden (full sequence)")
    plt.grid(True, alpha=0.3)
    plt.legend()
    plt.tight_layout()
    curve_path = out_dir / "silu_y_ref_vs_rtl.png"
    plt.savefig(curve_path, dpi=150)
    plt.close()

    print("Saved plot:", curve_path)


if __name__ == "__main__":
    main()