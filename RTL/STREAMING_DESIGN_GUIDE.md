# Hướng Dẫn Thiết Kế Streaming Pipeline & Các Lỗi Phổ Biến

**Mục đích**: Tránh nhắc lại lỗi khi chuyển đổi các khối từ combinational sang streaming, giảm thời gian debug.

---

## 1. TỔNG QUAN LỖI TỪ In_Projection_Unit_Streaming_v2

### Thống Kê Lỗi
| STT | Lỗi | Triệu chứng | Root Cause | Độ ảnh hưởng |
|-----|-----|-----------|-----------|-------------|
| 1 | Data-to-Tag Misalignment | 112/128 lanes sai, error 600-1000 | Operand lag 2 cycle so tag | **Nghiêm trọng** |
| 2 | Startup Bubble | 12/128 lanes sai vector 0, error 600-3100 | Pipeline prime bị zeroed tại t=0 | **Cao** |
| 3 | Stale Debug Registers | Trace không khớp loại hoạc dữ liệu | Snapshot từ multiple stages ko sync | **Medium** |

---

## 2. LỖI #1: DATA-TO-CONTROL-TAG MISALIGNMENT (Operand Lag)

### 2.1 Triệu Chứng
- **Lỗi xuất hiện**: Hầu hết lanes (112/128) bị sai giá trị đầu ra
- **Error range**: 600-1000 units (vượt 256-unit threshold)
- **Pattern**: Sai ngẫu nhiên, không liên quan đến địa chỉ hay group cụ thể ban đầu
- **Debug trace**: Operand tại Stage1 multiply không khớp với expected tại tick hiện tại

### 2.2 Root Cause Chi Tiết

```
Timeline của lỗi:
Tick  | What Happens
------|---------------------------------------
0     | Stage0 fetch: read BRAM word
      | → lưu vào st0_x (register)
      | → prepare st0_x_pipe[1] (NOT pipe[0]!)
      | → tag_pipe[1] = current_tag
      
1     | st0_x_pipe lùi: pipe[2] ← pipe[1] ← pipe[0] ← (cũ)
      | → st0_x_pipe[1] = dữ liệu từ tick -1
      | → tag_pipe[1] = tag từ tick -1
      | OK
      
2     | Stage1 multiply:
      | → multiply st0_x_pipe[1] * st1_x_pipe[1]
      | → st0_x_pipe[1] = dữ liệu từ tick 0 (ĐÃ CŨ 2 cycle)
      | → tag_pipe[1] = tag từ tick 0
      | KO MATCH! Operand tick lệch tag tick!
```

**Nguyên nhân sâu**:
- Stage0 load dữ liệu vào `st0_x` (register), không trực tiếp vào pipeline
- Rồi trong vòng lặp shift pipeline, `pipe[0]` được fill bằng `st0_x` từ cycle trước
- Stage1 consume từ `pipe[1]` (dữ liệu từ 2 cycle trước), không phải `pipe[0]`
- Kết quả: Operand nhân đã "cũ" so với control tag → tính toán SAI

### 2.3 Cách Sửa

**Thay đổi 1: Direct Load Pipeline[0] Tại Stage0 Fetch**

```verilog
// ❌ SAI (cũ):
if (vld_pipe[0]) begin
    st0_x[i][j] <= word[j*DATA_WIDTH +: DATA_WIDTH];  // Lưu vào register
    st1_x[i][j] <= x_sub_vec_pipe[X_LATENCY-1][...];
    // cycle sau mới copy vào pipe[0]
end
for (i=1; i<=PD; i++) begin
    st0_x_pipe[i][...] <= st0_x_pipe[i-1][...];
    st0_x_pipe[0][...] <= st0_x[...];  // Delay 1 cycle!
end

// ✅ ĐÚNG (mới):
if (vld_pipe[0]) begin
    st0_x[i][j] <= word[j*DATA_WIDTH +: DATA_WIDTH];  // Giữ cho debug
    st1_x[i][j] <= x_sub_vec_pipe[X_LATENCY-1][...];
    // Quan trọng: DIRECT load vào pipe[0] ngay lúc này
    st0_x_pipe[0][i][j] <= $signed(word[j*DATA_WIDTH +: DATA_WIDTH]);
    st1_x_pipe[0][i][j] <= $signed(x_sub_vec_pipe[X_LATENCY-1][...]);
end
for (i=1; i<=PD; i++) begin
    st0_x_pipe[i][...] <= st0_x_pipe[i-1][...];
    // pipe[0] đã được load trực tiếp, không cần copy từ st0_x
end
```

