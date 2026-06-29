# Production Component OOC Synthesis (KV260 xck26-sfvc784-2LV-c @ 100MHz)

Component modules from `RMSNorm_InProj_Conv_Scan_Chain_Wrapper` + `Out_Projection_Streaming_v2` (no wrappers).

| Module | Note | Clk(ns) | WNS | TNS | WHS | Timing | Est.Fmax | LUT | FF | DSP | BRAM |
|---|---|---:|---:|---:|---:|---|---:|---:|---:|---:|---:|
| RMSNorm_Unit_IntSqrt | IntSqrt RMSNorm per-token | 10.0 | n/a | n/a | n/a | FAIL | n/a | 2769 | 1526 | 8 | 0 |
| In_Projection_Unit_Streaming_v2 | 16-bank BRAM, 128 MAC/tap | 10.0 | n/a | n/a | n/a | FAIL | n/a | 0 | 0 | 0 | 0 |
| Conv1D_Layer | NUM_MAC=8 depthwise k=4 + dual SiLU | 10.0 | n/a | n/a | n/a | FAIL | n/a | 0 | 0 | 0 | 0 |
