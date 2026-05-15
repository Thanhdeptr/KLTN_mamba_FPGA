#!/usr/bin/env python3
"""
Verify hypothesis: if we exclude taps 0-1 from accumulation in Python,
does output match RTL's -68?
"""

import numpy as np

# Load data from group 0
weight_lane_0_line_0 = "fddf010bfe0d01b4ff7afd99fedf009f"
input_bytes = ["e734", "f43f", "00fa", "1323", "2557", "f75c", "1905", "f27f"]

# Parse weights (128-bit, 8 taps * 16-bit each, Tap0 at LSB)
wval = int(weight_lane_0_line_0, 16)
weights = []
for tap in range(8):
    w = (wval >> (tap * 16)) & 0xFFFF
    if w & 0x8000:
        w = -(65536 - w)
    weights.append(w)

# Parse inputs
inputs = []
for inp_hex in input_bytes:
    i = int(inp_hex, 16)
    if i & 0x8000:
        i = -(65536 - i)
    inputs.append(i)

print("=== Hypothesis Test: Missing Taps 0-1 ===\n")
print("Lane 0 weights (taps 0-7):", weights)
print("Lane 0 inputs (taps 0-7): ", inputs)

print("\n1. Sum ALL 8 taps (expected correct):")
products = [w * i for w, i in zip(weights, inputs)]
print(f"   Products: {products}")
total_all = sum(products)
print(f"   Total:    {total_all}")

print("\n2. Sum ONLY taps 2-7 (hypothesis: RTL is missing taps 0-1):")
products_no_01 = products[2:]
print(f"   Products: {products_no_01}")
total_no_01 = sum(products_no_01)
print(f"   Total:    {total_no_01}")

print("\n3. Compare to RTL output -68:")
print(f"   RTL output: -68")
print(f"   Match with taps 2-7 only? {total_no_01 == -68}")

print("\n4. Try other combinations:")
for skip_start in range(0, 8):
    for skip_end in range(skip_start, 8):
        remaining = products[:skip_start] + products[skip_end+1:]
        s = sum(remaining)
        if s == -68:
            print(f"   ✓ Skip taps {skip_start}-{skip_end}: sum = {s}")

print("\n=== Possible Root Causes ===")
print("If no match found, then missing taps is NOT the issue.")
print("Could be: rounding, saturation, quantization, or group/lane indexing.")