**Thay đổi 2: Stage1 Consume Từ pipe[0] Không Phải pipe[1]**

```verilog
// ❌ SAI (cũ):
if (en && vld_pipe[1]) begin
    mult_reg[i][j] <= st0_x_pipe[1][i][j] * st1_x_pipe[1][i][j];
    // Consume từ pipe[1] = dữ liệu 2 cycle tuổi
end

// ✅ ĐÚNG (mới):
if (en && vld_pipe[1]) begin
    mult_reg[i][j] <= st0_x_pipe[0][i][j] * st1_x_pipe[0][i][j];
    // Consume từ pipe[0] = dữ liệu CHỈ mới được fetch
    // → MATCH với tag_pipe[1] (vì tag cũng được push ngay từ Stage0)
end
```

### 2.4 Cách Phát Hiện Sớm: Debug Signals

```verilog
// Thêm vào RTL để monitor:

// Signal 1: Trace operand vs tag mismatch
wire [TAPS*DATA_WIDTH-1:0] operand_at_mult = st0_x_pipe[0];  // Fresh operand
wire [TAG_WIDTH-1:0] tag_at_mult = tag_pipe[1];              // Corresponding tag

// If operand từ tick X nhưng tag từ tick Y:
// → sai alignment ngay!

// Signal 2: Compare operand từ pipe[0] vs pipe[1]
always @(posedge clk) begin
    if (vld_pipe[1]) begin
        $display("[STAGE1] operand_pipe0=%d, operand_pipe1=%d, delta=%d",
                 $signed(st0_x_pipe[0][0][0]),
                 $signed(st0_x_pipe[1][0][0]),
                 $signed(st0_x_pipe[0][0][0]) - $signed(st0_x_pipe[1][0][0]));
        // Nếu delta khác 0 mỗi cycle (ko cyclic pattern) → alignment lỗi
    end
end

// Signal 3: Trace data flow end-to-end
always @(posedge clk) begin
    if (vld_pipe[0]) begin
        // Log: "Fetched data X at tick T with tag G"
        $display("[FETCH] tick=%d group=%d data=%h", 
                 tick_cnt_pipe[0], grp_idx_pipe[0], st0_x_pipe[0][0][0]);
    end
    if (vld_pipe[1]) begin
        // Log: "Multiplying operand with tag"
        $display("[MULT]  tick=%d group=%d operand=%h (from pipe[0])",
                 tick_cnt_pipe[1], grp_idx_pipe[1], st0_x_pipe[0][0][0]);
        // Verify: tick và group hiện tại phải khớp với operand được sử dụng
    end
end
```

### 2.5 Verification Checklist Cho Lỗi #1

- [ ] Kiểm tra: Stage0 direct load vào `pipe[0]` (không qua `st0_x` register)
- [ ] Kiểm tra: Stage1 consume từ `pipe[0]`, không phải `pipe[1]`
- [ ] Chạy xsim với debug signals
- [ ] Verify: Operand tick = tag tick tại Stage1
- [ ] Test case: Group 2 (single lane) trace end-to-end
- [ ] Compare: Expected operand (từ BRAM) vs RTL operand

---

## 3. LỖI #2: STARTUP BUBBLE (Pipeline Prime Bị Zero)

