#!/bin/bash
# ============================================================
# Fmax sweep — runs OpenSTA at multiple clock periods
# Usage: ./sweep_fmax.sh
# ============================================================

PERIODS="10.0 8.0 7.5 7.2 7.0 6.5 6.0"

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Fmax SWEEP — Sky130 cache_top"
echo "═══════════════════════════════════════════════════════"
echo ""
printf "%-12s %-12s %-15s %-10s\n" "Period(ns)" "Freq(MHz)" "Setup Slack" "Result"
echo "───────────────────────────────────────────────────────"

for P in $PERIODS; do
    FREQ=$(echo "scale=1; 1000.0 / $P" | bc)

    # Patch the clock period into sta.tcl
    sed -i "s/^set CLK_PERIOD .*/set CLK_PERIOD $P/" sta.tcl

    # Run OpenSTA, capture output
    OUTPUT=$(sta sta.tcl 2>&1)

    # Extract worst setup slack (WNS line)
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
echo ""
