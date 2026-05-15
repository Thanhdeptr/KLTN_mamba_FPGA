#!/usr/bin/env python3

import sys
import struct

# Load and verify tap 0 behavior
print("=== Analyzing Tap 0 Issue ===\n")

# 1. Load first weight bank to see if tap 0 is all zeros
print("1. Check weight_lane_0.mem:")
try:
    with open("banks/weight_lane_0.mem", "r") as f:
        lines = f.readlines()
        first_line = lines[0].strip()  # Address 0 = group 0, ticks 0-7
        print(f"   Line 0 (group 0, all taps): {first_line}")
        
        # Parse as 128-bit (8 taps * 16 bits)
        val = int(first_line, 16)
        print(f"   Parsed as {128}-bit: 0x{val:032x}")
        
        # Extract each tap (16 bits per tap, Tap0 at LSB)
        for tap in range(8):
            tap_mask = (1 << 16) - 1
            tap_val = (val >> (tap * 16)) & tap_mask
            # Sign extend
            if tap_val & 0x8000:
                tap_val = -(65536 - tap_val)
            print(f"      Tap {tap}: 0x{(val >> (tap * 16)) & 0xFFFF:04x} = {tap_val:6d}")
except FileNotFoundError as e:
    print(f"   ERROR: {e}")

# 2. Load first input vector
print("\n2. Check input.mem:")
try:
    with open("input.mem", "r") as f:
        inputs = []
        for line in f:
            inputs.append(int(line.strip(), 16))
        
        print(f"   First 8 inputs (taps 0-7 for group 0, type X):")
        for i, val in enumerate(inputs[:8]):
            # Sign extend
            if val & 0x8000:
                sval = -(65536 - val)
            else:
                sval = val
            print(f"      Input {i}: 0x{val:04x} = {sval:6d}")
except FileNotFoundError as e:
    print(f"   ERROR: {e}")

# 3. Check if multiple banks have tap 0 = 0
print("\n3. Check tap 0 across all banks (group 0):")
all_zero = True
for lane in range(16):
    try:
        with open(f"banks/weight_lane_{lane}.mem", "r") as f:
            first_line = f.readline().strip()
            val =int(first_line, 16)
            tap0_val = val & 0xFFFF
            if tap0_val & 0x8000:
                tap0_signed = -(65536 - tap0_val)
            else:
                tap0_signed = tap0_val
            print(f"   Lane {lane:2d}: tap0 = 0x{tap0_val:04x} ({tap0_signed:6d})")
            if tap0_val != 0:
                all_zero = False
    except Exception as e:
        print(f"   Lane {lane}: ERROR - {e}")

if all_zero:
    print("\n⚠️  OBSERVATION: Tap 0 is 0 across all lanes for group 0!")
    print("    This means the first tap contribution is multiplied by 0.")
    print("    Q: Is this weight intentional, or is testbench not initializing?")
else:
    print("\n✓ Tap 0 has non-zero weights in at least one lane.")

print("\n=== End Analysis ===")