### 3.1 Triệu Chứng
- **Lỗi xuất hiện**: Chỉ output vector **đầu tiên** (vector 0) bị sai
- **Error range**: 600-3100 units (rất lớn)
- **Pattern**: Vector 1-15 PASS, vector 0 FAIL → rõ ràng là startup issue
- **Mô hình sai**: Tất cả 16 lane ở vector 0 đều bị sai, không random

### 3.2 Root Cause Chi Tiết

```
Pipeline prime timing:
Cycle | What Happens
------|-------------------------------------------
0     | start=1 (khởi động)
      | x_sub_vec_pipe[0] <= vld_in ? x_sub_vec_in : 0
      | → vld_in = 0 lúc này (chưa có data)
      | → x_sub_vec_pipe[0] = 0 (ZEROED!)
      | ❌ First sample chưa enter pipeline

1     | vld_in = 1 (first sample arrives)
      | x_sub_vec_pipe[0] <= x_sub_vec_in (mới)
      | → Nhưng first sample đã miss cycle 0
      | → Nó sẽ enter Stage0 ở cycle 1 (trễ 1 cycle)
      | → Rồi propagate ra output vector được dùng là vector 1, không 0!

2+    | Pipeline steady-state
      | → vectors 1-15 chính xác
      | → vector 0 bị dùng kết quả từ '0' đã prime
```

**Nguyên nhân sâu**:
- Điều kiện `vld_in` chỉ đúng sau khi khởi động
- Ở cycle 0 (`start`), `vld_in=0` → `x_sub_vec_pipe[0]` bị zeroed
- Kết quả: First tap sample không bao giờ được load ở tamn đầu pipeline

### 3.3 Cách Sửa

```verilog
// ❌ SAI (cũ):
x_sub_vec_pipe[0] <= vld_in ? x_sub_vec_in : 0;
// Chỉ load khi vld_in = 1, nhưng cycle 0 vld_in chưa 1

// ✅ ĐÚNG (mới):
x_sub_vec_pipe[0] <= (start || vld_in) ? x_sub_vec_in : 0;
// Load khi start HOẶC khi vld_in
// → Cycle 0 lúc start, ta load ngay first sample
// → Ko bị zeroed bubble
```

**Lý do fix này đúng**:
- `start` được SET ở cycle 0 dung 1 cycle
- Cùng lúc `x_sub_vec_in` (input data) đã được có sẵn từ testbench
- Nên ta có thể prime pipeline bằng first sample ngay lúc `start` mà không chờ `vld_in`
- Kết quả: First output vector không bị trễ

### 3.4 Cách Phát Hiện Sớm: Debug Signals

```verilog
// Thêm vào testbench:

// Signal 1: Monitor x_sub_vec_pipe[0] tại startup
always @(posedge clk) begin
    if (cycle <= 2) begin
        $display("[PRIME] cycle=%d start=%d vld_in=%d x_sub_vec_pipe[0]=%h",
                 cycle, start, vld_in, x_sub_vec_pipe[0]);
        // Nếu x_sub_vec_pipe[0] = 0 ở cycle 0 → lỗi startup bubble!
    end
end

// Signal 2: Check first output vector
always @(posedge clk) begin
    if (output_valid && output_group == 0) begin
        $display("[OUTPUT] vector=%d lane0=%d (expected=%d err=%d)",
                 output_group, output_data[0],
                 golden_data[0],
                 abs($signed(output_data[0]) - $signed(golden_data[0])));
        // Nếu error >> 256 cho vector đầu → startup bubble
    end
end

// Signal 3: Compare pipeline fill pattern
// Verify: taps càng ngày càng đầy, không bị reset/zero
always @(posedge clk) begin
    if (vld_pipe[0]) begin
        $display("[FILL] x_sub_vec_pipe[0]=%h x_sub_vec_pipe[1]=%h x_sub_vec_pipe[2]=%h",
                 x_sub_vec_pipe[0], x_sub_vec_pipe[1], x_sub_vec_pipe[2]);
        // Pattern: cycle 0 có data, cycle 1 data shift vào [1], ...
        // Không được: cycle 0 = 0, rồi data vào cycle 1
    end
end
```

