#!/usr/bin/env python3
"""
Comprehensive validation that bank unpacking follows row-major combinational logic.

Steps:
1. Load input from input.mem
2. Load golden output from golden_output.mem
3. Load RTL output from rtl_output.mem
4. Reconstruct weight matrix from banks/weight_lane_*.mem
5. Compute dot-product using BANK-UNPACKED weights
6. Compare BANK-COMPUTED vs GOLDEN vs RTL
   - If BANK-COMPUTED ≈ GOLDEN, then banks are unpacked correctly (quy ước đúng)
   - Show per-row breakdown for multiple rows across different groups/lanes

Purpose:
   - Chứng minh rằng quy ước unpack bank là đúng (không sai)
   - Chứng minh rằng weight/x pairings khớp theo row-major combinational
   - Nếu BANK-COMPUTED ≠ RTL, thì lệch ở pipeline, không phải ở unpacking
"""

import sys
from pathlib import Path
import struct
import numpy as np

# Config
FRAC_BITS = 12
DATA_WIDTH = 16
SAT_MAX = 32767
SAT_MIN = -32768

def read_mem_file(path, dtype=np.int16):
    """Read .mem file containing hex values (one per line)"""
    path = Path(path)
    if not path.exists():
        raise FileNotFoundError(f"{path}")
    lines = path.read_text().strip().split('\n')
    vals = []
    for line in lines:
        line = line.strip()
        if not line or line.startswith('//'):
            continue
        v = int(line, 16)
        # Convert to signed
        if v & 0x8000:
            v = v - 0x10000
        vals.append(v)
    return np.array(vals, dtype=dtype)


def parse_bank_line_to_cluster(line_str):
    """
    Parse one line from weight_lane_*.mem.
    Line = 128-bit hex (8 x 16-bit words).
    Format: MSB->LSB, with cluster[7] at MSB and cluster[0] at LSB.
    """
    s = line_str.strip()
    if len(s) < 32:
        s = s.zfill(32)
    parts = [s[i:i+4] for i in range(0, 32, 4)]
    cluster = []
    for p in parts:
        v = int(p, 16)
        if v & 0x8000:
            v = v - 0x10000
        cluster.append(v)
    # Reverse because MSB->LSB in string, but we want cluster[0..7]
    return list(reversed(cluster))


def reconstruct_weight_from_banks(banks_dir):
    """
    Reconstruct 256x64 weight matrix from 16 bank files.
    Returns: numpy array (256, 64) int16
    """
    banks_dir = Path(banks_dir)
    rows = []
    for group in range(16):
        for lane in range(16):
            row_idx = group * 16 + lane
            lane_path = banks_dir / f"weight_lane_{lane}.mem"
            if not lane_path.exists():
                raise FileNotFoundError(f"{lane_path}")
            lines = lane_path.read_text().strip().split('\n')
            # For this (group, lane), read lines from group*8 to group*8+8
            row = []
            for tick in range(8):
                line_idx = group * 8 + tick
                if line_idx >= len(lines):
                    raise ValueError(f"Bank {lane} has {len(lines)} lines, need >= {line_idx+1}")
                cluster = parse_bank_line_to_cluster(lines[line_idx])
                row.extend(cluster)
            rows.append(np.array(row, dtype=np.int16))
    return np.array(rows, dtype=np.int16)  # (256, 64)


def dotproduct_row(weight_row, input_vec, frac_bits=FRAC_BITS):
    """
    Compute dot-product: sum(weight_row[j] * input_vec[j] for j in 0..63)
    Then scale back: result >> frac_bits
    Then saturate.
    """
    acc = np.int32(0)
    for j in range(64):
        w = np.int32(weight_row[j])
        x = np.int32(input_vec[j])
        acc += w * x
    scaled = acc >> frac_bits
    # Saturate
    if scaled > SAT_MAX:
        return np.int16(SAT_MAX)
    elif scaled < SAT_MIN:
        return np.int16(SAT_MIN)
    else:
        return np.int16(scaled)


def compute_outputs_from_banks(weight_matrix, input_vec):
    """
    Compute all 128 dot-products using weight matrix from banks.
    """
    outputs = []
    for gi in range(128):
        result = dotproduct_row(weight_matrix[gi], input_vec)
        outputs.append(result)
    return np.array(outputs, dtype=np.int16)


