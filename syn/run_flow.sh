#!/bin/bash
# ============================================================
# Full synthesis + STA flow for cache_top
# Run from the syn/ directory
# ============================================================
set -e

LIB_FILE="sky130_fd_sc_hd__tt_025C_1v80.lib"
LIB_URL="https://raw.githubusercontent.com/google/skywater-pdk-libs-sky130_fd_sc_hd/main/timing/${LIB_FILE}"

# ── Step 0: Check tools ──
echo "══════ Checking tools ══════"
for tool in yosys sta; do
  if ! command -v $tool &>/dev/null; then
    echo "ERROR: '$tool' not found. Install it first."
    exit 1
  fi
done
echo "  yosys: $(yosys -V 2>&1 | head -1)"
echo "  sta:   $(sta -version 2>&1 | head -1 || echo 'ok')"

# ── Step 1: Download liberty file ──
if [ ! -f "$LIB_FILE" ]; then
  echo ""
  echo "══════ Downloading Skywater 130nm liberty ══════"
  wget -q --show-progress "$LIB_URL" -O "$LIB_FILE"
  echo "  Downloaded $LIB_FILE"
else
  echo "  Liberty file already present."
fi

# ── Step 2: Create output dirs ──
mkdir -p reports netlists

# ── Step 3: Yosys synthesis ──
echo ""
echo "══════ Running Yosys synthesis ══════"
yosys synth_sky130.ys 2>&1 | tee reports/yosys_log.txt | tail -25
echo "  Netlist: netlists/cache_top_sky130.v"
echo "  Area:    reports/area_sky130.rpt"

# ── Step 4: OpenSTA timing ──
echo ""
echo "══════ Running OpenSTA ══════"
sta sta.tcl 2>&1 | tee reports/sta_log.txt

echo ""
echo "══════ DONE ══════"
echo "  Check reports/ for all outputs."