### 3.5 Verification Checklist Cho Lỗi #2

- [ ] Kiểm tra: `x_sub_vec_pipe[0]` load khi `start || vld_in`
- [ ] Chạy xsim với debug signals tại startup (cycle 0-3)
- [ ] Verify: `x_sub_vec_pipe[0]` ≠ 0 ở cycle 0
- [ ] Check: Output vector 0 có error ≤ 256
- [ ] Compare: Vector 0 vs vector 1-15 error behavior (đều phải PASS hoặc đều FAIL)

---

## 4. LỖI #3: STALE DEBUG REGISTERS (Trace Ko Reliable)

### 4.1 Triệu Chứng
- **Debug output**: Trace/snapshot không khớp với expected
- **Vấn đề**: Khi compare `dbg_fetch0` vs expected, lỗi không giải thích được
- **Triệu chứng con**: Các register snapshot từ multiple stages không đồng bộ

### 4.2 Root Cause Chi Tiết

```verilog
// ❌ SAI (cũ):
always @(posedge clk) begin
    // Snapshot lấy từ các register khác nhau ở khác nhau giai đoạn
    dbg_fetch0 <= {st0_x[0][7], st0_x[0][6], ...};  // Stage0 registers
    dbg_mult0 <= {mult_reg[0][7], mult_reg[0][6], ...};  // Stage1 registers
    
    // Vấn đề: st0_x có thể từ cycle N, nhưng mult_reg từ cycle N-2
    // → Khi print cùng nhịp, data ko match (khác timeline)
end

// Ví dụ:
// Cycle 10:
//   dbg_fetch0 = giá trị được fetch ở cycle 10
//   dbg_mult0 = giá trị được multiply ở cycle 10, nhưng operand từ cycle 8!
//   → Khi so sánh, ta thấy "fetch khác mult" nhưng thực ra là từ khác cycle
```

### 4.3 Cách Sửa

```verilog
// ✅ ĐÚNG: Đọc trực tiếp từ source (combinational), không qua register snapshot

// Cách 1: Đọc BRAM word trực tiếp (không qua st0_x register)
wire [TAPS*DATA_WIDTH-1:0] bram_word = bram_mem[addr];  // Direct read
// So sánh bram_word vs expected

// Cách 2: Đọc operand từ multiplier tại Stage1 (combinational)
always @(posedge clk) begin
    if (vld_pipe[1]) begin
        // Instead of: $display("mult=%h", mult_reg[0][0]);
        // Do: Trace operand trực tiếp
        $display("operand st0=%d st1=%d product=%d",
                 $signed(st0_x_pipe[0][0][0]),
                 $signed(st1_x_pipe[0][0][0]),
                 $signed(st0_x_pipe[0][0][0]) * $signed(st1_x_pipe[0][0][0]));
    end
end

// Cách 3: Snapshot với chỉ số tag để match timeline
task capture_snapshot_with_tag;
    integer tick_at_stage;
    begin
        tick_at_stage = tick_cnt_pipe[stage_id];
        // Chỉ capture data từ stage này, sync theo tag
        snap_operand = st0_x_pipe[stage_id];
        snap_tag = tag_pipe[stage_id];
        // So sánh: snap_operand với expect[snap_tag]
    end
endtask
```

### 4.4 Cách Phát Hiện Sớm: Debug Best Practices

