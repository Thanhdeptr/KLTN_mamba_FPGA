# Scan Core Streaming — Pipeline Spec (Per-Group Beat)

> **Cập nhật:** Refactor từ serial (Phase 1 PASS) sang **pipeline gối đầu S0–S6**.
> Serial RTL: `Scan_Core_Streaming.v` + `Scan_Channel_Exec` — giữ làm golden reference.

## Math (per channel `ch` at token `t`)

```
δ       = softplus(Δ_raw)
discA   = exp(δ ⊙ A)
h_new   = discA ⊙ h_prev + (δ·B) ⊙ x_act
y_pre   = C·h_new + D·x_act
y_out   = y_pre · z_act        // x_act, z_act pre-silu from Conv
```

## Beat order (InProj v2 interleaved)

`X0,Z0,X1,Z1,...,X7,Z7` per token — 16 channels per beat, `ch = grp*16 + lane`.

Mỗi grp = **16 channel hoàn chỉnh** — streaming từng beat là đúng toán, không cần ghép 8 grp.

## Pipeline stages (gối đầu)

| Stage | Work | Latency | DSP (dedicated) |
|-------|------|---------|-----------------|
| **S0** | Context: tag, Δ, x, A, D, B/C, read `h_prev` | 1 cy | 0 |
| **S1** | softplus, δ⊙A, δ⊙B, exp(δ⊙A) | 3 cy | MUL engine #1: **16** |
| **S2** | discA⊙h_prev, δB⊙x, D⊙x | 2 cy | MUL engine #2: **16** |
| **S3** | h_new ADD, write `h_mem` | 2 cy | 0 (LUT) |
| **S4** | C⊙h_new reduce + D⊙x → `y_pre` | 2 cy | MUL engine #3: **16** |
| **S5** | Latch `z_act` from Z beat | 1 cy | 0 |
| **S6** | Merge FIFO: `y_out = y_pre · z_act` | 1 cy | **16** (or 1 scalar) |

**Dispatch:** Sau warm-up (~12 cy), **1 channel/cycle** vào S0.
**Overlap:** grp0 @ S3–S4 đồng thời grp1 @ S1–S2 khi có 3 MUL engine riêng.

### DSP tiers

| Tier | Total DSP | Notes |
|------|-----------|-------|
| Min overlap | ~48 | 3× vector MUL 16-lane |
| Balanced | ~64 | + 16-lane gate S6 |
| Production | **80–96** | + headroom, match Conv chain |

## Tag (mandatory)

```verilog
{ valid, token, grp, lane, ch }
```

Operand và tag cùng latency mỗi stage — xem `RTL/STREAMING_DESIGN_GUIDE.md`.

## FIFOs

| FIFO | Entry | Depth |
|------|-------|-------|
| Ingress | X beat → 16 ch jobs | 16–32 |
| y_pre | (y_pre, token, ch) | 8 |
| z_act | (z_act, token, ch) | 8 |

S6 merge chỉ khi tag khớp.

## `h_mem` addressing

```
h_addr = token * 2048 + ch * 16 + state_idx
```

`h_prev` @ token `t` reads token `t-1`. BRAM 2-port; no R+W same (token,ch) same cycle.

## Interface

```verilog
input  beat_valid, beat_path_x
input  [15:0] beat_token, [2:0] beat_grp
input  signed [LANES*16-1:0] beat_vec
output scan_ready, scan_valid
output signed [LANES*16-1:0] y_out_vec
```

Chain: FIFO Conv→Scan + `scan_ready` backpressure (no drop on `scan_busy`).

## Throughput target

| Arch | ~cycles/token |
|------|---------------|
| Serial (current) | ~2500–2800 |
| Pipeline (target) | **~140–200** |

## Golden (this folder)

- Inputs: `delta_before_softplus.mem`, `x_activated.mem`, `silu_z_golden.mem`, `A_vec.mem`, `B_vec.mem`, `C_vec.mem`, `D_vec.mem`
- Outputs: `h_state.mem`, `golden_y_gated.mem` (cpp float `y_pre * silu(z)`, includes D·x)
- Tolerance: `compare_tolerance.txt` → `abs_error_lsb=48` (h_state), `y_gated_abs_error_lsb=192` (y_gated)

## Verify plan

1. Serial baseline PASS (done): N=1/10/1000
2. Pipeline 2-ch stagger vs serial N=1
3. Pipeline full beat order N=1/10/1000
4. Throughput log: sustained ≥0.5 ch/cycle

## Implementation files (target)

- `Scan_Core_Streaming_Pipe.v` — top pipeline
- `Scan_S0_Ingress.v` … `Scan_S6_Gate.v` — stage modules
- `Scan_Vector_Mul16.v` — 16-lane MUL (×3 instances)
- Legacy: `Scan_Core_Streaming.v` — serial reference
