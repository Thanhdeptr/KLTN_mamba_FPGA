#!/usr/bin/env python3
"""Generate LUT seed coefficients for RMSNorm reciprocal sqrt NR core.

Output format: one 16-bit Q3.12 hex value per line, 64 entries.
Address mapping in RTL: addr = mean_sq_q312[15:10], where mean_sq_q312 is Q3.12.
"""

from pathlib import Path
import math

FRAC_BITS = 12
SCALE = 1 << FRAC_BITS


def to_q312(x: float) -> int:
    q = int(round(x * SCALE))
    if q > 32767:
        q = 32767
    if q < -32768:
        q = -32768
    return q & 0xFFFF


def main() -> None:
    repo_root = Path(__file__).resolve().parents[1]
    out_path = repo_root / "RTL" / "code_initial" / "rmsnorm_rsqrt_coeffs.mem"

    lines = []
    for addr in range(64):
        # mean_sq step is 2^10 in Q3.12 => 1024/4096 = 0.25
        x_center = max((addr + 0.5) * 0.25, 1.0 / SCALE)
        # Seed value for NR: y0 ~= 1/sqrt(x)
        seed = 1.0 / math.sqrt(x_center)
        lines.append(f"{to_q312(seed):04x}")

    out_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Generated: {out_path}")


if __name__ == "__main__":
    main()