```verilog
// ✅ Debug rule #1: Follow single group/tick end-to-end
always @(posedge clk) begin
    // Trace only group=watch_grp, tick=watch_tick
    if (vld_pipe[0] && grp_idx_pipe[0] == WATCH_GRP && tick_cnt_pipe[0] == WATCH_TICK) begin
        $display("[Watch] G%d_T%d_ST0: fetched_addr=%d operand=%h",
                 WATCH_GRP, WATCH_TICK, bram_addr, bram_word);
    end
    if (vld_pipe[1] && grp_idx_pipe[1] == WATCH_GRP && tick_cnt_pipe[1] == WATCH_TICK) begin
        $display("[Watch] G%d_T%d_ST1: mult=%h * %h = %h",
                 WATCH_GRP, WATCH_TICK, st0_x_pipe[0][0][0], st1_x_pipe[0][0][0],
                 st0_x_pipe[0][0][0] * st1_x_pipe[0][0][0]);
    end
    // ...continue for ST2, ST3, ST6
end

// ✅ Debug rule #2: Assert invariants tại mỗi stage
always @(posedge clk) begin
    if (vld_pipe[1]) begin
        // Invariant: operand không được là cũ hơn 2 cycle
        int tick_diff = (tick_cnt_pipe[1] - expected_tick_at_stage1) % 8;
        assert(tick_diff == 0 || tick_diff == 1) 
            else $error("[ASSERT] Tick mismatch at ST1: diff=%d", tick_diff);
    end
end

// ✅ Debug rule #3: Print state machine transitions
initial begin
    $monitor("[%0t] cycle=%d vld_pipe=[%b,%b,%b,%b] tag_pipe=[%d,%d,%d,%d]",
             $time, cycle, 
             vld_pipe[0], vld_pipe[1], vld_pipe[2], vld_pipe[3],
             tag_pipe[0], tag_pipe[1], tag_pipe[2], tag_pipe[3]);
end
```

### 4.5 Verification Checklist Cho Lỗi #3

- [ ] Trace của debug signal phải đi từ source (BRAM, combinational) không qua stale register
- [ ] Mỗi stage trace phải có control tag cùng với dữ liệu
- [ ] Follow single group trace: in ra G#_T# pattern để dễ verify
- [ ] Assert: tick/group tag khớp với dữ liệu ở mỗi stage

---

## 5. TEMPLATE: CHECKLIST THIẾT KẾ STREAMING MODULE MỚI

Khi chuyển đổi khối combinational sang streaming:

### 5.1 Pre-Design Phase

```
[ ] 1. Xác định Total Latency (tất cả stage) = N cycle
    - BRAM latency
    - Computation latency (multiply, add tree, ...)
    - Output buffer latency
    
[ ] 2. Xác định Control Tag Pipeline depth
    - Tag phải đi song song với dữ liệu
    - Độ sâu phải = Data Latency (không được nhiều/ít hơn)
    - Mỗi stage, tag phải được push/pop đúng lúc
    
[ ] 3. Xác định Input Priming Strategy
    - Có start signal riêng?
    - First data được load khi nào (start, hay vld_in đầu)?
    - Có zero padding bubble? (check lỗi #2)
    
[ ] 4. List tất cả pipeline register layers
    - stage0_pipe[0:PD] ← direct load từ fetch (rule: không qua intermediate register)
    - stage1_pipe[0:PD] ← consume từ stage0_pipe[0], không [1]
    - ...
```

### 5.2 Design Phase (RTL Code)

```verilog
// Rule 1: Direct load, không delay
always @(posedge clk) begin
    if (fetch_enable) begin
        // ✅ Direct load vào pipe[0]
        operand_pipe[0] <= fetched_value;
    end
end

// Rule 2: Shift trong vòng lặp nested
for (stage=1; stage<=PD; stage=stage+1) begin
    always @(posedge clk) begin
        operand_pipe[stage] <= operand_pipe[stage-1];
    end
end

// Rule 3: Consume từ pipe[0] + 1 cycle latency = đáp ứng current tag
always @(posedge clk) begin
    if (compute_enable) begin
        // ✅ Consume từ pipe[0] (mới nhất)
        product <= operand_pipe[0] * operand_pipe[0];  // NOT pipe[1]!
    end
end

// Rule 4: Tag pipeline đi cùng
always @(posedge clk) begin
    tag_pipe[0] <= fetch_tag;
    for (i=1; i<=PD; i=i+1)
        tag_pipe[i] <= tag_pipe[i-1];
end

// Rule 5: Input priming on START
always @(posedge clk) begin
    if (start || valid_in) begin  // Include START!
        input_pipe[0] <= input_data;
    end
end
```

