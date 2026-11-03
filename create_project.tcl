# create_project.tcl - builds the Vivado project in one step.
#   In Vivado's Tcl console:  cd <this folder>  then  source create_project.tcl
set part     xc7a100tcsg324-1    ;# Nexys A7-100T. For the A7-50T use xc7a50tcsg324-1
set run_flow 0                   ;# 1 = also run synthesis, implementation and bitstream

set script_dir [file dirname [file normalize [info script]]]
set proj_name  fpga_udp_eth
set proj_dir   [file join $script_dir vivado_project]

create_project $proj_name $proj_dir -part $part -force
set_property target_language Verilog [current_project]

add_files -norecurse -fileset sources_1 [glob [file join $script_dir rtl *.v]]
set_property top top [get_filesets sources_1]
add_files -norecurse -fileset constrs_1 [file join $script_dir constraints nexys_a7_eth.xdc]

# simulation: testbench + test vectors (absolute path passed to the testbench)
add_files -norecurse -fileset sim_1 [file join $script_dir tb tb_eth.v]
set_property top tb_eth [get_filesets sim_1]
set vec [file join $script_dir tb vectors vectors.txt]
set_property -name {xsim.simulate.xsim.more_options} -value "-testplusarg vec=$vec" -objects [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {-all} -objects [get_filesets sim_1]

update_compile_order -fileset sources_1
puts "Project created: [file join $proj_dir ${proj_name}.xpr]"
if {$run_flow} {
    launch_runs synth_1 -jobs 4; wait_on_run synth_1
    launch_runs impl_1 -to_step write_bitstream -jobs 4; wait_on_run impl_1
}
