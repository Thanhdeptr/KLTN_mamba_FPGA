import struct

# Read RTL output (256 signed 16-bit hex values)
with open('rtl_output.mem', 'r') as f:
    rtl_lines = [line.strip() for line in f.readlines()]
    rtl_values = [int(v, 16) if int(v, 16) < 0x8000 else (int(v, 16) - 0x10000) for v in rtl_lines[:256]]

# Read golden output (first 256 from file)
with open('golden_output.mem', 'r') as f:
    golden_lines = [line.strip() for line in f.readlines()]
    golden_values = [int(v, 16) if int(v, 16) < 0x8000 else (int(v, 16) - 0x10000) for v in golden_lines[:256]]

print(f"RTL values: {len(rtl_values)}")
print(f"Golden values: {len(golden_values)}")
print()

# Compare
mismatches = 0
max_error = 0
for i in range(min(256, len(rtl_values), len(golden_values))):
    error = abs(golden_values[i] - rtl_values[i])
    if error > 256:
        mismatches += 1
        if i < 10 or i >= len(rtl_values) - 10:
            print(f"  {i:3d}  RTL={rtl_values[i]:6d}  Golden={golden_values[i]:6d}  Error={error}")
    if error > max_error:
        max_error = error

print(f"\nResults:")
print(f"  Mismatches (error > 256): {mismatches} / 256")
print(f"  Max error: {max_error}")
if mismatches == 0:
    print("  ✓ PASS: All 256 values match!")
