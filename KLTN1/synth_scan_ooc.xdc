create_clock -period 10.000 -name clk [get_ports clk]
set_input_delay 0 [get_ports {rst_n en clear_h beat_valid beat_path_x beat_grp beat_token beat_vec*}]
set_output_delay 0 [get_ports {busy scan_valid scan_token scan_grp y_out_vec*}]
set_false_path -from [get_ports rst_n]
