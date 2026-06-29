# Generic OOC clock for KV260 (xck26) block synth.
# Input/output delays omitted here (applied in synth Tcl when needed).

create_clock -period 10.000 -name sys_clk [get_ports clk]
set_clock_uncertainty -setup 0.200 [get_clocks sys_clk]
set_false_path -from [get_ports rst_n]
