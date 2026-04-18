#!/usr/bin/env python3
"""
Debug script: extract Scan FSM state transitions and Exp latency from VCD waveform
"""
import subprocess
import re
from pathlib import Path

# Generate limited-token simulation with waveform dump
print("=" * 80)
print("Running simulation with waveform dump for latency analysis...")
print("=" * 80)

# Create simple TCL to generate VCD
tcl_content = """
set design tb_mamba_fullbranch_chain_sim
set vcd_file [file normalize debug_scan_latency.vcd]

open_wave_config {}
add_wave /tb_mamba_fullbranch_chain/mamba_wrapper_inst/scan_core_inst/state
add_wave /tb_mamba_fullbranch_chain/mamba_wrapper_inst/scan_core_inst/exp_in_reg
add_wave /tb_mamba_fullbranch_chain/mamba_wrapper_inst/scan_core_inst/exp_out
add_wave /tb_mamba_fullbranch_chain/mamba_wrapper_inst/scan_core_inst/discA_stored
add_wave /tb_mamba_fullbranch_chain/mamba_wrapper_inst/scan_core_inst/deltaBx_stored
set_param xilinx.wdb.MaskBitCount 4

write_vcd $vcd_file -scope /tb_mamba_fullbranch_chain -max_samples 100000
"""

with open("/tmp/dump_vcd.tcl", "w") as f:
    f.write(tcl_content)

# Run simulation with VCD dump
cmd = (
    "cd /home/hatthanh/schoolwork/KLTN/RTL/code_AI_gen/test_Mamba_FullBranch_Chain && "
    "python3 prepare_mem.py >/dev/null 2>&1 && "
    "timeout 60 xsim tb_mamba_fullbranch_chain_sim -testplusarg TOKENS=1 -testplusarg TRACE=0 "
    "-runall -vcd debug_scan_latency.vcd 2>&1"
)
result = subprocess.run(["bash", "-lc", cmd], capture_output=True, text=True, timeout=90)
print("Simulation output (last 20 lines):")
print("\n".join(result.stdout.splitlines()[-20:]))

# Parse VCD to extract state transitions
print("\n" + "=" * 80)
print("Analyzing VCD waveform...")
print("=" * 80)

vcd_path = Path("/home/hatthanh/schoolwork/KLTN/RTL/code_AI_gen/test_Mamba_FullBranch_Chain/debug_scan_latency.vcd")
if vcd_path.exists():
    print(f"✓ VCD file created: {vcd_path}")
    print("  Open with: gtkwave debug_scan_latency.vcd &")
    print("\nKey signals to observe:")
    print("  1. state: FSM state transitions (should show S_STEP1→S_STEP2→...→S_STEP5→...)")
    print("  2. exp_in_reg[*]: Input to Exp_Unit (loaded in S_STEP2)")
    print("  3. exp_out[*]: Output from Exp_Unit (should stabilize 2 cycles after exp_in_reg)")
    print("  4. discA_stored[*]: When does it capture exp_out? (Should be at S_STEP4 END)")
    print("\nExpected latency sequence:")
    print("  Cycle N (S_STEP2 end): exp_in_reg <= pe_result")
    print("  Cycle N+1 (S_STEP3 end): exp_in_reg valid, Exp_Unit.in_data_r <= exp_in")
    print("  Cycle N+2 (S_STEP4 end): exp_out should be ready NOW (2 cycles after N)")
    print("  Cycle N+3 (S_STEP5 end): discA_stored captures exp_out")
    print("\nIf exp_out ready at Cycle N+2 but discA_stored reads at Cycle N+3,")
    print("we're reading one cycle TOO EARLY → stale exp_out value!")
else:
    print("✗ VCD file NOT created - check xsim output above")

print("\n" + "=" * 80)
print("MANUAL LATENCY CHECK (from source code):")
print("=" * 80)

# Read and analyze Scan_Core_Engine.v
scan_file = Path("/home/hatthanh/schoolwork/KLTN/RTL/code_initial/Scan_Core_Engine.v")
scan_code = scan_file.read_text()

# Extract FSM state names
states_match = re.findall(r'localparam.*?(S_STEP\d+|S_IDLE)\s*=\s*(\d+)', scan_code)
states = {name: int(val) for name, val in states_match}
print(f"FSM states: {sorted(states.items(), key=lambda x: x[1])}\n")

# Extract Exp_Unit latency
exp_file = Path("/home/hatthanh/schoolwork/KLTN/RTL/code_initial/Exp_Unit.v")
exp_code = exp_file.read_text()
exp_cycles = exp_code.count("always @(posedge clk)") + 1  # +1 for PWL pipeline
print(f"Exp_Unit pipeline stages: {exp_cycles} cycles")
print(f"  - Exp_Unit.in_data_r: 1 cycle")
print(f"  - Exp_Unit_PWL calc+register: 1 cycle")
print(f"  Total: 2 cycles latency from input available → output ready\n")

# Current FSM sequence
print("Current FSM timing from exp_in_reg load:")
print("  S_STEP2 end (Cycle C):   exp_in_reg <= pe_result (becomes valid combinatorially immediately)")
print("  S_STEP3 end (Cycle C+1): Exp_Unit.in_data_r <= exp_in (1st pipeline stage)")
print("  S_STEP4 end (Cycle C+2): ⚠️  discA_stored <= exp_out  ← READING HERE")
print("                    But exp_out updated AT Cycle C+2! (2-cycle latency means:")
print("                    Cycle C: input available")
print("                    Cycle C+1: Exp_Unit.in_data_r loads")
print("                    Cycle C+2: exp_out updates (at posedge, register write)")
print("                    So discA_stored gets exp_out value written at C+2")
print("\n⚠️  RISK: Synchronous read-after-write on same cycle!")
print("   Depending on synthesis/timing, this could read STALE value!\n")

print("RECOMMENDATION:")
print("  Add state S_STEP3W (or rename S_STEP3→S_STEP3W) to insert 1 more wait")
print("  Then S_STEP4 reads exp_out at Cycle C+3 (guarantees fresh value)\n")

