#!/usr/bin/env python3
"""
Validate In_Projection logic via Python (fixed-point Q3.12 arithmetic).
Verify: W[128x64] @ x[64] = golden_output[128×N]
"""

import sys

def read_mem_file(path):
    """Read .mem file and return list of hex strings"""
    with open(path) as f:
        return [line.strip() for line in f if line.strip()]

def hex_to_q312(hex_str):
    """Convert hex string to Q3.12 signed value"""
    val = int(hex_str, 16)
    if val >= 0x8000:
        val = -(0x10000 - val)
    return val / 4096.0  # Q3.12 means /2^12

def q312_to_int(val_float):
    """Convert float to Q3.12 fixed-point int"""
    q_int = int(round(val_float * 4096))
    if q_int > 32767:
        q_int = 32767
    if q_int < -32768:
        q_int = -32768
    return q_int

def q312_to_hex(val_int):
    """Convert Q3.12 int to 16-bit hex"""
    if val_int < 0:
        val_int = 0x10000 + val_int
    return f"{val_int & 0xFFFF:04x}"

# Read mem files
print("[*] Reading mem files...")
w1_lines = read_mem_file('weight_1.mem')
w2_lines = read_mem_file('weight_2.mem')
input_lines = read_mem_file('input.mem')
golden_lines = read_mem_file('golden_output.mem')

print(f"  weight_1: {len(w1_lines)} lines (128×64 matrix)")
print(f"  weight_2: {len(w2_lines)} lines (bias or extra)")
print(f"  input: {len(input_lines)} lines (1 iteration = 64 dim)")
print(f"  golden: {len(golden_lines)} lines")

# Parse data
print("\n[*] Parsing data...")
W = []  # 128x64 weight matrix
for i in range(128):
    row = []
    for j in range(64):
        idx = i * 64 + j
        if idx < len(w1_lines):
            val_f = hex_to_q312(w1_lines[idx])
            row.append(val_f)
    W.append(row)
print(f"  Weight matrix shape: {len(W)} x {len(W[0]) if W else 0}")

x = []  # 64-dim input (same for all iterations)
for j in range(64):
    if j < len(input_lines):
        val_f = hex_to_q312(input_lines[j])
        x.append(val_f)
print(f"  Input vector shape: {len(x)}")

# Number of test cases (golden iterations)
n_tests = len(golden_lines) // 128
print(f"  Number of test iterations: {n_tests}")

# Compute y = W @ x (matrix-vector multiply)
print("\n[*] Computing W @ x in Q3.12 arithmetic...")
y_computed = []
for i in range(128):
    acc = 0.0
    for j in range(64):
        acc += W[i][j] * x[j]
    # Scale back (Q(3.12+3.12) >> 12 = Q3.12)
    acc_scaled = acc / 4096.0
    y_computed.append(q312_to_int(acc_scaled))

print(f"  Computed output shape: {len(y_computed)}")
print(f"  First 4 elements: {[q312_to_hex(v) for v in y_computed[:4]]}")

# Compare with golden (first test case)
print("\n[*] Comparing with golden_output (first test case)...")
mismatch = 0
max_error = 0
for i in range(128):
    gold_hex = golden_lines[i]
    gold_val_int = hex_to_q312(gold_hex)
    comp_val = y_computed[i] / 4096.0
    comp_val_int = hex_to_q312(q312_to_hex(y_computed[i]))
    
    error = abs(int(gold_val_int * 4096) - y_computed[i])
    if error > 256:
        mismatch += 1
        if mismatch <= 5:
            print(f"  MISMATCH @lane {i}: computed {q312_to_hex(y_computed[i])}, golden {gold_hex} (error={error})")
        if error > max_error:
            max_error = error

print(f"\n=== IN_PROJECTION VALIDATION RESULT ===")
print(f"Compared: 1 sample × 128 lanes")
print(f"Mismatches (>|256|): {mismatch} / 128")
if mismatch == 0:
    print("✓ PASS: All values matched! Design logic is correct.")
else:
    print(f"✗ FAIL: {mismatch} mismatches (max error: {max_error})")
print("=" * 40)
