# L1 Cache Controller

Parameterized, synthesizable 4-way set-associative L1 data cache controller in SystemVerilog. Write-back, write-allocate policy with tree-based pseudo-LRU replacement. Fully verified with 45 self-checking tests and timed-closed at **138.8 MHz on SkyWater 130nm**.

## Architecture

```
                  CPU Interface                          Memory Interface
              (32-bit, valid/ready)                    (32-bit, valid/ready)
                      │                                        │
                      ▼                                        ▼
        ┌──────────────────────────────────┐
        │           cache_top              │
        │                                  │
        │  ┌──────────┐   ┌────────────┐   │
        │  │ Tag Array │   │ Data Array │   │
        │  │ (4-way)   │   │ (4-way)    │   │
        │  └──────────┘   └────────────┘   │
        │                                  │
        │  ┌──────────┐   ┌────────────┐   │
        │  │ PLRU Tree │   │  FSM       │   │
        │  │ (3b/set)  │   │  Control   │   │
        │  └──────────┘   └────────────┘   │
        └──────────────────────────────────┘
```

### Address Breakdown (32-bit)

| Field       | Bits     | Width |
|-------------|----------|-------|
| Tag         | [31:10]  | 22    |
| Index       | [9:4]    | 6     |
| Word Offset | [3:2]    | 2     |
| Byte Offset | [1:0]    | 2     |

### Cache Geometry (Default)

| Parameter   | Value                        |
|-------------|------------------------------|
| Ways        | 4                            |
| Sets        | 64                           |
| Line Size   | 128 bits (4 × 32-bit words)  |
| Total Size  | 4 KB                         |
| Replacement | Tree-based Pseudo-LRU        |
| Write Policy| Write-back, write-allocate   |

All geometry parameters (`NUM_WAYS`, `NUM_SETS`, `LINE_SIZE`, `ADDR_WIDTH`, `DATA_WIDTH`) are configurable via `cache_pkg.sv`.

## FSM

```
  IDLE ──► TAG_CHECK ──► Hit ──► IDLE
                    │
                    ├── Miss (clean) ──► ALLOCATE ──► REFILL_DONE ──► IDLE
                    │
                    └── Miss (dirty) ──► WRITEBACK ──► ALLOCATE ──► REFILL_DONE ──► IDLE
```

- **TAG_CHECK**: Parallel tag comparison across all ways. Invalid ways are preferred over PLRU eviction.
- **WRITEBACK**: Bursts dirty line to memory (4 beats, valid/ready handshake).
- **ALLOCATE**: Fetches new line from memory (4-beat burst).
- **REFILL_DONE**: Installs fetched line + applies CPU write (write-allocate merge).

## Interfaces

**CPU Side** — Simple valid/ready handshake:
- `cpu_req_valid`, `cpu_req_ready`, `cpu_req_addr[31:0]`, `cpu_req_wdata[31:0]`, `cpu_req_we`, `cpu_req_be[3:0]`
- `cpu_resp_valid`, `cpu_resp_rdata[31:0]`

**Memory Side** — 4-beat burst, valid/ready handshake:
- `mem_req_valid`, `mem_req_ready`, `mem_req_addr[31:0]`, `mem_req_wdata[31:0]`, `mem_req_we`
- `mem_resp_valid`, `mem_resp_rdata[31:0]`

## Verification

**45/45 self-checking tests PASS** (Icarus Verilog) covering:

- Compulsory misses (cold cache)
- Read/write hits (all word offsets)
- Sub-word access: SB, SH via byte enables
- Dirty eviction + writeback integrity
- Write-allocate on miss (read-modify-write)
- Back-to-back hits and back-to-back misses
- PLRU set thrashing (6 unique tags on 4 ways)
- Writeback data integrity round-trip

The testbench (`tb/tb_cache_top.sv`) uses a behavioral memory model with configurable latency (`tb/mem_model.sv`) and a reference model that shadows cache state for automatic checking.

**Lint**: Verilator clean (`-Wall`, `-Wno-UNUSEDPARAM`).

## Synthesis & Timing Results

### SkyWater 130nm (`sky130_fd_sc_hd`)

| Metric          | Value                |
|-----------------|----------------------|
| **Fmax**        | **138.8 MHz**        |
| Clock Period    | 7.2 ns               |
| Setup Slack     | +0.04 ns (at Fmax)   |
| Hold Slack      | +0.24 ns             |
| WNS / TNS       | 0.00                 |
| Area            | ~1.63 mm²            |
| Sequential %    | 48.36%               |

**Critical path**: Tag compare → hit detect → 4-way data mux → word select → `cpu_resp_rdata` output.

Fmax sweep from 100–143 MHz confirms 138.8 MHz as the maximum with positive slack. 142.8 MHz (7.0 ns period) fails at −0.18 ns.

### ASAP 7nm (`asap7_merged_RVT_TT`)

| Metric          | Value                |
|-----------------|----------------------|
| Area            | ~0.022 mm²           |
| Cells           | 173,717              |
| Flops           | 39,201 (52.45% seq)  |

> **Note**: ASAP 7nm timing is not reported — Yosys maps minimum-drive cells only, and without buffer insertion / gate resizing (requires OpenROAD), timing numbers are not meaningful. ASAP 7nm is used here for **cross-node area comparison only** (~74× smaller than SkyWater 130nm).

### Tools

- **Synthesis**: Yosys 0.46
- **STA**: OpenSTA 3.1.0
- **Simulation**: Icarus Verilog, Verilator (lint)

## Repository Structure

```
l1-cache-controller/
├── rtl/
│   ├── cache_pkg.sv         # Parameters, derived constants, FSM enum
│   ├── cache_top.sv          # Main FSM + inlined tag/data storage
│   ├── tag_array.sv          # Tag array (reference, not instantiated)
│   └── data_array.sv         # Data array (reference, not instantiated)
├── tb/
│   ├── tb_cache_top.sv       # Self-checking testbench (45 tests)
│   └── mem_model.sv          # Behavioral memory, configurable latency
├── syn/
│   ├── cache_top_flat.sv     # Flattened SV for Yosys compatibility
│   ├── run_flow.sh           # Yosys synth + OpenSTA timing automation
│   ├── sweep_fmax.sh         # Fmax binary sweep script
│   └── sta.tcl               # OpenSTA timing constraints
└── docs/
    └── (architecture diagrams)
```

> `tag_array.sv` and `data_array.sv` are kept for reference. They are **not instantiated** in `cache_top.sv` due to an Icarus Verilog limitation where `always_comb` does not re-trigger when internal arrays are updated via NBA in sub-modules. Storage is inlined into `cache_top.sv` with generate-based assign reads.

## Running

### Simulation (Icarus Verilog)

```bash
cd tb/
iverilog -g2012 -o cache_tb.vvp \
    ../rtl/cache_pkg.sv ../rtl/cache_top.sv \
    mem_model.sv tb_cache_top.sv
vvp cache_tb.vvp
```

### Lint (Verilator)

```bash
verilator --lint-only -Wall -Wno-UNUSEDPARAM \
    rtl/cache_pkg.sv rtl/cache_top.sv
```

### Synthesis + STA

```bash
cd syn/
./run_flow.sh          # Single-frequency synthesis + timing
./sweep_fmax.sh        # Fmax sweep across frequency range
```

## License

MIT
