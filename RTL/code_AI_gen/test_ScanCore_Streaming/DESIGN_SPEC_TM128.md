# ScanCore_TM128: Pipeline Streaming Architecture Specification

> **Cập nhật plan (2026-06):** Chuyển từ serial functional (`Scan_Channel_Exec` + 16 PE share) sang **pipeline S0–S6 gối đầu**.
> Phase 1 serial đã PASS golden tại `RTL/testbench/test_Scancore/`. Spec này là target RTL pipeline.
> Plan chi tiết: [`.cursor/plans/ssm_scan_streaming_pipeline.plan.md`](../../../.cursor/plans/ssm_scan_streaming_pipeline.plan.md)

## Overview

Time-multiplex 1 ScanCore xử lý 128 channel/token với **pipeline gối đầu đa stage** — khi grp0 ở S3–S4, grp1 có thể ở S1–S2.

**Key Features:**
- Input **đã activate từ Conv**: `x_act`, `z_act` (không silu nội bộ)
- Delta branch S1: softplus(δ), δ⊙A, δ⊙B, exp(δ⊙A)
- Beat order InProj v2: **X0,Z0,X1,Z1,...,X7,Z7**
- Pipeline stage S0–S6: dispatch **1 channel/cycle** sau warm-up
- FIFO tag: ghép `y_pre` và `z_act` theo `(token, ch)`
- **DSP budget: 48–96** (3–4 vector MUL engine × 16 lane + gate)

---

## Stage-Level Architecture

### Stage S0: Context Load (Ingress)
**Purpose:** Nạp context khi channel job vào pipeline (từ X beat queue hoặc per-lane dispatch)

**Load:**
- A_row[15:0] theo (token, ch)
- D_ch theo ch
- h_prev_row[15:0] từ h_mem @ token-1
- delta_raw, x_act từ beat X (x_act đã silu Conv)
- B_row, C_row per token (broadcast)

**Output (latch → S1):**
- delta_raw, x_act
- A_row[15:0], D_ch, h_prev_row[15:0]
- token_id, channel_id (tag)

**Cycles:** 1 cycle

---

### Stage S1: Delta Branch + Exp pre-compute (3 cycles)
**Purpose:** Tính softplus(delta), delta*A, delta*B, exp(delta*A) song song

**Compute:**
```
Cycle S1_a:
  - softplus_unit.in = delta_raw
  - delta_raw × A_row (16-lane MUL)
  - delta_raw × B_row (scalar, reuse dari MUL lane output)
  - signed_sh(exp(delta*A)) feed vào Exp_Unit

Cycle S1_b:
  - softplus_unit: latch kết quả (PWL latency ~1 cycle)
  - MUL results: deltaA_result[15:0], deltaB_result

Cycle S1_c:
  - softplus(delta) ready
  - Exp_Unit: output exp(delta*A) ready (PWL ~2 cycle latency)
```

**DSP used:** 
- 1× Vector MUL engine 16-lane @ ~16 DSP
- 1× Softplus PWL (LUT-based, no DSP)
- 1× Exp PWL (LUT-based, no DSP)

**Output latch S1_out:**
- delta_act = softplus(delta)
- deltaA_result[15:0]
- deltaB_result
- exp_deltaA_result[15:0] (from Exp_Unit after 2-cycle wait in S1_c)
- h_prev_row[15:0]
- D_ch
- x_raw, z_raw (tag x/z)
- token_id, channel_id

**Total S1 latency: 3 cycles**

---

### Stage S2: X Branch (2 cycles)
**Purpose:** discA*h_prev, deltaB*x_act, D*x_act — `x_act` đã silu từ Conv (không SiLU nội bộ)

**Compute:**
```
Cycle S2_a:
  - exp_deltaA (from S1) × h_prev (16-lane MUL)
  - deltaB (from S1) × x_act (scalar MUL)
  - D × x_act (scalar MUL)

Cycle S2_b:
  - discA_h_prev[15:0] = exp_deltaA * h_prev result
  - deltaB_x_act = deltaB * x_act result
  - D_x_act = D * x_act result
```

