import numpy as np
import argparse
import os
from pathlib import Path

SCALE = 128  # Q8.7


def float_txt_to_q87_mem(txt_path: str, mem_path: str):
    """
    Đọc file .txt (float, mỗi dòng 1 hoặc nhiều số),
    flatten toàn bộ, quantize sang Q8.7 16-bit signed,
    rồi ghi ra .mem (mỗi dòng 1 word hex 4 ký tự).
    """
    txt_path = Path(txt_path)
    mem_path = Path(mem_path)
    mem_path.parent.mkdir(parents=True, exist_ok=True)

    # Đọc toàn bộ số thực
    data = np.loadtxt(txt_path, dtype=np.float64)
    flat = data.reshape(-1)  # flatten

    # Quantize sang Q8.7
    q = np.round(flat * SCALE).astype(np.int32)
    # Clamp vào [-32768, 32767]
    q = np.clip(q, -32768, 32767)

    # Ghi ra file .mem dưới dạng 16-bit signed, hex
    with mem_path.open("w") as f:
        for v in q:
            v16 = np.int16(v)          # 16-bit signed
            u16 = np.uint16(v16)      # view as unsigned để in hex
            f.write(f"{u16:04x}\n")

    print(f"{txt_path.name}: shape {data.shape} -> {q.shape[0]} samples -> {mem_path}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--in_txt",
        type=str,
        default="ITMN/silu_golden/silu1_x_input_conv_branch.txt",
        help="Đường dẫn file txt input float",
    )
    parser.add_argument(
        "--out_mem",
        type=str,
        default="ITMN/silu_golden/silu1_x_input_conv_branch_q87.mem",
        help="Đường dẫn file .mem output",
    )
    args = parser.parse_args()

    float_txt_to_q87_mem(args.in_txt, args.out_mem)


if __name__ == "__main__":
    main()
