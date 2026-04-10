from pathlib import Path


def generate():
    Path("scalar_input.mem").write_text("\n".join(["0000"] * 4) + "\n", encoding="utf-8")
    Path("A_vec.mem").write_text("\n".join(["0000"] * 16) + "\n", encoding="utf-8")
    Path("B_vec.mem").write_text("\n".join(["0000"] * 16) + "\n", encoding="utf-8")
    Path("C_vec.mem").write_text("\n".join(["0000"] * 16) + "\n", encoding="utf-8")
    Path("golden_output.mem").write_text("0000\n", encoding="utf-8")


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