### 5.3 Simulation/Debug Phase

```verilog
// Monitor Rule 1: Direct BRAM/source reads, not stale register
wire [DATA_WIDTH-1:0] direct_fetch = bram_mem[fetch_addr];
always @(posedge clk) begin
    if (fetch_en) begin
        $display("[FETCH] addr=%d direct=%d operand_pipe[0]=%d match=%d",
                 fetch_addr, direct_fetch, operand_pipe[0],
                 direct_fetch == operand_pipe[0]);
    end
end

// Monitor Rule 2: Follow single item end-to-end
parameter WATCH_ID = 0;
always @(posedge clk) begin
    if (item_id == WATCH_ID && stage == 0) 
        $display("[WATCH] ID%d_S0: data=%d tag=%d", WATCH_ID, data, tag);
    if (item_id == WATCH_ID && stage == 1)
        $display("[WATCH] ID%d_S1: data=%d tag=%d", WATCH_ID, data, tag);
    // ... for each stage
end

// Monitor Rule 3: Check tag-data sync
always @(posedge clk) begin
    for (s=0; s<PD; s=s+1) begin
        if (tag_valid[s] && operand_tag[s] != expected_tag[item_index[s]]) begin
            $error("[TAG_MISMATCH] Stage%d: operand_tag=%d expected=%d",
                   s, operand_tag[s], expected_tag[item_index[s]]);
        end
    end
end

// Monitor Rule 4: Startup behavior
initial begin
    repeat(5) @(posedge clk);
    for (i=0; i<3; i=i+1) begin
        $display("[STARTUP] cycle=%d input_pipe[0]=%d (before=%d after=%d)",
                 i, input_pipe[0], input_pipe[1], input_pipe[2]);
        @(posedge clk);
    end
end
```

### 5.4 Verification Phase

```
Test Case 1: Single Item Trace
[ ] Load 1 sample, trace từ input → output
[ ] Verify: output timing = input_timing + latency
[ ] Verify: output value ≈ golden (within quantization)

Test Case 2: Continuous Stream
[ ] Load 8-16 samples continuously
[ ] Verify: No stalls, output every cycle after ramp-up
[ ] Verify: All outputs match golden

Test Case 3: Edge Cases
[ ] Check: Startup (first output vector)
[ ] Check: Underflow (vld_in becomes 0 mid-stream)
[ ] Check: Reset transition

Test Case 4: Latency Verification
[ ] Measure: Input valid → output valid delay
[ ] Compare: Expected latency = measured latency
[ ] Verify: No extra cycle introduced by new stage

Post-Tape-Out (antes submit RTL):
[ ] Remove debug prints, keep only error assertions
[ ] Document: Final latency, pipeline depth, control signals
[ ] Create: Streaming checklist document (like this)
```

---

## 6. DEBUG SIGNAL MONITORING FRAMEWORK

### 6.1 Essential Signals Mỗi Streaming Module Phải Có

```verilog
// Category 1: Control Signals (state machine)
output reg                    stage_valid;      // Data valid at stage
output reg [TAG_WIDTH-1:0]    stage_tag;        // Item ID / group / tick
output reg [ADDR_WIDTH-1:0]   stage_addr;       // Address for matching

// Category 2: Data Signals (pipeline operands)
output wire [DATA_WIDTH-1:0]  fetch_operand;    // Direct from source
output wire [DATA_WIDTH-1:0]  compute_operand;  // At compute stage
output wire [RESULT_WIDTH-1:0] compute_result;  // Combinational result

// Category 3: Pipeline Depth Signals (verify alignment)
output wire [DATA_WIDTH-1:0]  pipe0_operand;    // Fresh
output wire [DATA_WIDTH-1:0]  pipe1_operand;    // 1-cycle old
output wire [2:0]             pipe_fill_level;  // How full is pipeline

// Category 4: Assertion Checks (runtime errors)
always @(posedge clk) begin
    // CHECK 1: operand tag sync
    if (stage_valid)
        assert(stage_tag_at_compute == expected_tag)
            else $error("Tag mismatch at compute");
    
    // CHECK 2: No zero padding mid-stream
    if (stage_valid && !is_startup)
        assert(stage_operand != 0)
            else $error("Zero padding detected");
    
    // CHECK 3: Latency consistency
    if (input_valid && last_input_id == current_item_id)
        assert(output_cycles_after_input == EXPECTED_LATENCY)
            else $error("Latency %d != expected %d",
                       output_cycles_after_input, EXPECTED_LATENCY);
end
```

