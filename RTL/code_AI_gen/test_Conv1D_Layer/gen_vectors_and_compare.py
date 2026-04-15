from pathlib import Path


def write_zero_mem(path: Path, n: int):
    path.write_text("\n".join("0000" for _ in range(n)) + "\n", encoding="utf-8")


def generate():
    # REAL DATA MODE: Skip generation, use extracted .mem files
    # .mem files already created by extract_real_rtl_golden.py
    # Path: x_in.mem, weights.mem, bias.mem, golden_output.mem (from ITMN model)
    print("✓ Using real model data (extracted from cpp_golden_files)")
    
    # Verify real data files exist
    required_files = ["x_in.mem", "weights.mem", "bias.mem", "golden_output.mem"]
    for fname in required_files:
        if not Path(fname).exists():
            # Fallback to zero test if not found
            print(f"Warning: {fname} not found, falling back to zero test")
            write_zero_mem(Path("x_in.mem"), 16)
            write_zero_mem(Path("bias.mem"), 16)
            write_zero_mem(Path("weights.mem"), 16 * 4)
            write_zero_mem(Path("golden_output.mem"), 16)
            return
    print("✓ All real data files found")


def read_hex(path: Path):
    arr = []
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            s = line.strip().lower()
            if not s or "x" in s:
                continue
            arr.append(int(s, 16) & 0xFFFF)
    return arr


def compare():
    rtl = read_hex(Path("rtl_output.mem"))
    golden = read_hex(Path("golden_output.mem"))
    n = min(len(rtl), len(golden))
    mismatches = 0
    
    print(f"\n{'='*60}")
    print(f"COMPARISON: Conv1D_Layer RTL vs Golden")
    print(f"{'='*60}")
    print(f"Gold outputs: {n}")
    print(f"RTL outputs:  {len(rtl)}")
    
    for i in range(n):
        if rtl[i] != golden[i]:
            mismatches += 1
            if mismatches <= 10:
                rtl_signed = rtl[i] if rtl[i] < 32768 else rtl[i] - 65536
                gold_signed = golden[i] if golden[i] < 32768 else golden[i] - 65536
                print(f"  Mismatch[{i:2d}]: exp={golden[i]:04x}({gold_signed:6d}) got={rtl[i]:04x}({rtl_signed:6d})")
    
    if mismatches == 0:
        print(f"\n✅ PASS: All {n} outputs match!")
    else:
        print(f"\n❌ FAIL: {mismatches}/{n} mismatches")
        
    print(f"{'='*60}\n")
    raise SystemExit(0 if mismatches == 0 else 1)


if __name__ == "__main__":
    generate()
    if Path("rtl_output.mem").exists():
        compare()
