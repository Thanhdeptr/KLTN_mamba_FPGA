"""
Convert all .bin golden files in ITMN/golden_vectors/ to 16-bit Q3.12 .mem
files under ITMN/golden_vectors/rtl_mem/, for easier RTL testing.

Run from project root:
    python3 py_software/gen_rtl_mem_from_bin.py
"""

import numpy as np
from pathlib import Path

FRAC_BITS = 12  # Q3.12
SCALE = 1 << FRAC_BITS


def float32_bin_to_q312_mem(bin_path: Path, out_dir: Path) -> Path:
    """Read float32 .bin, quantize to Q3.12, write one 16-bit hex word per line."""
    arr = np.fromfile(bin_path, dtype=np.float32)
    if arr.size == 0:
        raise ValueError(f"{bin_path} is empty or not a valid float32 bin")

    q = np.round(arr * SCALE).astype(np.int32)
    q = np.clip(q, -32768, 32767).astype(np.int16)

    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / (bin_path.stem + "_q312.mem")

    with out_path.open("w") as f:
        for v in q:
            u16 = np.uint16(v)
            f.write(f"{u16:04x}\n")

    print(f"[INFO] {bin_path.name}: {arr.shape} -> {q.size} samples -> {out_path}")
    return out_path


def main():
    gv_dir = Path("ITMN/golden_vectors")
    out_dir = gv_dir / "rtl_mem"

    bin_files = sorted(gv_dir.glob("*.bin"))
    if not bin_files:
        print(f"[WARN] No .bin files found in {gv_dir}")
        return

    print(f"[INFO] Found {len(bin_files)} .bin files in {gv_dir}")

    for bin_path in bin_files:
        try:
            float32_bin_to_q312_mem(bin_path, out_dir)
        except Exception as e:
            print(f"[ERROR] Failed to convert {bin_path}: {e}")


if __name__ == "__main__":
    main()

