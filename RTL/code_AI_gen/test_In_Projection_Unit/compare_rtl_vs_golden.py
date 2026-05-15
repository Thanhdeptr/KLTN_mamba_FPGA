#!/usr/bin/env python3
"""
Compare RTL-generated output (rtl_output_pipeline.mem) vs golden output from Python model.
Accepts Q3.12 fixed-point 16-bit signed hex values.
Error threshold: 256 (quantization + rounding tolerance).
"""

import sys
import os

def read_hex_file(path):
    """Read .mem file (hex 16-bit values) and return list."""
    if not os.path.exists(path):
        print(f'Error: file not found: {path}')
        sys.exit(1)
    with open(path) as f:
        return [line.strip() for line in f if line.strip()]

def hex_to_signed_int(h):
    """Convert 16-bit hex string to signed integer."""
    try:
        v = int(h, 16)
        if v & 0x8000:
            v = v - 0x10000
        return v
    except ValueError:
        print(f'Error: invalid hex value: {h}')
        sys.exit(1)

def main():
    print("[Compare] Loading files...")
    rtl = read_hex_file('rtl_output.mem')
    gold = read_hex_file('golden_output.mem')

    print(f"  RTL output: {len(rtl)} values")
    print(f"  Golden:     {len(gold)} values")

    if len(rtl) < 256:
        print(f'Error: rtl_output.mem has only {len(rtl)} values, need 256')
        sys.exit(2)
    if len(gold) < 256:
        print(f'Error: golden_output.mem has only {len(gold)} values, need 256')
        sys.exit(2)

    print("\n[Compare] Comparing all 256 output values...")
    mismatch_count = 0
    max_error = 0
    error_histogram = {}
    
    for i in range(256):
        r = hex_to_signed_int(rtl[i])
        g = hex_to_signed_int(gold[i])
        err = abs(g - r)
        
        # Track error histogram
        err_bucket = (err // 50) * 50
        error_histogram[err_bucket] = error_histogram.get(err_bucket, 0) + 1
        
        if err > 256:
            mismatch_count += 1
            # Print first 10 mismatches
            if mismatch_count <= 10:
                print(f"  MISMATCH lane {i:3d}: RTL={rtl[i]} gold={gold[i]} "
                      f"(signed: rtl={r} gold={g}, err={err})")
        
        if err > max_error:
            max_error = err

    print(f"\n[Results]")
    print(f"  ✓ Lanes compared: 256")
    print(f"  ✓ Mismatches (error > 256): {mismatch_count} / 256")
    print(f"  ✓ Max error: {max_error}")
    
    if mismatch_count > 0:
        print(f"\n  Error distribution:")
        for bucket in sorted(error_histogram.keys()):
            count = error_histogram[bucket]
            bar = "█" * (count // 5 + 1) if count > 0 else ""
            print(f"    [{bucket:4d}-{bucket+49:4d}): {count:3d} {bar}")
    
    print(f"\n{'='*50}")
    if mismatch_count == 0:
        print(f"✓ PASS: All 256 output values match within tolerance!")
    else:
        print(f"✗ FAIL: {mismatch_count} values exceeded threshold")
    print(f"{'='*50}\n")
    
    return 0 if mismatch_count == 0 else 1

if __name__ == '__main__':
    sys.exit(main())
