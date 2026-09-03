set CLK_PERIOD 0.5

read_liberty asap7_libs/asap7_merged_RVT_TT.lib

read_verilog netlists/cache_top_asap7.v
link_design cache_top

create_clock -name clk -period $CLK_PERIOD [get_ports clk]
set_clock_uncertainty 0.02 [get_clocks clk]
set_clock_transition 0.01 [get_clocks clk]

set all_inputs_except_clk {}
foreach p [all_inputs] {
    set pname [get_property $p name]
    if {$pname ne "clk"} {
        lappend all_inputs_except_clk $p
    }
}

set_input_delay  0.2 -clock clk $all_inputs_except_clk
set_output_delay 0.2 -clock clk [all_outputs]
set_input_transition 0.01 $all_inputs_except_clk
set_load -pin_load 0.001 [all_outputs]

puts "\n══════════════════════════════════════════"
puts "  SETUP TIMING @ [expr {1000.0 / $CLK_PERIOD}] MHz"
puts "══════════════════════════════════════════"
report_checks -path_delay max -sort_by_slack -fields {slew cap input_pins nets} \
  -format full_clock_expanded -digits 3

puts "\n══════════════════════════════════════════"
puts "  HOLD TIMING"
puts "══════════════════════════════════════════"
report_checks -path_delay min -sort_by_slack -fields {slew cap input_pins nets} \
  -format full_clock_expanded -digits 3

puts "\n══════════════════════════════════════════"
puts "  DESIGN SUMMARY @ [expr {1000.0 / $CLK_PERIOD}] MHz"
puts "══════════════════════════════════════════"
report_tns
report_wns

exit
