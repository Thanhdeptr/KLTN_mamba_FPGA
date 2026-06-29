# OOC constraints for RMSNorm_Unit_IntSqrt

create_clock -period 8.000 -name sys_clk [get_ports clk]
set_clock_uncertainty -setup 0.200 [get_clocks sys_clk]

set data_inputs [get_ports -filter {DIRECTION == IN && NAME != clk}]
set_input_delay  -clock sys_clk -max 2.0 $data_inputs
set_input_delay  -clock sys_clk -min 0.5 $data_inputs
set_output_delay -clock sys_clk -max 2.0 [all_outputs]
set_output_delay -clock sys_clk -min 0.5 [all_outputs]
