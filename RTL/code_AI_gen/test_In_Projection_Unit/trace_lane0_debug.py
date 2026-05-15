#!/usr/bin/env python3
import struct

# Read the testbench capture log (raw simulation output)
# to extract lane 0 values at each output capture

with open('rtl_output.mem') as f:
    rtl_output = [line.strip() for line in f.readlines()]

with open('golden_output.mem') as f:
    golden_all = [line.strip() for line in f.readlines()]

# Parse as signed 16-bit
def h2s(h):
    v = int(h, 16)
    return v if v < 0x8000 else v - 0x10000

rtl_vec0_lane0 = h2s(rtl_output[0])
rtl_vec1_lane0 = h2s(rtl_output[16])
rtl_vec2_lane0 = h2s(rtl_output[32])

golden_vec0_lane0 = h2s(golden_all[0])
golden_vec1_lane0 = h2s(golden_all[16])
golden_vec2_lane0 = h2s(golden_all[32])

print("Lane 0 outputs (16 lanes per vector):")
print(f"RTL   vec0={rtl_vec0_lane0:6d}  vec1={rtl_vec1_lane0:6d}  vec2={rtl_vec2_lane0:6d}")
print(f"Golden vec0={golden_vec0_lane0:6d}  vec1={golden_vec1_lane0:6d}  vec2={golden_vec2_lane0:6d}")

# The zero in vec0 is expected (cold-start). But vec1 should match.
print(f"\nVec1 comparison (first real output):")
print(f"  Error: {abs(golden_vec1_lane0 - rtl_vec1_lane0)}")
if abs(golden_vec1_lane0 - rtl_vec1_lane0) < 100:
    print("  ✓ Close match (rounding error acceptable)")
else:
    print("  ✗ Large mismatch—computation is wrong")
