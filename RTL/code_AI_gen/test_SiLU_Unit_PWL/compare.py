from pathlib import Path


def read_hex_lines(path: Path, limit: int | None = None):
    values = []
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            s = line.strip().lower()
            if not s or "x" in s:
                continue
            values.append(int(s, 16) & 0xFFFF)
            if limit is not None and len(values) >= limit:
                break
    return values


def to_signed16(v: int) -> int:
    return v - 0x10000 if (v & 0x8000) else v


def main():
    rtl = read_hex_lines(Path("rtl_output.mem"))
    golden = read_hex_lines(Path("golden_output.mem"), limit=len(rtl))

    n = min(len(rtl), len(golden))
    if n == 0:
        raise SystemExit("No comparable samples found.")

    mismatches = 0
    first_errors = []
    for i in range(n):
        if rtl[i] != golden[i]:
            mismatches += 1
            if len(first_errors) < 10:
                first_errors.append(
                    (
                        i,
                        f"{golden[i]:04x}",
                        f"{rtl[i]:04x}",
                        abs(to_signed16(golden[i]) - to_signed16(rtl[i])),
                    )
                )

    print(f"Compared: {n}")
    print(f"Mismatches: {mismatches}")
    for idx, exp_hex, got_hex, abs_err in first_errors:
        print(f"idx={idx} expected={exp_hex} got={got_hex} abs_err={abs_err}")

    raise SystemExit(0 if mismatches == 0 else 1)


if __name__ == "__main__":
    main()
