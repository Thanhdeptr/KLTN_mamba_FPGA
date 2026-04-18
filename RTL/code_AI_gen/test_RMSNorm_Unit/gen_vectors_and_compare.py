from pathlib import Path


def read_hex(path: Path):
    arr = []
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            s = line.strip().lower()
            if not s or "x" in s:
                continue
            arr.append(int(s, 16) & 0xFFFF)
    return arr


def to_signed(v: int) -> int:
    return v if v < 0x8000 else v - 0x10000


def compare(abs_tol: int = 256):
    rtl = read_hex(Path("rtl_output.mem"))
    golden = read_hex(Path("golden_output.mem"))
    n = min(len(rtl), len(golden))

    mismatches = 0
    for i in range(n):
        err = abs(to_signed(rtl[i]) - to_signed(golden[i]))
        if err > abs_tol:
            mismatches += 1
            if mismatches <= 12:
                print(
                    f"idx={i} exp={golden[i]:04x} got={rtl[i]:04x} "
                    f"abs_err={err}"
                )

    print(f"Compared: {n}")
    print(f"Mismatches(>|{abs_tol}|): {mismatches}")

    raise SystemExit(0 if mismatches == 0 else 1)


if __name__ == "__main__":
    compare()
