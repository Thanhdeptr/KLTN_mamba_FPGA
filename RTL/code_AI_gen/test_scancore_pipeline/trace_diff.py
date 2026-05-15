#!/usr/bin/env python3
import re
import sys

def extract_lines(path):
    patterns = [
        r"INSTR_S_STEP2W: exp_in_reg\[0\]=(?P<val>[0-9a-fA-F]+)",
        r"PE_DBG S_STEP2W .* pe_result_vec=(?P<val>[0-9a-fA-F]+)",
        r"PE_DBG S_STEP3W .* pe_result_vec=(?P<val>[0-9a-fA-F]+)",
        r"INSTR_S_STEP5: (?P<val>.*)",
        r"PE_DBG S_STEP5W .* pe_result_vec=(?P<val>[0-9a-fA-F]+)",
        r"INSTR_DUMP: pe_result_vec=(?P<val>[0-9a-fA-F]+)",
        r"INSTR_PE\[(?P<idx>\d+)\]: (?P<rest>.*)"
    ]
    data = { 'INSTR_S_STEP2W': [], 'PE_S2W': [], 'PE_S3W': [], 'INSTR_S_STEP5': [], 'PE_S5W': [], 'INSTR_DUMP': [], 'INSTR_PE': [] }
    with open(path, 'r', errors='ignore') as f:
        for ln in f:
            s = ln.strip()
            m = re.search(patterns[0], s)
            if m:
                data['INSTR_S_STEP2W'].append(m.group('val'))
            m = re.search(patterns[1], s)
            if m:
                data['PE_S2W'].append(m.group('val'))
            m = re.search(patterns[2], s)
            if m:
                data['PE_S3W'].append(m.group('val'))
            m = re.search(patterns[3], s)
            if m:
                data['INSTR_S_STEP5'].append(m.group('val'))
            m = re.search(patterns[4], s)
            if m:
                data['PE_S5W'].append(m.group('val'))
            m = re.search(patterns[5], s)
            if m:
                data['INSTR_DUMP'].append(m.group('val'))
            m = re.search(patterns[6], s)
            if m:
                data['INSTR_PE'].append((int(m.group('idx')), m.group('rest')))
    return data

def first_mismatch(a, b):
    for k in ['INSTR_S_STEP2W','PE_S2W','PE_S3W','INSTR_S_STEP5','PE_S5W','INSTR_DUMP']:
        la = a.get(k, [])
        lb = b.get(k, [])
        n = min(len(la), len(lb))
        for i in range(n):
            if la[i].lower() != lb[i].lower():
                print(f"Mismatch in {k} at index {i}: baseline={la[i]} pipe={lb[i]}")
                return True
    # Check per-PE entries
    pa = a.get('INSTR_PE', [])
    pb = b.get('INSTR_PE', [])
    n = min(len(pa), len(pb))
    for i in range(n):
        if pa[i][1] != pb[i][1] or pa[i][0] != pb[i][0]:
            print(f"Mismatch in INSTR_PE at entry {i}: baseline={pa[i]} pipe={pb[i]}")
            return True
    print('No mismatches found in captured labels (or unequal lengths).')
    return False

def main():
    if len(sys.argv) != 3:
        print('Usage: trace_diff.py baseline.log pipeline.log')
        sys.exit(2)
    a = extract_lines(sys.argv[1])
    b = extract_lines(sys.argv[2])
    first_mismatch(a,b)

if __name__ == '__main__':
    main()
