from pathlib import Path

FRAC_BITS = 12
MAX_POS = 32767
MIN_NEG = -32768


def to_signed16(v: int) -> int:
    v &= 0xFFFF
    return v - 0x10000 if (v & 0x8000) else v


def to_hex16_signed(v: int) -> str:
    return f"{(v & 0xFFFF):04x}"


def load_rom(path: Path):
    rom = []
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            s = line.strip()
            if not s:
                continue
            x = int(s, 16) & 0xFFFFFFFF
            slope = to_signed16((x >> 16) & 0xFFFF)
            intercept = to_signed16(x & 0xFFFF)
            rom.append((slope, intercept))
    return rom


def gen_input_mem(path: Path):
    vals = list(range(-32768, 32768, 64))
    with path.open("w", encoding="utf-8") as f:
        for v in vals:
            f.write(to_hex16_signed(v) + "\n")
    return vals


def model(x_signed: int, rom):
    x_u16 = x_signed & 0xFFFF
    addr = (x_u16 >> 10) & 0x3F
    slope, intercept = rom[addr]
    prod = slope * x_signed
    res = (prod >> FRAC_BITS) + intercept
    if res > MAX_POS:
        return MAX_POS
    if res < MIN_NEG:
        return MIN_NEG
    return res


def read_hex_lines(path: Path):
    out = []
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            s = line.strip().lower()
            if not s or "x" in s:
                continue
            out.append(int(s, 16) & 0xFFFF)
    return out


def main():
    rom = load_rom(Path("softplus_pwl_coeffs.mem"))
    inputs = gen_input_mem(Path("input.mem"))

    with Path("golden_output.mem").open("w", encoding="utf-8") as f:
        for x in inputs:
            y = model(x, rom)
            f.write(to_hex16_signed(y) + "\n")

    if not Path("rtl_output.mem").exists():
        print("Generated input.mem and golden_output.mem")
        return

    rtl = read_hex_lines(Path("rtl_output.mem"))
    golden = read_hex_lines(Path("golden_output.mem"))
    n = min(len(rtl), len(golden))
    mismatches = 0
    for i in range(n):
        if rtl[i] != golden[i]:
            mismatches += 1
            if mismatches <= 10:
                print(
                    f"idx={i} exp={golden[i]:04x} got={rtl[i]:04x} "
                    f"abs_err={abs(to_signed16(golden[i]) - to_signed16(rtl[i]))}"
                )
    print(f"Compared: {n}")
    print(f"Mismatches: {mismatches}")
    raise SystemExit(0 if mismatches == 0 else 1)


if __name__ == "__main__":
    main()
