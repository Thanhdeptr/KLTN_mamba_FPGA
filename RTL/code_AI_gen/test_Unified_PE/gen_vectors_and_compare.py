from pathlib import Path
import random

FRAC_BITS = 12
MAX_POS = 32767
MIN_NEG = -32768
N = 512

MODE_MAC = 0
MODE_MUL = 1
MODE_ADD = 2


def to_signed16(v: int) -> int:
    v &= 0xFFFF
    return v - 0x10000 if (v & 0x8000) else v


def to_hex16(v: int) -> str:
    return f"{(v & 0xFFFF):04x}"


def sat16(v: int) -> int:
    if v > MAX_POS:
        return MAX_POS
    if v < MIN_NEG:
        return MIN_NEG
    return v


def generate_vectors():
    rng = random.Random(12345)
    ops = []
    clears = []
    a_vals = []
    b_vals = []

    for i in range(N):
        if i % 97 == 0:
            op = MODE_MAC
            clear = 1
            a = 0
            b = 0
        else:
            op = [MODE_MAC, MODE_MUL, MODE_ADD][i % 3]
            clear = 0
            a = rng.randint(-32768, 32767)
            b = rng.randint(-32768, 32767)
        ops.append(op)
        clears.append(clear)
        a_vals.append(a)
        b_vals.append(b)

    Path("op_mode.mem").write_text("\n".join(f"{x:x}" for x in ops) + "\n", encoding="utf-8")
    Path("clear_acc.mem").write_text("\n".join(f"{x:x}" for x in clears) + "\n", encoding="utf-8")
    Path("in_a.mem").write_text("\n".join(to_hex16(x) for x in a_vals) + "\n", encoding="utf-8")
    Path("in_b.mem").write_text("\n".join(to_hex16(x) for x in b_vals) + "\n", encoding="utf-8")

    acc = 0
    golden = []
    for op, clr, a, b in zip(ops, clears, a_vals, b_vals):
        if clr:
            acc = 0
            out = 0
        else:
            mult = a * b
            mult_shift = mult >> FRAC_BITS
            if op == MODE_MAC:
                temp = acc + mult_shift
            elif op == MODE_MUL:
                temp = mult_shift
            elif op == MODE_ADD:
                temp = a + b
            else:
                temp = 0
            out = sat16(temp)
            acc = out
        golden.append(out)
    Path("golden_output.mem").write_text("\n".join(to_hex16(x) for x in golden) + "\n", encoding="utf-8")


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
                print(
                    f"idx={i} exp={golden[i]:04x} got={rtl[i]:04x} "
                    f"abs_err={abs(to_signed16(golden[i]) - to_signed16(rtl[i]))}"
                )
    print(f"Compared: {n}")
    print(f"Mismatches: {mismatches}")
    raise SystemExit(0 if mismatches == 0 else 1)


if __name__ == "__main__":
    generate_vectors()
    if Path("rtl_output.mem").exists():
        compare()
