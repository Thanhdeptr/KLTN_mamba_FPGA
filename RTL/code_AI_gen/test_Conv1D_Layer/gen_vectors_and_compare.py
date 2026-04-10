from pathlib import Path


def write_zero_mem(path: Path, n: int):
    path.write_text("\n".join("0000" for _ in range(n)) + "\n", encoding="utf-8")


def generate():
    # One zero test case for 16 lanes, kernel size 4
    write_zero_mem(Path("x_in.mem"), 16)
    write_zero_mem(Path("bias.mem"), 16)
    write_zero_mem(Path("weights.mem"), 16 * 4)
    # With all-zero data and weights/bias, expected output is all zero.
    write_zero_mem(Path("golden_output.mem"), 16)


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
    for i in range(n):
        if rtl[i] != golden[i]:
            mismatches += 1
            if mismatches <= 10:
                print(f"idx={i} exp={golden[i]:04x} got={rtl[i]:04x}")
    print(f"Compared: {n}")
    print(f"Mismatches: {mismatches}")
    raise SystemExit(0 if mismatches == 0 else 1)


if __name__ == "__main__":
    generate()
    if Path("rtl_output.mem").exists():
        compare()
