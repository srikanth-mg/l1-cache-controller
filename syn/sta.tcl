# ============================================================
# OpenSTA timing analysis — cache_top on Skywater 130nm
# ============================================================
# Usage:
#   sta sta.tcl
#
# To sweep Fmax, change CLK_PERIOD below and re-run.
# ============================================================

# ── Clock period (change this for Fmax sweep) ──
set CLK_PERIOD 6.0

# ── Read liberty ──
read_liberty sky130_fd_sc_hd__tt_025C_1v80.lib

# ── Read gate-level netlist ──
read_verilog netlists/cache_top_sky130.v
link_design cache_top

# ── Clock definition ──
create_clock -name clk -period $CLK_PERIOD [get_ports clk]
set_clock_uncertainty 0.2 [get_clocks clk]
set_clock_transition 0.1 [get_clocks clk]

# ── Input/output constraints ──
# FIX: use foreach to reliably skip the clock port
set all_inputs_except_clk {}
foreach p [all_inputs] {
    set pname [get_property $p name]
    if {$pname ne "clk"} {
        lappend all_inputs_except_clk $p
    }
}

set_input_delay  2.0 -clock clk $all_inputs_except_clk
set_output_delay 2.0 -clock clk [all_outputs]

set_input_transition 0.1 $all_inputs_except_clk
set_load -pin_load 0.01 [all_outputs]

# ── Timing reports ──
puts "\n══════════════════════════════════════════"
puts "  SETUP TIMING (worst paths) @ [expr {1000.0 / $CLK_PERIOD}] MHz"
puts "══════════════════════════════════════════"
report_checks -path_delay max -sort_by_slack -fields {slew cap input_pins nets} \
  -format full_clock_expanded -digits 3

puts "\n══════════════════════════════════════════"
puts "  HOLD TIMING (worst paths)"
puts "══════════════════════════════════════════"
report_checks -path_delay min -sort_by_slack -fields {slew cap input_pins nets} \
  -format full_clock_expanded -digits 3

puts "\n══════════════════════════════════════════"
puts "  DESIGN SUMMARY @ [expr {1000.0 / $CLK_PERIOD}] MHz"
puts "══════════════════════════════════════════"
report_tns
report_wns

# ── Write reports to files ──
report_checks -path_delay max -sort_by_slack -digits 3 > reports/setup_timing.rpt
report_checks -path_delay min -sort_by_slack -digits 3 > reports/hold_timing.rpt

puts "\n  Reports written to reports/"
puts "  Clock period: ${CLK_PERIOD} ns ([expr {1000.0 / $CLK_PERIOD}] MHz)"
puts "══════════════════════════════════════════"

exit