def detailed_row_trace(weight_row, input_vec, frac_bits=FRAC_BITS):
    """
    Return detailed breakdown of dot-product computation for a row.
    Returns: dict with products, running sums, final result
    """
    products = []
    acc = np.int32(0)
    for j in range(64):
        prod = np.int32(weight_row[j]) * np.int32(input_vec[j])
        products.append((j, weight_row[j], input_vec[j], prod))
        acc += prod
    
    scaled = acc >> frac_bits
    if scaled > SAT_MAX:
        saturated = np.int16(SAT_MAX)
    elif scaled < SAT_MIN:
        saturated = np.int16(SAT_MIN)
    else:
        saturated = np.int16(scaled)
    
    return {
        'products': products,
        'sum_before_scale': acc,
        'sum_after_scale': scaled,
        'saturated_output': saturated,
    }


def main():
    test_dir = Path(__file__).parent
    banks_dir = test_dir / 'banks'
    
    print("[==] COMPREHENSIVE BANK VALIDATION")
    print(f"[==] Test dir: {test_dir}")
    print(f"[==] Banks dir: {banks_dir}\n")
    
    # Load all data
    print("[1] Loading data...")
    try:
        input_vec = read_mem_file(test_dir / 'input.mem')  # (64,)
        golden_raw = read_mem_file(test_dir / 'golden_output.mem')  # (256000,) - first 128 are actual output from In_Projection_Unit_Pipelined
        golden_out = golden_raw[:128]  # Take first 128 (corresponding to 128 output lanes)
        # Try rtl_output_pipeline.mem first (128 lanes), fall back to rtl_output.mem (256)
        if (test_dir / 'rtl_output_pipeline.mem').exists():
            rtl_out = read_mem_file(test_dir / 'rtl_output_pipeline.mem')
            print(f"   Using rtl_output_pipeline.mem (128 lanes)")
        elif (test_dir / 'rtl_output.mem').exists():
            rtl_temp = read_mem_file(test_dir / 'rtl_output.mem')
            rtl_out = rtl_temp[:128]  # Take first 128
            print(f"   Using rtl_output.mem (truncated to 128 lanes)")
        else:
            raise FileNotFoundError("Neither rtl_output_pipeline.mem nor rtl_output.mem found")
        
        print(f"   Input shape: {input_vec.shape}")
        print(f"   Golden output shape (first 128 of {len(golden_raw)}): {golden_out.shape}")
        print(f"   RTL output shape: {rtl_out.shape}")
    except Exception as e:
        print(f"   ERROR loading .mem files: {e}")
        sys.exit(1)
    
    # Reconstruct weight from banks
    print("\n[2] Reconstructing weight matrix from banks...")
    try:
        weight_matrix = reconstruct_weight_from_banks(banks_dir)
        print(f"   Weight matrix shape: {weight_matrix.shape}")
        print(f"   Weight dtype: {weight_matrix.dtype}")
    except Exception as e:
        print(f"   ERROR: {e}")
        sys.exit(1)
    
    # Compute outputs using bank-unpacked weights
    print("\n[3] Computing outputs using BANK-UNPACKED weights...")
    bank_computed_out = compute_outputs_from_banks(weight_matrix, input_vec)
    print(f"   Bank-computed output shape: {bank_computed_out.shape}")
    
    # Compare: BANK-COMPUTED vs GOLDEN
    print("\n[4] Comparison: BANK-COMPUTED vs GOLDEN")
    bank_vs_golden_diff = bank_computed_out - golden_out
    bank_golden_mismatches = np.sum(bank_vs_golden_diff != 0)
    print(f"   Mismatches: {bank_golden_mismatches}/128")
    print(f"   Max error: {np.max(np.abs(bank_vs_golden_diff))}")
    print(f"   Mean error: {np.mean(np.abs(bank_vs_golden_diff)):.2f}")
    
    # Compare: BANK-COMPUTED vs RTL
    print("\n[5] Comparison: BANK-COMPUTED vs RTL")
    bank_vs_rtl_diff = bank_computed_out - rtl_out
    bank_rtl_mismatches = np.sum(bank_vs_rtl_diff != 0)
    print(f"   Mismatches: {bank_rtl_mismatches}/128")
    print(f"   Max error: {np.max(np.abs(bank_vs_rtl_diff))}")
    print(f"   Mean error: {np.mean(np.abs(bank_vs_rtl_diff)):.2f}")
    
    # Compare: GOLDEN vs RTL
    print("\n[6] Comparison: GOLDEN vs RTL")
    golden_vs_rtl_diff = golden_out - rtl_out
    golden_rtl_mismatches = np.sum(golden_vs_rtl_diff != 0)
    print(f"   Mismatches: {golden_rtl_mismatches}/128")
    
    # INTERPRETATION
    print("\n" + "="*70)
    print("[INTERPRETATION]")
    print("="*70)
    if bank_golden_mismatches == 0:
        print("✓ BANK-COMPUTED == GOLDEN (perfectly)")
        print("  → Banks are unpacked correctly (quy ước ĐÚNG)")
        print("  → Weight/input pairings match row-major combinational logic")
        print("  → Lệch hiện tại có nguồn gốc từ PIPELINE, không phải unpacking")
    elif bank_golden_mismatches <= 10:
        print(f"~ BANK-COMPUTED ≈ GOLDEN (only {bank_golden_mismatches} small mismatches)")
        print("  → Banks unpacking is mostly correct (minor rounding differences)")
        print("  → Problem likely NOT in bank unpacking")
    else:
        print(f"✗ BANK-COMPUTED ≠ GOLDEN ({bank_golden_mismatches} mismatches)")
        print("  → Banks may be unpacked with wrong convention")
        print("  → Need to re-examine packing/unpacking logic")
    
    print("\n" + "="*70)
    print("[DETAILED PER-ROW TRACE for representative samples]")
    print("="*70)
    
    # Show detailed trace for key rows across groups and lanes
    # Note: Only testing first 128 lanes (In_Projection_Unit_Pipelined)
    test_rows = [0, 1, 15, 16, 31, 32, 63, 64, 95, 96, 127]  # Cover various lanes within 0..127
    
    for gi in test_rows:
        trace = detailed_row_trace(weight_matrix[gi], input_vec)
        
        bank_comp_val = bank_computed_out[gi]
        golden_val = golden_out[gi]
        rtl_val = rtl_out[gi]
        
        group_idx = gi // 16
        lane_idx = gi % 16
        print(f"\n--- Output Lane {gi} (group={group_idx}, lane={lane_idx}) ---")
        print(f"  Bank-computed: {bank_comp_val:8d}   |   Golden: {golden_val:8d}   |   RTL: {rtl_val:8d}")
        print(f"  Bank vs Golden: {bank_comp_val - golden_val:+8d}   |   Bank vs RTL: {bank_comp_val - rtl_val:+8d}")
        
        # Show first few and last few products
        prods = trace['products']
        print(f"  Sum (before scale): {trace['sum_before_scale']}")
        print(f"  Sum (after scale >> {FRAC_BITS}): {trace['sum_after_scale']}")
        
        # Show sample products
        print(f"  First 5 products (tap index, weight, input, product):")
        for idx in range(min(5, len(prods))):
            j, w, x, p = prods[idx]
            print(f"    [tap {j:2d}]  w={w:8d}  x={x:8d}  prod={p:12d}")
        print(f"  ... ({len(prods)-10} more) ...")
        if len(prods) > 5:
            for idx in range(max(5, len(prods)-5), len(prods)):
                j, w, x, p = prods[idx]
                print(f"    [tap {j:2d}]  w={w:8d}  x={x:8d}  prod={p:12d}")
    
    print("\n" + "="*70)
    print("[CONCLUSION]")
    print("="*70)
    if bank_rtl_mismatches == 0:
        print("✓ BANK-COMPUTED == RTL PERFECTLY")
        print("✓ Quy ước UNPACKING BANK là ĐÚNG")
        print("✓ Weight/input pairings khớp 100% theo row-major combinational logic")
        print("✓ RTL pipeline hoạt động CHÍNH XÁC")
        print("\n→ LỆCH không phải do 'bóc 16 bank sai quy ước'")
        print("→ LỆCH có nguồn gốc: Golden reference provenance hoặc rounding đó")
    elif bank_rtl_mismatches <= 10:
        print(f"~ BANK-COMPUTED ≈ RTL (only {bank_rtl_mismatches} small mismatches)")
        print("  → Banks unpacking là mostly correct")
        print("  → Problem likely NOT in bank unpacking")
    else:
        print(f"✗ BANK-COMPUTED ≠ RTL ({bank_rtl_mismatches} mismatches)")
        print("  → Banks may be unpacked with wrong convention")


if __name__ == '__main__':
    main()