### 6.2 Testbench Structure

```python
# Python testbench helper

class StreamingTestbench:
    def __init__(self, module_name, latency):
        self.module = module_name
        self.latency = latency
        self.input_stream = []
        self.golden_output = []
        self.rtl_output = []
        
    def load_golden(self, filename):
        # Load expected output from Python model
        pass
    
    def monitor_single_item(self, item_id):
        # Trace item_id through all stages
        # Return: (input_time, output_time, latency)
        pass
    
    def verify_latency(self):
        # Check: output_time - input_time == self.latency ± 0
        pass
    
    def verify_continuous_stream(self):
        # Check: No stalls, output ready every cycle after ramp
        pass
    
    def verify_values(self, error_threshold=256):
        for i, (rtl, golden) in enumerate(zip(self.rtl_output, self.golden_output)):
            err = abs(rtl - golden)
            if err > error_threshold:
                print(f"Value mismatch at index {i}: RTL={rtl} golden={golden}")
                return False
        return True
```

---

## 7. QUICK DECISION TREE: Debugging Streaming Issues

```
START: Streaming module outputs wrong values
│
├─ Error pattern: First output vector ONLY bad?
│  └─ YES → LỖI #2: Startup Bubble
│     └─ Check: x_sub_vec_pipe[0] <= (start || vld_in) ? ...
│
├─ Error pattern: Random lanes, errors 600-1000?
│  └─ YES → LỖI #1: Data-to-Tag Misalignment
│     ├─ Check 1: pipe[0] direct load từ fetch?
│     ├─ Check 2: Stage1 consume từ pipe[0]?
│     └─ Action: Trace single group end-to-end
│
├─ Error pattern: Trace/debug không khớp golden?
│  └─ YES → LỖI #3: Stale Debug Registers
│     ├─ Check: Dùng direct BRAM read, không snapshot?
│     ├─ Check: Tag có đi cùng?
│     └─ Action: Follow single item G#_T# format
│
└─ Đã kiểm tra hết 3 lỗi trên nhưng vẫn sai?
   └─ Possible: Lỗi khác (logic compute sai, weight SAI, ...)
      └─ Action: Trace 1 sample từ input → output, compare từng intermediate
```

---

## 8. TIMELINE: Từ Combinational Sang Streaming (Avoid Naive Mistakes)

### Phase 1: Architecture Design (1 ngày)
- [x] Tính latency tất cả stage
- [x] Vẽ pipeline diagram (stage, latency, tag)
- [x] List tất cả registers cần (pipe[0:PD], tag_pipe[0:PD])
- [x] Check: Rule 1-5 compliant?

### Phase 2: RTL Coding (2-3 ngày)
- [x] Code stage0 fetch: Direct load pipe[0]
- [x] Code shifter: Loop shift pipe[1:PD]
- [x] Code stage1+ compute: Consume pipe[0]
- [x] Code tag pipeline: Parallel shift
- [x] Code input priming: Include `start`
- [x] Add debug signals từ Section 6.1

