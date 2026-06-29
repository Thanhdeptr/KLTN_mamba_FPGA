// Shared absolute paths for InProjection testbenches (Vivado / xsim).
// Override via compile define, e.g.:
//   -define INPROJ_TEST_ROOT=\"/path/to/test_In_Projection_Unit\"
//   -define INPROJ_VECTORS_DIR=\"/path/to/test_Inprojection\"

`ifndef INPROJ_TEST_ROOT
  `define INPROJ_TEST_ROOT "/home/hatthanh/schoolwork/KLTN/RTL/code_AI_gen/test_In_Projection_Unit"
`endif

`ifndef INPROJ_VECTORS_DIR
  `define INPROJ_VECTORS_DIR "/home/hatthanh/schoolwork/KLTN/RTL/testbench/test_Inprojection"
`endif