**DSP used:** 
- **Dedicated** Vector MUL 16-lane engine #2 (16 DSP) — không share với S1 khi overlap
- 2× Scalar MUL (deltaB*x, D*x) — time-share 1–2 lane

**Output latch S2_out:**
- x_act (from Conv, passthrough tag)
- discA_h_prev[15:0]
- deltaB_x_act
- D_x_act
- token_id, channel_id

**Total S2 latency: 2 cycles**

---

### Stage S3: State Update (2 cycles)
**Purpose:** h_new = discA*h_prev + deltaB*x_act, store to h_mem

**Compute:**
```
Cycle S3_a:
  - 16-lane ADD: discA_h_prev[i] + deltaB_x_act
    (if deltaB_x_act is scalar, broadcast to all lanes or fold into PE accumulator)

Cycle S3_b:
  - h_new_result[15:0] ready
  - Write h_mem: addr = token_id * 128 * 16 + channel_id * 16 + 0..15
  - data = h_new_result[15:0]
```

**DSP used:** 
- 1× Vector ADD 16-lane (LUT-based)
- 0 DSP (if ADD done in concurrent ALU, else minimal)

**Output latch S3_out:**
- h_new[15:0]
- D_x_act (from S2 delay)
- z_raw (further delay for S5)
- token_id, channel_id

**Total S3 latency: 2 cycles**

---

### Stage S4: Output Pre-Gate (2 cycles)
**Purpose:** y_pre = dot(C, h_new) + D*x_act

**Compute:**
```
Cycle S4_a:
  - 16-lane MUL: C_row[i] * h_new[i]
  - Accumulate 16 products → sum_C_h (16-to-1 reduce tree, ~1 cycle)

Cycle S4_b:
  - y_sum = sum_C_h + D_x_act (scalar ADD)
  - y_pre = saturate(y_sum) to Q3.12
```

**DSP used:** 
- 1× Vector MUL 16-lane
- 1× Scalar ADD (LUT)

**Output latch S4_out:**
- y_pre = (C*h_new + D*x_act) saturated
- z_raw (further delay for S5/S6)
- token_id, channel_id
- **Enqueue (y_pre, token_id, channel_id) into FIFO_y_pre**

**Total S4 latency: 2 cycles**

---

### Stage S5: Z Branch (Independent, no blocking S1-S4)
**Purpose:** Latch `z_act` từ beat Z (Conv đã SiLU) — không activate nội bộ

**Compute:**
```
On Z beat (beat_path_x=0):
  - Latch z_act[15:0] per lane with tag (token, grp, lane, ch)
  - **Enqueue (z_act, token_id, channel_id) into FIFO_z**
```

**DSP used:** 0

**Total S5 latency: 1 cycle (overlaps with S1-S4)**

---

### Stage S6: Final Gate & Output (On-demand merge)
**Purpose:** y_out = y_pre * silu(z) when both (y_pre, token_id, channel_id) and (z_act, token_id, channel_id) are ready

**Merge Logic:**
```
When FIFO_y_pre has entry (y_pre_i, tok_i, ch_i) 
AND FIFO_z has entry matching (tok_i, ch_i):
  - Pop both FIFOs
  - MUL: y_out = y_pre * z_act (1 DSP scalar MUL)
  - Saturate y_out to Q3.12
  - Output y_out with token_id, channel_id
```

**DSP used:** 
- **16-lane MUL** (16 DSP) for parallel gate per beat, or 1 scalar if merge 1 ch/cycle

**Output:**
- y_out[15:0] per channel (or 16-lane beat)
- token_id, channel_id (for ordering check)

**Total S6 latency: 1 cycle (MUL)**

---

## Scheduler & Control Flow

### Channel Loop (Per Token)
```
for token_id = 0 to TOKENS-1:
  for channel_id = 0 to 127:
    // Initiate pipeline stages
    dispatch(token_id, channel_id) → S0 context load
    // stages S1-S6 proceed autonomously with pipeline valid/ready
```

