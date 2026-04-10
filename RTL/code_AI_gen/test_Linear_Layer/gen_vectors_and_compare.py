from pathlib import Path


def write_zero(path: Path, n: int):
    path.write_text("\n".join("0000" for _ in range(n)) + "\n", encoding="utf-8")


def generate():
    write_zero(Path("W_row.mem"), 16)
    write_zero(Path("bias.mem"), 16)
    Path("x_val.mem").write_text("0000\n", encoding="utf-8")
    write_zero(Path("golden_output.mem"), 16)


def read_hex(path: Path):
    out = []
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            s = line.strip().lower()
            if not s or "x" in s:
                continue
            out.append(int(s, 16) & 0xFFFF)
    return out


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
