#!/usr/bin/env python3
"""
Verify generated bank .mem files match original weight binary.

Usage:
  python3 py_software/check_inproj_banks.py --banks DIR --orig FULL.bin
  OR
  python3 py_software/check_inproj_banks.py --banks DIR --in1 IN1.bin --in2 IN2.bin

The script reconstructs the 256x64 matrix from 16 bank files and compares
to the provided original weights.
"""

import argparse
from pathlib import Path
import struct
import sys


def read_int16_le(path):
    data = Path(path).read_bytes()
    if len(data) % 2 != 0:
        raise ValueError(f"File {path} length not multiple of 2")
    return list(struct.unpack('<' + 'h' * (len(data) // 2), data))


def parse_line_to_cluster(line):
    s = line.strip()
    # expect hex string length 32 chars (8 * 4)
    if len(s) < 32:
        # pad or error
        s = s.zfill(32)
    parts = [s[i:i+4] for i in range(0, len(s), 4)]
    if len(parts) != 8:
        raise ValueError(f"Line has {len(parts)} parts, expected 8: '{s}'")
    # parts are MSB->LSB (cluster[7] .. cluster[0]) based on packing convention
    vals = []
    for p in parts:
        v = int(p, 16)
        # convert to signed 16-bit
        if v & 0x8000:
            v = v - 0x10000
        vals.append(v)
    # reverse to get cluster[0..7]
    return list(reversed(vals))


def reconstruct_rows_from_banks(banks_dir: Path):
    # returns rows: list of 256 lists of 64 ints
    rows = [None] * 256
    for lane in range(16):
        path = banks_dir / f"weight_lane_{lane}.mem"
        if not path.exists():
            raise FileNotFoundError(f"Missing {path}")
        lines = [l.strip() for l in path.read_text().splitlines() if l.strip()]
        if len(lines) != 128:
            raise ValueError(f"Expected 128 lines in {path}, got {len(lines)}")
        for group in range(16):
            row_idx = group * 16 + lane
            row = []
            base = group * 8
            for tick in range(8):
                line = lines[base + tick]
                cluster = parse_line_to_cluster(line)
                row.extend(cluster)
            if len(row) != 64:
                raise ValueError(f"Reconstructed row {row_idx} length {len(row)} != 64")
            rows[row_idx] = row
    # sanity
    if any(r is None for r in rows):
        raise ValueError("Some rows were not reconstructed")
    return rows


def compare_rows(rows, orig_vals):
    # orig_vals can be flat list of length 256*64 or two 128*64 lists
    flat = []
    if len(orig_vals) == 256 * 64:
        flat = orig_vals
    elif len(orig_vals) == 128 * 64 * 2:
        flat = orig_vals
    else:
        raise ValueError(f"Original values length {len(orig_vals)} unexpected")
    # compare
    mismatches = []
    for r in range(256):
        for c in range(64):
            expected = flat[r * 64 + c]
            got = rows[r][c]
            if expected != got:
                mismatches.append((r, c, expected, got))
                if len(mismatches) >= 10:
                    return mismatches
    return mismatches


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--banks', required=True, help='directory with weight_lane_*.mem')
    p.add_argument('--orig', help='original full 256x64 binary (int16 LE)')
    p.add_argument('--in1', help='in_proj1 128x64 bin')
    p.add_argument('--in2', help='in_proj2 128x64 bin')
    args = p.parse_args()

    banks_dir = Path(args.banks)
    if not banks_dir.exists():
        print(f"Banks dir {banks_dir} does not exist")
        sys.exit(1)

    rows = reconstruct_rows_from_banks(banks_dir)
    print("Reconstructed 256 rows from banks")

    orig_vals = None
    if args.orig:
        orig_vals = read_int16_le(args.orig)
    elif args.in1 and args.in2:
        a = read_int16_le(args.in1)
        b = read_int16_le(args.in2)
        orig_vals = a + b
    else:
        print("Provide --orig or both --in1 and --in2 to compare")
        sys.exit(1)

    mism = compare_rows(rows, orig_vals)
    if not mism:
        print("OK: bank files match original weights exactly")
    else:
        print(f"Found {len(mism)} mismatches (showing up to 10):")
        for r, c, exp, got in mism:
            print(f" row {r} col {c}: expected {exp} got {got}")
        sys.exit(2)


if __name__ == '__main__':
    main()