### Timeline Example (Single Token, First 3 Channels)

```
Cycle:    0      1      2      3      4      5      6      7      8     9    10    11   12
Ch0:     [S0]  [S1a] [S1b] [S1c]  [S2a] [S2b] [S3a] [S3b] [S4a] [S4b] [S5] [S6]
Ch1:            [S0]  [S1a] [S1b] [S1c] [S2a] [S2b] [S3a] [S3b] [S4a] [S4b][S5][S6]
Ch2:                   [S0] [S1a] [S1b] [S1c] [S2a] [S2b] [S3a] [S3b] [S4a][S4b][S5][S6]
Z0:               [S5 start when z_raw ready in S0]      [z_act ready ~2 cycle]
Z1:                    [S5 start] ...                      [z_act ready]
Z2:                          [S5 start] ...                [z_act ready]
```

**Key insight:** Channels proceed staggered, S5 (z branch) overlaps fully without blocking other stages.

---

## FIFO Tag & Output Ordering

### FIFO_y_pre
- Entry: (y_pre[15:0], token_id[10:0], channel_id[6:0])
- Written after S4 completes for each (token_id, channel_id)
- Depth: ~4-8 entries (absorb S5/S6 latency variance)

### FIFO_z
- Entry: (z_act[15:0], token_id[10:0], channel_id[6:0])
- Written after S5 completes
- Depth: ~4-8 entries

### S6 Merge Logic
```
always @(posedge clk) begin
  if (FIFO_y_pre.valid && FIFO_z.valid) begin
    if (FIFO_y_pre.token_id == FIFO_z.token_id && 
        FIFO_y_pre.channel_id == FIFO_z.channel_id) begin
      // Tags match: merge and output
      y_out = (FIFO_y_pre.y_pre * FIFO_z.z_act) >>> FRAC_BITS;
      FIFO_y_pre.deq();
      FIFO_z.deq();
      output_valid = 1;
    end else begin
      // Mismatch: wait or error (scheduler must ensure ordering)
    end
  end
end
```

**Assumption:** Scheduler ensures y_pre and z_act for same (token_id, channel_id) arrive at S6 in order, no interlocking. If Z is significantly slower (e.g., SiLU PWL takes 3 cycles), FIFO absorbs delay.

---

## Resource Budget & DSP Allocation

### DSP Count per Stage (pipeline — dedicated engines)

| Stage | Operation | DSP Count | Notes |
|-------|-----------|-----------|-------|
| S1 | delta × A (16-lane MUL) | **16** | Engine #1 — dedicated |
| S1 | softplus + exp PWL | 0 | LUT-based |
| S2 | exp(deltaA) × h_prev (16-lane MUL) | **16** | Engine #2 — runs parallel with S1 on different ch |
| S2 | deltaB × x + D × x (scalar) | 0–2 | LUT or 1–2 lane share |
| S3 | 16-lane ADD | 0 | LUT adders |
| S4 | C × h_new (16-lane MUL) + reduce | **16** | Engine #3 |
| S5 | z_act latch | 0 | From Conv |
| S6 | y_pre × z_act gate | **16** (or 1) | 16-lane = match beat rate |

**Total DSP tiers:**

| Tier | DSP | Throughput |
|------|-----|------------|
| Min overlap | **~48** | 3× MUL engine, ~140 cy/token |
| Balanced | **~64** | + 16-lane gate |
| Production | **80–96** | Full chain, no stall vs Conv |

**So với serial Phase 1:** 16 PE share (~20 DSP) → ~2750 cy/token. Pipeline + 48+ DSP → ~15–20× faster.

**Comparison (historical):**
- 128 parallel cores × 16 PE ≈ 4096 DSP
- 1 pipeline core × 48–96 DSP ≈ **98% reduction** với throughput tương đương chain

---

## Interface / Port Spec

