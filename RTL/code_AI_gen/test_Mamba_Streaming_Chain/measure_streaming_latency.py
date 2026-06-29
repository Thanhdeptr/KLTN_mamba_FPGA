#!/usr/bin/env python3
"""Parse timing monitor + mamba chain logs; summarize streaming latency vs batch model."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


def parse_timing_monitor(path: Path) -> dict:
    inproj_x: dict[int, int] = {}
    inproj_z: dict[int, int] = {}
    conv_x: dict[int, int] = {}
    conv_z: dict[int, int] = {}
    for line in path.read_text().splitlines():
        m = re.search(
            r"\[CHECK INPROJ\] clk=(\d+) tok=0 grp=(\d+) path=([XZ]).*delta_from_X=(\d+)?",
            line,
        )
        if m:
            clk, grp, path_xz = int(m.group(1)), int(m.group(2)), m.group(3)
            if path_xz == "X":
                inproj_x[grp] = clk
            else:
                inproj_z[grp] = clk
        m = re.search(
            r"\[CHECK CONV\] clk=(\d+) tok=0 grp=(\d+) path=([XZ]).*delta_from_X=(\d+)?",
            line,
        )
        if m:
            clk, grp, path_xz = int(m.group(1)), int(m.group(2)), m.group(3)
            if path_xz == "X":
                conv_x[grp] = clk
            else:
                conv_z[grp] = clk
        m = re.search(r"final_clk=(\d+)", line)
        final_clk = int(m.group(1)) if m else None
    return {
        "inproj_x": inproj_x,
        "inproj_z": inproj_z,
        "conv_x": conv_x,
        "conv_z": conv_z,
        "final_clk": final_clk,
    }


def parse_mamba_latency(path: Path) -> dict[str, int]:
    out: dict[str, int] = {}
    keys = (
        "start",
        "first_inproj_X0",
        "last_inproj_beat",
        "first_conv_X0",
        "first_scan_valid",
        "feed_complete",
        "first_out_valid",
        "token0_out_valid",
    )
    for line in path.read_text().splitlines():
        if line.startswith("[LATENCY]"):
            for k in keys:
                m = re.search(rf"{re.escape(k)}=(\d+)", line)
                if m:
                    out[k] = int(m.group(1))
            m = re.search(r"batch_model_first_scan~=(\d+)", line)
            if m:
                out["batch_model_first_scan"] = int(m.group(1))
            m = re.search(r"overlap_saved_first_scan~=(\d+)", line)
            if m:
                out["overlap_saved_first_scan"] = int(m.group(1))
        m = re.search(r"final_clk=(\d+)", line)
        if m:
            out["final_clk"] = int(m.group(1))
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--timing-log", type=Path, required=True)
    ap.add_argument("--chain-log", type=Path, required=True)
    args = ap.parse_args()

    tm = parse_timing_monitor(args.timing_log)
    lat = parse_mamba_latency(args.chain_log)

    print("=== InProj / Conv timing (token 0) ===")
    if tm["inproj_x"]:
        g0 = min(tm["inproj_x"])
        print(f"  first InProj X: grp={g0} clk={tm['inproj_x'][g0]}")
    if tm["inproj_z"]:
        last_g = max(tm["inproj_z"], key=tm["inproj_z"].get)
        print(f"  last InProj Z:  grp={last_g} clk={tm['inproj_z'][last_g]}")
    if 0 in tm["inproj_x"] and 0 in tm["inproj_z"]:
        print(f"  InProj X0→Z0 delta: {tm['inproj_z'][0] - tm['inproj_x'][0]} cy")
    if tm["conv_x"]:
        g0 = min(tm["conv_x"])
        print(f"  first Conv X: grp={g0} clk={tm['conv_x'][g0]}")
    if 0 in tm["conv_x"] and 0 in tm["conv_z"]:
        print(f"  Conv X0→Z0 delta: {tm['conv_z'][0] - tm['conv_x'][0]} cy")

    print("\n=== Full Mamba chain latency (token 0) ===")
    for k, v in lat.items():
        print(f"  {k}: {v}")

    if "first_inproj_X0" in lat and "last_inproj_beat" in lat:
        span = lat["last_inproj_beat"] - lat["first_inproj_X0"]
        print(f"\n  InProj macro span X0→last beat: {span} cy (overlap window)")

    if "first_scan_valid" in lat and "batch_model_first_scan" in lat:
        saved = lat.get("overlap_saved_first_scan", lat["batch_model_first_scan"] - lat["first_scan_valid"])
        pct = 100.0 * saved / lat["batch_model_first_scan"] if lat["batch_model_first_scan"] else 0.0
        print(f"\n=== Batch vs streaming (first scan) ===")
        print(f"  streaming first_scan: {lat['first_scan_valid']} cy")
        print(f"  batch model first_scan: {lat['batch_model_first_scan']} cy")
        print(f"  overlap saved: {saved} cy ({pct:.1f}% vs batch first_scan time)")

    if "start" in lat and "token0_out_valid" in lat:
        print(f"\n  start → token0 OutProj valid: {lat['token0_out_valid'] - lat['start']} cy")
    if "final_clk" in lat:
        print(f"  total sim cycles (feed+drain): {lat['final_clk']}")


if __name__ == "__main__":
    main()
