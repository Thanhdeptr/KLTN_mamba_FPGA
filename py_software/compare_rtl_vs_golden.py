#!/usr/bin/env python3
import re
import sys
from pathlib import Path

def read_golden(path, n=256):
    lines = Path(path).read_text().splitlines()
    vals = []
    for i,l in enumerate(lines):
        if len(vals) >= n: break
        s = l.strip()
        if not s: continue
        # accept hex like 0x..., or plain hex
        if s.lower().startswith('0x'):
            s = s[2:]
        vals.append(int(s,16) if all(c in '0123456789abcdefABCDEF' for c in s) else int(s))
    return vals

def parse_rtl_output(path):
    txt = Path(path).read_text()
    # find y=hex groups
    ys = re.findall(r"y=([0-9a-fA-F]+)", txt)
    vals = []
    for y in ys:
        # split into 4-hex groups (16-bit) from left
        if len(y) % 4 != 0:
            # pad left
            y = y.rjust(((len(y)+3)//4)*4, '0')
        groups = [y[i:i+4] for i in range(0,len(y),4)]
        # groups are MSB first (lane15..lane0). reverse to get lane0..lane15
        groups = list(reversed(groups))
        for g in groups:
            v = int(g,16)
            if v & 0x8000:
                v = v - 0x10000
            vals.append(v)
    return vals

def main():
    if len(sys.argv) < 3:
        print("Usage: compare_rtl_vs_golden.py <rtl_output.mem> <golden_output.mem> [count]")
        return 1
    rtl = sys.argv[1]
    gold = sys.argv[2]
    count = int(sys.argv[3]) if len(sys.argv)>3 else 256

    if not Path(rtl).exists():
        print("rtl output not found:", rtl); return 2
    if not Path(gold).exists():
        print("golden not found:", gold); return 2

    g = read_golden(gold, n=count)
    r = parse_rtl_output(rtl)

    # compare first count values
    mism = []
    for i in range(min(count, len(g), len(r))):
        if g[i] != r[i]:
            mism.append((i, g[i], r[i]))
            if len(mism) >= 20: break

    print(f"gold_count={len(g)} rtl_extracted={len(r)} compare_count={min(count,len(g),len(r))}")
    if not mism and len(g) >= count and len(r) >= count:
        print("OK: first", count, "values match")
        return 0
    else:
        print("Mismatches:")
        for i,gv,rv in mism:
            print(f" idx={i} gold=0x{(gv & 0xFFFF):04x} rtl=0x{(rv & 0xFFFF):04x} ({gv} vs {rv})")
        if len(g) < count:
            print("Golden has fewer than requested count")
        if len(r) < count:
            print("RTL extracted fewer than requested count")
        return 3

if __name__ == '__main__':
    raise SystemExit(main())