### Input Ports
```verilog
module ScanCore_TM128 #(
    parameter DATA_WIDTH = 16,
    parameter D_STATE = 16,
    parameter D_INNER = 128,
    parameter FRAC_BITS = 12
) (
    input clk,
    input reset,
    
    // Control
    input start,           // pulse to initiate token processing
    input en,              // pipeline enable (flow control)
    input clear_h,         // reset hidden state
    output reg done,       // pulse when all 128 channels done for 1 token
    
    // Token-level inputs (broadcasted per token)
    input signed [DATA_WIDTH-1:0] B_row[D_STATE-1:0],  // 16 elements
    input signed [DATA_WIDTH-1:0] C_row[D_STATE-1:0],  // 16 elements
    
    // Per-channel streaming (mux by scheduler)
    input signed [DATA_WIDTH-1:0] delta_raw,
    input signed [DATA_WIDTH-1:0] x_raw,
    input signed [DATA_WIDTH-1:0] z_raw,
    
    // Memory read ports (implicit in module)
    // h_state_mem: read h_prev by (token_id, channel_id, state_idx)
    // A_log_mem: read A_row by channel_id
    // D_mem: read D by channel_id
    
    // Output stream
    output reg signed [DATA_WIDTH-1:0] y_out,
    output reg y_out_valid,           // pulse when y_out ready
    output reg [9:0] y_token_id,      // which token
    output reg [6:0] y_channel_id     // which channel
);
```

### Handshake Protocol
- **start:** User pulses start=1 for 1 cycle to begin processing 1 token (128 channels)
- **done:** Core pulses done=1 when all 128 channels output for that token
- **en:** Flow control, if en=0, pipeline stalls (for external backpressure)
- **y_out_valid:** High when y_out contains valid data; user reads and de-asserts ready if needed

### Memory Architecture (Internal)
```
// Distributed/embedded within ScanCore_TM128:
h_state_mem:   [TOKEN_MAX][D_INNER*D_STATE] = [1000][128*16]
A_log_mem:     [D_INNER][D_STATE] = [128][16] (or read from external)
D_mem:         [D_INNER] = [128]
```

---

## Pipeline Depth & Latency

**Per-channel pipeline depth:** ~11 cycles (S0 + S1 + S2 + S3 + S4 + S6 wait)
**Channel stagger:** 1 cycle per new channel dispatch → throughput after warm-up = ~1 channel/cycle

**Total latency per token (128 channels):**
- Channel 0: dispatch @ cycle 0, output @ cycle ~11
- Channel 127: dispatch @ cycle 127, output @ cycle ~138
- Token complete: cycle ~140 (including drain)

**Throughput:** ~128 channels / 140 cycles ≈ **0.91 channels/cycle** sustained

---

## Design Verification Checklist

- [ ] Scheduler ensures (token_id, channel_id) pairs don't duplicate or skip
- [ ] FIFO_y_pre and FIFO_z merge correctly by tag without deadlock
- [ ] All saturation done to ±32767 (Q3.12)
- [ ] Exp_Unit, SiLU_unit, Softplus_unit PWL output match golden to ±1 LSB
- [ ] h_state write/read address calculation correct (avoiding off-by-one)
- [ ] Start/en/done handshake non-blocking and pipelined
- [ ] DSP utilization matches budget ~20 DSP
- [ ] Timing closure met @ target Fmax (e.g., 200 MHz)

---

## Next Steps

1. ✅ Serial functional PASS — `RTL/testbench/test_Scancore/` (golden reference).
2. **Implement pipeline** — `Scan_S0_Ingress` … `Scan_S6_Gate` + `Scan_Core_Streaming_Pipe.v`.
3. **Verify** pipeline vs serial golden N=1/10/1000; throughput ≤200 cy/token.
4. **Chain** — FIFO + `scan_ready` in `Scan_Chain_Wrapper.v`.
5. **Synthesis OOC** — target 48–96 DSP @ 100 MHz.

See [`.cursor/plans/ssm_scan_streaming_pipeline.plan.md`](../../../.cursor/plans/ssm_scan_streaming_pipeline.plan.md).
