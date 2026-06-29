#!/usr/bin/env python3
"""Parse trace_v3.log and compare merge/emit timeline vs v2/golden vec0."""

from pathlib import Path

BASE = Path(__file__).parent


def read256(path):
    vals = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                v = int(line, 16)
            except ValueError:
                continue
            if v >= 0x8000:
                v -= 0x10000
            vals.append(v)
            if len(vals) == 256:
                break
    return vals


def parse_trace(path):
    events = []
    snaps = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line.startswith("P3_EMIT"):
                parts = {}
                for tok in line.split():
                    if "=" in tok:
                        k, v = tok.split("=", 1)
                        parts[k] = v.rstrip(",")
                events.append(parts)
            elif line.startswith("  MERGE_SNAP") or line.startswith("MERGE_SNAP"):
                snaps.append(line)
            elif line.startswith("FIXUP_END"):
                snaps.append(line)
            elif line.startswith("P3_SKIP"):
                events.append({"type": "skip", "line": line})
    return events, snaps


def main():
    v2 = read256(BASE / "rtl_output.mem")
    gold = read256(BASE / "golden_output.mem")
    v3 = read256(BASE / "rtl_output_v3.mem")
    trace_path = BASE / "trace_v3.log"
    if not trace_path.exists():
        print("Missing trace_v3.log — run run_trace_v3.sh first")
        return 1

    emits, snaps = parse_trace(trace_path)

    print("=" * 60)
    print("TRACE ANALYSIS: In_Projection v3 vector 0")
    print("=" * 60)

    print("\n--- Golden / v2 vec0 (target) ---")
    print(f"  gold vec0 lane0 = {gold[0]}")
    print(f"  v2   vec0 lane0 = {v2[0]}")
    print(f"  v3   vec0 lane0 = {v3[0]}  (captured sequential slot 0)")

    print(f"\n--- Pass-3 emit timeline ({len(emits)} events) ---")
    print(f"{'seq':>3} {'pipe':>4} {'log':>3} {'y0':>8}  {'gold[log*16]':>12}  {'v2[log*16]':>12}  match?")
    for e in emits:
        if "seq" not in e:
            print(f"  {e.get('line', e)}")
            continue
        seq = int(e["seq"])
        pipe = int(e["pipe_grp"])
        log = int(e["log_grp"])
        y0 = int(e["y0"])
        g = gold[log * 16] if log < 16 else 0
        r = v2[log * 16] if log < 16 else 0
        ok = "OK" if abs(y0 - g) <= 256 or y0 == r else "MISS"
        print(f"{seq:3d} {pipe:4d} {log:3d} {y0:8d}  {g:12d}  {r:12d}  {ok}")

    print("\n--- merge_out snapshots ---")
    for s in snaps:
        print(s[:120] + ("..." if len(s) > 120 else ""))

    # Which emit should have been vec0?
    print("\n--- Root-cause hints ---")
    log0 = [e for e in emits if e.get("log_grp") == "0"]
    pipe1 = [e for e in emits if e.get("pipe_grp") == "1"]
    if not log0:
        print("  [!] No emit with logical_grp=0 — vec0 never emitted as group 0")
    if pipe1:
        e = pipe1[0]
        print(f"  [!] pipe_grp=1 emit: y0={e.get('y0')} (seq={e.get('seq')}) — likely cold group-0 tagged as 1")
        print(f"      golden vec0 lane0 = {gold[0]}, v2 vec0 = {v2[0]}")

    # Check if sequential slot 0 matches any golden vector
    print("\n--- What golden vector matches v3 sequential slot 0? ---")
    best = min(range(16), key=lambda v: abs(v3[0] - gold[v * 16]))
    print(f"  Closest: golden vec{best} lane0 = {gold[best*16]} (err={abs(v3[0]-gold[best*16])})")

    # Lane-level vec0 partial matches
    ok_lanes = [i for i in range(16) if abs(v3[i] - gold[i]) <= 256]
    print(f"\n--- vec0 lanes within tolerance (<=256): {ok_lanes} ---")
    for i in ok_lanes:
        print(f"  lane {i}: v3={v3[i]} gold={gold[i]} v2={v2[i]}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
