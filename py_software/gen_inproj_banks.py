#!/usr/bin/env python3
"""
Generate 16 bank .mem files from in_proj1 and in_proj2 weight bins.

Usage:
  python3 py_software/gen_inproj_banks.py --in1 IN1.bin --in2 IN2.bin --out OUT_DIR

Assumptions:
  - IN1 and IN2 are int16 little-endian flat arrays of shape (128,64) each.
  - We concatenate IN1 (rows 0..127) then IN2 (rows 128..255) -> total 256 rows x 64 cols.
  - Output: 16 files weight_lane_0.mem .. weight_lane_15.mem, each with 128 lines.
  - Each line is 128-bit hex (8 x 16-bit words) written MSB->LSB such that Tap0 is LSB.
"""

import argparse
from pathlib import Path
import struct
import sys


def read_int16_le(path):
    data = Path(path).read_bytes()
    # interpret as little-endian signed 16-bit
    if len(data) % 2 != 0:
        raise ValueError(f"File {path} length not multiple of 2")
    vals = list(struct.unpack('<' + 'h' * (len(data) // 2), data))
    return vals


def ensure_dir(p: Path):
    p.mkdir(parents=True, exist_ok=True)


def pack_cluster_to_hex(cluster):
    # cluster: list of 8 signed ints (16-bit). We need to write MSB->LSB
    # with Tap0 in LSB (bits [15:0]) and Tap7 in MSB (bits [127:112]).
    # So output string should place cluster[7] first, cluster[0] last.
    parts = []
    for val in reversed(cluster):
        parts.append(f"{(val & 0xFFFF):04x}")
    return "".join(parts)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--in1', required=True, help='in_proj1_weight.bin (128x64 int16 LE)')
    p.add_argument('--in2', required=True, help='in_proj2_weight.bin (128x64 int16 LE)')
    p.add_argument('--out', required=True, help='output directory for bank files')
    args = p.parse_args()

    in1 = read_int16_le(args.in1)
    in2 = read_int16_le(args.in2)

    # Possible shapes:
    # - in1: 8192 (128x64) and in2: 8192 -> concat to 256x64
    # - in1: 16384 (256x64) and in2 present -> use in1 (assume already full)
    # - other cases: error
    if len(in1) == 128 * 64 and len(in2) == 128 * 64:
        rows1 = [in1[i * 64:(i + 1) * 64] for i in range(len(in1) // 64)]
        rows2 = [in2[i * 64:(i + 1) * 64] for i in range(len(in2) // 64)]
        rows = rows1 + rows2
    elif len(in1) == 256 * 64:
        print(f"Info: {args.in1} appears to be 256x64, using it as full weight matrix and ignoring {args.in2}")
        rows = [in1[i * 64:(i + 1) * 64] for i in range(len(in1) // 64)]
    else:
        print(f"Error: unexpected input sizes: {args.in1}={len(in1)}, {args.in2}={len(in2)}")
        sys.exit(1)

    total_rows = len(rows)
    if total_rows != 256:
        print(f"Error: total rows = {total_rows}, expected 256")
        sys.exit(1)

    out_dir = Path(args.out)
    ensure_dir(out_dir)

    # For lane in 0..15 (physical bank file)
    # For group in 0..15:
    #   row_idx = group * 16 + lane
    #   row_data = rows[row_idx]  # 64 elements
    #   for tick in 0..7:
    #       cluster = row_data[tick*8:(tick+1)*8]
    #       pack cluster to 128-bit hex and write one line

    for lane in range(16):
        out_path = out_dir / f"weight_lane_{lane}.mem"
        with out_path.open('w') as f:
            for group in range(16):
                row_idx = group * 16 + lane
                row = rows[row_idx]
                if len(row) != 64:
                    raise ValueError(f"row {row_idx} length != 64")
                for tick in range(8):
                    cluster = row[tick * 8:(tick + 1) * 8]
                    if len(cluster) != 8:
                        raise ValueError("cluster length != 8")
                    wide_hex = pack_cluster_to_hex(cluster)
                    f.write(wide_hex + "\n")

    print(f"Wrote 16 bank files to {out_dir}")


if __name__ == '__main__':
    main()
