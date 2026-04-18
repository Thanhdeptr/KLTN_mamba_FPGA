#!/usr/bin/env python3
"""
Scan/Exp intermediate golden check:
Extract golden h_state evolution + compare RTL trace to detect divergence point
"""
import os
import sys
import numpy as np

golden_dir = '/home/hatthanh/schoolwork/KLTN/ITMN/cpp_golden_files'

def parse_golden_tensor(fname):
    """Parse PyTorch tensor txt format (float values)"""
    try:
        with open(fname) as f:
            lines = f.readlines()
        # Format: tensor(...) or just values
        content = ''.join(lines)
        # Extract numbers
        import re
        nums = re.findall(r'[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?', content)
        return np.array([float(x) for x in nums], dtype=np.float32)
    except:
        return None

# Load key golden tensors
print("=" * 80)
print("GOLDEN SCAN/EXP EXTRACTION")
print("=" * 80)

# Token 0 - h_state initialization (should be ~0)
h_t0_golden = parse_golden_tensor(os.path.join(golden_dir, '13_12_Mixer_h_state_t0.txt'))
if h_t0_golden is not None:
    print(f"\n[Golden] h_state @ t=0 (16 states): shape={h_t0_golden.shape}")
    print(f"  Values (first 8):  {h_t0_golden[:8]}")
    print(f"  Min/Max: {h_t0_golden.min():.6f} / {h_t0_golden.max():.6f}")

# Token 1 - h_state after first step
h_t1_golden = parse_golden_tensor(os.path.join(golden_dir, '14_12_Mixer_h_state_t1.txt'))
if h_t1_golden is not None:
    print(f"\n[Golden] h_state @ t=1 (16 states): shape={h_t1_golden.shape}")
    print(f"  Values (first 8):  {h_t1_golden[:8]}")
    print(f"  Min/Max: {h_t1_golden.min():.6f} / {h_t1_golden.max():.6f}")
    if h_t0_golden is not None:
        delta_h = h_t1_golden - h_t0_golden
        print(f"  Delta from t=0: {delta_h[:8]} (max_delta={delta_h.max():.6f})")

# Delta + B raw
delta_golden = parse_golden_tensor(os.path.join(golden_dir, '10_09_Mixer_delta_final.txt'))
B_golden = parse_golden_tensor(os.path.join(golden_dir, '11_10_Mixer_B_raw.txt'))
C_golden = parse_golden_tensor(os.path.join(golden_dir, '12_11_Mixer_C_raw.txt'))

if delta_golden is not None:
    print(f"\n[Golden] Delta (Δ): shape={delta_golden.shape}, first 8={delta_golden[:8]}")
    print(f"  Min/Max: {delta_golden.min():.6f} / {delta_golden.max():.6f}")

if B_golden is not None:
    print(f"\n[Golden] B_raw: shape={B_golden.shape}, first 8={B_golden[:8]}")
    print(f"  Min/Max: {B_golden.min():.6f} / {B_golden.max():.6f}")

if C_golden is not None:
    print(f"\n[Golden] C_raw: shape={C_golden.shape}, first 8={C_golden[:8]}")
    print(f"  Min/Max: {C_golden.min():.6f} / {C_golden.max():.6f}")

# Scan output raw
scan_out_golden = parse_golden_tensor(os.path.join(golden_dir, '1013_13_Mixer_scan_output_raw.txt'))
y_gated_golden = parse_golden_tensor(os.path.join(golden_dir, '1014_14_Mixer_y_gated.txt'))

if scan_out_golden is not None:
    print(f"\n[Golden] Scan output raw: shape={scan_out_golden.shape}, first 8={scan_out_golden[:8]}")
    print(f"  Min/Max: {scan_out_golden.min():.6f} / {scan_out_golden.max():.6f}")

if y_gated_golden is not None:
    print(f"\n[Golden] Y gated (final): shape={y_gated_golden.shape}, first 8={y_gated_golden[:8]}")
    print(f"  Min/Max: {y_gated_golden.min():.6f} / {y_gated_golden.max():.6f}")

# Now run RTL trace for same token
print("\n" + "=" * 80)
print("RUNNING RTL SIMULATION WITH SCAN/EXP TRACE")
print("=" * 80)

os.system('cd /home/hatthanh/schoolwork/KLTN/RTL/code_AI_gen/test_Mamba_FullBranch_Chain && '
          'python3 prepare_mem.py >/dev/null 2>&1')

# Run xsim with trace token=0, dump full scan details
trace_cmd = (
    'cd /home/hatthanh/schoolwork/KLTN/RTL/code_AI_gen/test_Mamba_FullBranch_Chain && '
    'timeout 60 xsim tb_mamba_fullbranch_chain_sim -testplusarg TOKENS=2 -testplusarg TRACE=1 '
    '-testplusarg TRACE_CH=21 -testplusarg TRACE_TOKEN=0 -runall 2>&1 | head -200'
)
print("\nRTL trace output (token=0, channel=21, first 200 lines):")
print("-" * 80)
os.system(trace_cmd)

print("\n" + "=" * 80)
print("DIAGNOSTIC QUESTIONS:")
print("=" * 80)
print("1. Does RTL h_state grow from t=0 to t=1? (Should match golden delta_h)")
print("2. Are deltaBx values non-zero in RTL? (Pre-fix showed deltaBx=0)")
print("3. Do exp(discA) values match golden scan output?")
print("4. Where does RTL diverge from golden? (Early in Scan FSM or late?)")
print("\nNext: Run full comparison after examining trace.")
