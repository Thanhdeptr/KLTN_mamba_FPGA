#!/usr/bin/env python3
"""Parse Vivado OOC synth reports into a summary table."""

from __future__ import annotations

import re
import sys
from pathlib import Path


def parse_util_flat(path: Path) -> dict[str, int]:
    text = path.read_text(encoding="utf-8", errors="ignore")
    out: dict[str, int] = {}
    patterns = {
        "lut": r"\|\s*CLB LUTs\*\s*\|\s*(\d+)",
        "ff": r"\|\s*CLB Registers\s*\|\s*(\d+)",
        "dsp": r"\|\s*DSPs\s*\|\s*(\d+)",
        "bram": r"\|\s*Block RAM Tile\s*\|\s*(\d+)",
    }
    for key, pat in patterns.items():
        m = re.search(pat, text)
        out[key] = int(m.group(1)) if m else -1
    return out


def parse_timing(path: Path) -> dict[str, float]:
    text = path.read_text(encoding="utf-8", errors="ignore")
    out = {"wns": float("nan"), "tns": float("nan"), "whs": float("nan"), "ths": float("nan")}
    m = re.search(
        r"WNS\(ns\)\s+TNS\(ns\).*?\n\s*-+\s*\n\s*([-\d\.]+)\s+([-\d\.]+)\s+\d+\s+\d+\s+([-\d\.]+)\s+([-\d\.]+)",
        text,
        re.S,
    )
    if m:
        out["wns"] = float(m.group(1))
        out["tns"] = float(m.group(2))
        out["whs"] = float(m.group(3))
        out["ths"] = float(m.group(4))
    return out


def fmt_num(v: float) -> str:
    if v != v:
        return "n/a"
    return f"{v:.3f}"


def main() -> None:
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent
    manifest = root / "synth_blocks_manifest.txt"
    if not manifest.is_file():
        print(f"Missing manifest: {manifest}", file=sys.stderr)
        sys.exit(1)

    rows: list[dict[str, str]] = []
    for line in manifest.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = [p.strip() for p in line.split("|")]
        if len(parts) < 3:
            continue
        name, period_ns, tag = parts[0], parts[1], parts[2]
        util = parse_util_flat(root / f"synth_util_{tag}_flat.txt")
        tim = parse_timing(root / f"synth_timing_{tag}.txt")
        wns = tim["wns"]
        status = "PASS" if wns == wns and wns >= 0 else "FAIL"
        fmax = (1000.0 / float(period_ns)) if wns == wns and wns >= 0 else float("nan")
        if wns == wns and wns >= 0:
            fmax = 1000.0 / (float(period_ns) - wns)
        rows.append(
            {
                "module": name,
                "clk_ns": period_ns,
                "wns": fmt_num(wns),
                "tns": fmt_num(tim["tns"]),
                "whs": fmt_num(tim["whs"]),
                "timing": status,
                "fmax_mhz": f"{fmax:.1f}" if fmax == fmax else "n/a",
                "lut": str(util["lut"]),
                "ff": str(util["ff"]),
                "dsp": str(util["dsp"]),
                "bram": str(util["bram"]),
            }
        )

    md = root / "synth_blocks_summary.md"
    txt = root / "synth_blocks_summary.txt"
    header = "| Module | Clk(ns) | WNS | TNS | WHS | Timing | Est.Fmax(MHz) | LUT | FF | DSP | BRAM |\n"
    sep = "|---|---:|---:|---:|---:|---|---:|---:|---:|---:|---:|\n"
    body = ""
    for r in rows:
        body += (
            f"| {r['module']} | {r['clk_ns']} | {r['wns']} | {r['tns']} | {r['whs']} | {r['timing']} | "
            f"{r['fmax_mhz']} | {r['lut']} | {r['ff']} | {r['dsp']} | {r['bram']} |\n"
        )
    md.write_text("# OOC Synthesis Summary (KV260 xck26-sfvc784-2LV-c)\n\n" + header + sep + body, encoding="utf-8")
    txt.write_text(header + sep + body, encoding="utf-8")
    print(md.read_text(encoding="utf-8"))


if __name__ == "__main__":
    main()
