#!/usr/bin/env python3
import argparse
import sys
from pathlib import Path

def read_mem(path):
    lines = []
    with open(path, 'r') as f:
        for l in f:
            s = l.strip()
            if not s:
                continue
            # strip optional 0x and ensure even-length
            if s.startswith('0x') or s.startswith('0X'):
                s = s[2:]
            s = s.replace('_','')
            lines.append(s)
    return lines

def hex_to_signed_16(h):
    v = int(h, 16)
    if v & 0x8000:
        v = v - 0x10000
    return v

def main():
    p = argparse.ArgumentParser(description='Compare RTL output mem with golden mem')
    p.add_argument('--rtl', default='rtl_output.mem', help='RTL output mem file')
    p.add_argument('--golden', default='golden_output.mem', help='Golden mem file')
    p.add_argument('--max-show', type=int, default=20, help='Max mismatches to show')
    args = p.parse_args()

    rtl_path = Path(args.rtl)
    gold_path = Path(args.golden)
    if not rtl_path.exists():
        print(f'ERROR: RTL file not found: {rtl_path}', file=sys.stderr)
        sys.exit(2)
    if not gold_path.exists():
        print(f'ERROR: Golden file not found: {gold_path}', file=sys.stderr)
        sys.exit(2)

    rtl = read_mem(rtl_path)
    gold = read_mem(gold_path)

    n_rtl = len(rtl)
    n_gold = len(gold)
    n = min(n_rtl, n_gold)

    mismatches = []
    for i in range(n):
        try:
            r = hex_to_signed_16(rtl[i])
        except Exception:
            r = rtl[i]
        try:
            g = hex_to_signed_16(gold[i])
        except Exception:
            g = gold[i]
        if r != g:
            mismatches.append((i, rtl[i], gold[i], r, g))

    print('Comparison report:')
    print(f'  RTL lines:    {n_rtl}')
    print(f'  Golden lines: {n_gold}')
    print(f'  Compared:     {n}')
    print(f'  Mismatches:   {len(mismatches)}')

    if mismatches:
        print('\nFirst mismatches (index, rtl_hex, golden_hex, rtl_signed, golden_signed):')
        for idx, rtl_h, gold_h, rtl_v, gold_v in mismatches[:args.max_show]:
            print(f'  {idx:6d}  {rtl_h:>6}  {gold_h:>6}    {rtl_v:6d}    {gold_v:6d}')
        out_report = 'compare_report.txt'
        with open(out_report, 'w') as f:
            f.write(f'RTL: {rtl_path}\nGolden: {gold_path}\n')
            f.write(f'RTL lines: {n_rtl}\nGolden lines: {n_gold}\nCompared: {n}\nMismatches: {len(mismatches)}\n')
            f.write('\n')
            for idx, rtl_h, gold_h, rtl_v, gold_v in mismatches:
                f.write(f'{idx},{rtl_h},{gold_h},{rtl_v},{gold_v}\n')
        print(f'\nWrote full mismatch report to {out_report}')
        sys.exit(1)
    else:
        print('OK: RTL output matches golden exactly')
        sys.exit(0)

if __name__ == "__main__":
    main()
