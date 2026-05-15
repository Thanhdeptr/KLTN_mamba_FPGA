// Helper display macros for tracing x_sub_vec_pipe and st1_x
`define DISP_XPIPE(idx) \
    $display("XPIPE[%0d] = %h %h %h %h %h %h %h %h", idx, \
             dut.x_sub_vec_pipe[idx][0*DATA_WIDTH +: DATA_WIDTH], dut.x_sub_vec_pipe[idx][1*DATA_WIDTH +: DATA_WIDTH], \
             dut.x_sub_vec_pipe[idx][2*DATA_WIDTH +: DATA_WIDTH], dut.x_sub_vec_pipe[idx][3*DATA_WIDTH +: DATA_WIDTH], \
             dut.x_sub_vec_pipe[idx][4*DATA_WIDTH +: DATA_WIDTH], dut.x_sub_vec_pipe[idx][5*DATA_WIDTH +: DATA_WIDTH], \
             dut.x_sub_vec_pipe[idx][6*DATA_WIDTH +: DATA_WIDTH], dut.x_sub_vec_pipe[idx][7*DATA_WIDTH +: DATA_WIDTH])

`define DISP_ST1X(pipe_idx,lane) \
    $display("ST1X pipe=%0d lane=%0d t0..7 = %0d %0d %0d %0d %0d %0d %0d %0d", pipe_idx, lane, \
             dut.st1_x_pipe[pipe_idx][lane][0], dut.st1_x_pipe[pipe_idx][lane][1], dut.st1_x_pipe[pipe_idx][lane][2], dut.st1_x_pipe[pipe_idx][lane][3], \
             dut.st1_x_pipe[pipe_idx][lane][4], dut.st1_x_pipe[pipe_idx][lane][5], dut.st1_x_pipe[pipe_idx][lane][6], dut.st1_x_pipe[pipe_idx][lane][7])