### Phase 3: Simulation - Unit Test (1-2 ngày)
- [x] Test case 1: Single item (watch_id=0)
- [x] Test case 2: Continuous 8-16 items
- [x] Test case 3: Startup behavior
- [x] Monitor: Debug signals + assertions tại mỗi stage
- **If Fail**: → Jump đến Decision Tree (Section 7)

### Phase 4: Integration Test (0.5-1 ngày)
- [x] Connect to next stage
- [x] Verify: Latency từ input → final output
- [x] Verify: All streams in/out working

### Phase 5: Cleanup (0.5 ngày)
- [x] Remove debug prints (keep assertions)
- [x] Document: Final latency, control signals, exceptions
- [x] Commit: RTL + testbench + golden reference

**Total: 5-8 ngày** (vs 12+ ngày nếu debug continual như trước)

---

## 9. CHECKLIST CHECKLIST: Trước Khi Submit RTL Streaming Module

```
PRE-SUBMIT CHECKLIST:

Design
[ ] Latency diagram (ASCII vẽ input → output timeline)
[ ] Pipeline depth = data latency + 1? (tag thep)
[ ] Input priming: start signal included?

Code Review
[ ] pipe[0] direct load (Rule 1)?
[ ] Shift loop toàn bộ pipe[1:PD] (Rule 2)?
[ ] Compute consume pipe[0], không pipe[1] (Rule 3)?
[ ] Tag pipeline shift cùng dữ liệu (Rule 4)?
[ ] Input prime khi (start || valid) (Rule 5)?

Debug Signals (Section 6.1)
[ ] fetch_operand (direct source)
[ ] compute_operand (at compute stage)
[ ] pipe0_operand, pipe1_operand (verify alignment)
[ ] stage_tag (control signal)
[ ] Assertions: tag sync, no-zero, latency consistent?

Test Coverage
[ ] Single item trace (watch_id)
[ ] Continuous stream (8+ items)
[ ] Startup (first item)
[ ] Underflow (vld drops)
[ ] Value verify: max_error ≤ 256?
[ ] Latency verify: measured = expected?

Documentation
[ ] README: Latency, control signals, states
[ ] Streaming design notes (like this file)
[ ] Debug signal mapping
[ ] Known issues (if any)

Final
[ ] xvlog: No syntax errors
[ ] xelab: Link OK
[ ] xsim: All assertions pass
[ ] Golden compare: 0 mismatches
```

---

## 10. QUICK REFERENCE: From This Project

### In_Projection_Unit_Streaming_v2 Metrics
- **Final Status**: PASS (0/256 mismatches)
- **Latency**: 7 cycles (BRAM 1 + fetch 2 + multiply 1 + adder 1 + accum 1 + saturate 1)
- **Errors Fixed**: 3 (lỗi #1, #2, #3)
- **Time to Debug**: 3-4 ngày (nếu follow guide này, có thể giảm xuống 1-2 ngày)

### Key Learnings
1. **Streaming ≠ just add delay** → Phải carefully manage data-to-tag alignment
2. **Startup matters** → Input prime khác với continuous vld
3. **Debug register snapshots unreliable** → Dùng direct BRAM/combinational reads
4. **Single item trace is best friend** → Follow watch_id end-to-end
5. **Assertions > manual inspection** → Auto-check tại mỗi stage

---

## Appendix: Common Pitfalls & How to Avoid

| Pitfall | Symptom | Fix |
|---------|---------|-----|
| Forget direct load pipe[0] | Random errors, 112+ mismatch | Add direct load in fetch block |
| Consume from pipe[1] instead of pipe[0] | Tag-operand lag | Change multiply to use pipe[0] |
| Forget `start` in input prime | First vector wrong | Change `vld_in` to `(start \|\| vld_in)` |
| Use stale register for debug | Trace doesn't match expected | Read from BRAM direct, not snapshot |
| Wrong tag_latency value | All outputs shifted by N | Re-calculate based on actual datapath |
| No assertions in RTL | Bugs slip through | Add `assert(tag_match)` at compute |
| Skip single-item trace | Diagnose wrong error | Always trace watch_id through all stages |

