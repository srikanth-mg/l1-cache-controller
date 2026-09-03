#!/bin/bash
# ============================================================
# ASAP7 (7nm) synthesis + STA + Fmax sweep for cache_top
# Usage: ./run_asap7.sh (from syn/ directory)
# ============================================================

set -e

LIB_DIR="asap7_libs"
LIB_AO="${LIB_DIR}/asap7sc7p5t_AO_RVT_TT_nldm_211120.lib"
LIB_INVBUF="${LIB_DIR}/asap7sc7p5t_INVBUF_RVT_TT_nldm_220122.lib"
LIB_OA="${LIB_DIR}/asap7sc7p5t_OA_RVT_TT_nldm_211120.lib"
LIB_SEQ="${LIB_DIR}/asap7sc7p5t_SEQ_RVT_TT_nldm_220123.lib"
LIB_SIMPLE="${LIB_DIR}/asap7sc7p5t_SIMPLE_RVT_TT_nldm_211120.lib"

mkdir -p netlists reports

# ── Sanity check ──
for LIB in "$LIB_AO" "$LIB_INVBUF" "$LIB_OA" "$LIB_SEQ" "$LIB_SIMPLE"; do
    if [ ! -f "$LIB" ]; then
        echo "ERROR: Missing $LIB"
        exit 1
    fi
done
echo "═══ All 5 ASAP7 libs found ═══"

# ── Step 1: Generate Yosys script ──
cat > synth_asap7.ys << EOF
# Yosys synthesis — cache_top → ASAP7 7nm (RVT, TT corner)
read_verilog -sv cache_top_flat.sv
hierarchy -top cache_top
proc
flatten
opt -full
fsm
opt
memory
opt
techmap
dfflibmap -liberty ${LIB_SEQ}
abc -liberty ${LIB_INVBUF} -liberty ${LIB_SIMPLE} -liberty ${LIB_AO} -liberty ${LIB_OA} -liberty ${LIB_SEQ}
opt_clean -purge
stat -liberty ${LIB_SIMPLE}
tee -o reports/area_asap7.rpt stat -liberty ${LIB_SIMPLE}
write_verilog -noattr netlists/cache_top_asap7.v
EOF

# ── Step 2: Run Yosys ──
echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Running Yosys synthesis — ASAP7 7nm"
echo "═══════════════════════════════════════════════════════"
yosys synth_asap7.ys

# ── Step 3: Generate STA script ──
cat > sta_asap7.tcl << EOF
set CLK_PERIOD 2.0

read_liberty ${LIB_AO}
read_liberty ${LIB_INVBUF}
read_liberty ${LIB_OA}
read_liberty ${LIB_SEQ}
read_liberty ${LIB_SIMPLE}

read_verilog netlists/cache_top_asap7.v
link_design cache_top

create_clock -name clk -period \$CLK_PERIOD [get_ports clk]
set_clock_uncertainty 0.02 [get_clocks clk]
set_clock_transition 0.01 [get_clocks clk]

set all_inputs_except_clk {}
foreach p [all_inputs] {
    set pname [get_property \$p name]
    if {\$pname ne "clk"} {
        lappend all_inputs_except_clk \$p
    }
}

set_input_delay  0.2 -clock clk \$all_inputs_except_clk
set_output_delay 0.2 -clock clk [all_outputs]
set_input_transition 0.01 \$all_inputs_except_clk
set_load -pin_load 0.001 [all_outputs]

puts "\\n══════════════════════════════════════════"
puts "  SETUP TIMING @ [expr {1000.0 / \$CLK_PERIOD}] MHz"
puts "══════════════════════════════════════════"
report_checks -path_delay max -sort_by_slack -fields {slew cap input_pins nets} \\
  -format full_clock_expanded -digits 3

puts "\\n══════════════════════════════════════════"
puts "  HOLD TIMING"
puts "══════════════════════════════════════════"
report_checks -path_delay min -sort_by_slack -fields {slew cap input_pins nets} \\
  -format full_clock_expanded -digits 3

puts "\\n══════════════════════════════════════════"
puts "  DESIGN SUMMARY @ [expr {1000.0 / \$CLK_PERIOD}] MHz"
puts "══════════════════════════════════════════"
report_tns
report_wns

exit
EOF

# ── Step 4: Run STA at 500 MHz baseline ──
echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Running OpenSTA — ASAP7 7nm (500 MHz baseline)"
echo "═══════════════════════════════════════════════════════"
sta sta_asap7.tcl

# ── Step 5: Fmax sweep ──
echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Fmax SWEEP — ASAP7 7nm cache_top"
echo "═══════════════════════════════════════════════════════"
echo ""
PERIODS="2.0 1.5 1.2 1.0 0.9 0.8 0.7 0.6 0.5"

printf "%-12s %-12s %-15s %-10s\n" "Period(ns)" "Freq(MHz)" "Setup Slack" "Result"
echo "───────────────────────────────────────────────────────"

for P in $PERIODS; do
    FREQ=$(echo "scale=1; 1000.0 / $P" | bc)
    sed -i "s/^set CLK_PERIOD .*/set CLK_PERIOD $P/" sta_asap7.tcl
    OUTPUT=$(sta sta_asap7.tcl 2>&1)
    WNS=$(echo "$OUTPUT" | grep "wns" | awk '{print $NF}')

    if (( $(echo "$WNS >= 0" | bc -l) )); then
        RESULT="PASS"
    else
        RESULT="FAIL ✗"
    fi
    printf "%-12s %-12s %-15s %-10s\n" "${P}" "${FREQ}" "${WNS}" "${RESULT}"
done

echo "───────────────────────────────────────────────────────"
echo ""
echo "Fmax = last PASS frequency"
echo "═══════════════════════════════════════════════════════"
