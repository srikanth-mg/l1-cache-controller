// Self-checking testbench for cache_top
// Reference model: byte-addressable associative array, initialized same as mem_model
// Every CPU read is compared against reference; mismatches = FAIL

`timescale 1ns/1ps

module tb_cache_top;

  import cache_pkg::*;

  // ════════════════════════════════════════════
  //  Clock & reset
  // ════════════════════════════════════════════
  logic clk = 0;
  always #5 clk = ~clk;  // 100 MHz

  logic rst_n;

  // ════════════════════════════════════════════
  //  DUT signals
  // ════════════════════════════════════════════
  logic                  cpu_req_valid;
  logic                  cpu_req_ready;
  logic [ADDR_WIDTH-1:0] cpu_req_addr;
  logic [DATA_WIDTH-1:0] cpu_req_wdata;
  logic                  cpu_req_we;
  logic [BE_WIDTH-1:0]   cpu_req_be;
  logic                  cpu_resp_valid;
  logic [DATA_WIDTH-1:0] cpu_resp_rdata;

  logic                  mem_req_valid;
  logic                  mem_req_ready;
  logic [ADDR_WIDTH-1:0] mem_req_addr;
  logic                  mem_req_we;
  logic [DATA_WIDTH-1:0] mem_req_wdata;
  logic                  mem_resp_valid;
  logic [DATA_WIDTH-1:0] mem_resp_rdata;

  // ════════════════════════════════════════════
  //  DUT
  // ════════════════════════════════════════════
  cache_top u_dut (
    .clk            (clk),
    .rst_n          (rst_n),
    .cpu_req_valid  (cpu_req_valid),
    .cpu_req_ready  (cpu_req_ready),
    .cpu_req_addr   (cpu_req_addr),
    .cpu_req_wdata  (cpu_req_wdata),
    .cpu_req_we     (cpu_req_we),
    .cpu_req_be     (cpu_req_be),
    .cpu_resp_valid (cpu_resp_valid),
    .cpu_resp_rdata (cpu_resp_rdata),
    .mem_req_valid  (mem_req_valid),
    .mem_req_ready  (mem_req_ready),
    .mem_req_addr   (mem_req_addr),
    .mem_req_we     (mem_req_we),
    .mem_req_wdata  (mem_req_wdata),
    .mem_resp_valid (mem_resp_valid),
    .mem_resp_rdata (mem_resp_rdata)
  );

  // ════════════════════════════════════════════
  //  Memory model (configurable latency)
  // ════════════════════════════════════════════
  mem_model #(.LATENCY(2)) u_mem (
    .clk        (clk),
    .rst_n      (rst_n),
    .req_valid  (mem_req_valid),
    .req_ready  (mem_req_ready),
    .req_addr   (mem_req_addr),
    .req_we     (mem_req_we),
    .req_wdata  (mem_req_wdata),
    .resp_valid (mem_resp_valid),
    .resp_rdata (mem_resp_rdata)
  );

  // ════════════════════════════════════════════
  //  Reference model (byte-addressable)
  // ════════════════════════════════════════════
  logic [7:0] ref_mem [0:32767];  // 32KB, matches mem_model

  initial begin
    for (int i = 0; i < 32768; i += 4) begin
      ref_mem[i]   = i[7:0];
      ref_mem[i+1] = i[15:8];
      ref_mem[i+2] = i[23:16];
      ref_mem[i+3] = i[31:24];
    end
  end

  function automatic logic [DATA_WIDTH-1:0] ref_read(input logic [ADDR_WIDTH-1:0] addr);
    logic [ADDR_WIDTH-1:0] wa = {addr[ADDR_WIDTH-1:2], 2'b00};  // word-align
    return {ref_mem[wa+3], ref_mem[wa+2], ref_mem[wa+1], ref_mem[wa]};
  endfunction

  // ════════════════════════════════════════════
  //  Scoreboard
  // ════════════════════════════════════════════
  int pass_cnt = 0;
  int fail_cnt = 0;
  int total_ops = 0;

  // ════════════════════════════════════════════
  //  Timeout watchdog
  // ════════════════════════════════════════════
  parameter TIMEOUT = 50_000;
  initial begin
    #(TIMEOUT * 10);
    $display("\n[TIMEOUT] Simulation exceeded %0d ns — hanging.", TIMEOUT * 10);
    $finish;
  end

  // ════════════════════════════════════════════
  //  CPU driver tasks
  //  Drive on negedge, sample on posedge — no race conditions
  // ════════════════════════════════════════════

  task automatic cpu_read(
    input  logic [ADDR_WIDTH-1:0] addr,
    output logic [DATA_WIDTH-1:0] data
  );
    // Wait until DUT is ready
    @(posedge clk);
    while (!cpu_req_ready) @(posedge clk);

    // Drive request on negedge
    @(negedge clk);
    cpu_req_valid = 1;
    cpu_req_addr  = addr;
    cpu_req_we    = 0;
    cpu_req_be    = {BE_WIDTH{1'b1}};
    cpu_req_wdata = '0;

    // Wait for acceptance (valid & ready on posedge)
    @(posedge clk);
    // Handshake fires on this edge (ready was 1 from the while-loop check)

    // Deassert request
    @(negedge clk);
    cpu_req_valid = 0;

    // Wait for response
    @(posedge clk);
    while (!cpu_resp_valid) @(posedge clk);
    data = cpu_resp_rdata;

    total_ops++;
  endtask

  task automatic cpu_write(
    input logic [ADDR_WIDTH-1:0] addr,
    input logic [DATA_WIDTH-1:0] data,
    input logic [BE_WIDTH-1:0]   be
  );
    // Wait until DUT is ready
    @(posedge clk);
    while (!cpu_req_ready) @(posedge clk);

    // Drive request on negedge
    @(negedge clk);
    cpu_req_valid = 1;
    cpu_req_addr  = addr;
    cpu_req_we    = 1;
    cpu_req_be    = be;
    cpu_req_wdata = data;

    // Wait for acceptance
    @(posedge clk);

    // Deassert
    @(negedge clk);
    cpu_req_valid = 0;

    // Wait for response (write acknowledgment)
    @(posedge clk);
    while (!cpu_resp_valid) @(posedge clk);

    // Update reference model
    for (int b = 0; b < BE_WIDTH; b++) begin
      if (be[b]) begin
        logic [ADDR_WIDTH-1:0] wa = {addr[ADDR_WIDTH-1:2], 2'b00};
        ref_mem[wa + b] = data[b*8 +: 8];
      end
    end

    total_ops++;
  endtask

  // ════════════════════════════════════════════
  //  Check-and-report wrappers
  // ════════════════════════════════════════════

  task automatic check_read(
    input string                  test_name,
    input logic [ADDR_WIDTH-1:0]  addr
  );
    logic [DATA_WIDTH-1:0] got, exp;
    cpu_read(addr, got);
    exp = ref_read(addr);
    if (got === exp) begin
      pass_cnt++;
      $display("  [PASS] %-40s addr=0x%08h  data=0x%08h", test_name, addr, got);
    end else begin
      fail_cnt++;
      $display("  [FAIL] %-40s addr=0x%08h  exp=0x%08h  got=0x%08h", test_name, addr, exp, got);
    end
  endtask

  task automatic checked_write(
    input string                  test_name,
    input logic [ADDR_WIDTH-1:0]  addr,
    input logic [DATA_WIDTH-1:0]  data,
    input logic [BE_WIDTH-1:0]    be
  );
    cpu_write(addr, data, be);
    $display("  [WRIT] %-40s addr=0x%08h  data=0x%08h  be=0x%h", test_name, addr, data, be);
  endtask

  // ════════════════════════════════════════════
  //  Address helpers
  //  Set 0 addresses: tag increments by 0x400
  //  addr = tag * 0x400 + set * 0x10 + word * 0x4
  // ════════════════════════════════════════════
  function automatic logic [31:0] make_addr(
    input int tag, input int set, input int word
  );
    return (tag << TAG_LO) | (set << INDEX_LO) | (word << WORD_LO);
  endfunction

  // ════════════════════════════════════════════
  //  Test sequences
  // ════════════════════════════════════════════
  initial begin
    $dumpfile("cache_tb.vcd");
    $dumpvars(0, tb_cache_top);

    // ── Reset ──
    rst_n = 0;
    cpu_req_valid = 0;
    cpu_req_addr  = '0;
    cpu_req_wdata = '0;
    cpu_req_we    = 0;
    cpu_req_be    = '0;
    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);

    // ════════════════════════════════════════
    //  TEST 1: Cold-start compulsory misses
    //  4 reads to set 0, each a different tag → fills all 4 ways
    // ════════════════════════════════════════
    $display("\n══════ TEST 1: Cold-start compulsory misses (set 0) ══════");
    check_read("compulsory miss tag0", make_addr(0, 0, 0));  // way 0
    check_read("compulsory miss tag1", make_addr(1, 0, 0));  // way 1
    check_read("compulsory miss tag2", make_addr(2, 0, 0));  // way 2
    check_read("compulsory miss tag3", make_addr(3, 0, 0));  // way 3

    // ════════════════════════════════════════
    //  TEST 2: Read hits
    //  Same addresses → all should hit now
    // ════════════════════════════════════════
    $display("\n══════ TEST 2: Read hits ══════");
    check_read("read hit tag0", make_addr(0, 0, 0));
    check_read("read hit tag1", make_addr(1, 0, 0));
    check_read("read hit tag2", make_addr(2, 0, 0));
    check_read("read hit tag3", make_addr(3, 0, 0));

    // ════════════════════════════════════════
    //  TEST 3: Read different words in a cached line
    // ════════════════════════════════════════
    $display("\n══════ TEST 3: Read different words in cached line ══════");
    check_read("tag0 word1", make_addr(0, 0, 1));
    check_read("tag0 word2", make_addr(0, 0, 2));
    check_read("tag0 word3", make_addr(0, 0, 3));

    // ════════════════════════════════════════
    //  TEST 4: Write hit (full word)
    // ════════════════════════════════════════
    $display("\n══════ TEST 4: Write hit (SW) ══════");
    checked_write("SW to tag1 word0", make_addr(1, 0, 0), 32'hCAFEBABE, 4'hF);
    check_read("read back SW",        make_addr(1, 0, 0));

    // ════════════════════════════════════════
    //  TEST 5: Byte / halfword writes
    // ════════════════════════════════════════
    $display("\n══════ TEST 5: Byte & halfword writes (SB/SH) ══════");
    // SB: write byte 0 only
    checked_write("SB byte0",  make_addr(2, 0, 0), 32'h000000AA, 4'b0001);
    check_read("read back SB", make_addr(2, 0, 0));

    // SH: write bytes 2-3 (upper halfword)
    checked_write("SH upper",  make_addr(2, 0, 0), 32'hBBCC0000, 4'b1100);
    check_read("read back SH", make_addr(2, 0, 0));

    // ════════════════════════════════════════
    //  TEST 6: Dirty eviction
    //  Set 0 has 4 ways full (tag0-3). Tag1 is dirty.
    //  Access tag4 → PLRU victim gets evicted (writeback if dirty) → allocate tag4
    // ════════════════════════════════════════
    $display("\n══════ TEST 6: Dirty eviction (conflict miss) ══════");
    check_read("conflict miss tag4", make_addr(4, 0, 0));

    // Re-read a surviving tag to confirm it wasn't corrupted
    check_read("surviving tag2", make_addr(2, 0, 0));
    check_read("surviving tag3", make_addr(3, 0, 0));

    // ════════════════════════════════════════
    //  TEST 7: Write-allocate miss
    //  Write to a tag not in cache → miss → allocate → write
    // ════════════════════════════════════════
    $display("\n══════ TEST 7: Write-allocate miss ══════");
    checked_write("write-alloc miss", make_addr(5, 1, 0), 32'hDEAD_BEEF, 4'hF);
    check_read("read back write-alloc", make_addr(5, 1, 0));
    // Also check that the other words in the line came from memory
    check_read("line word1 after alloc", make_addr(5, 1, 1));

    // ════════════════════════════════════════
    //  TEST 8: Back-to-back hits
    // ════════════════════════════════════════
    $display("\n══════ TEST 8: Back-to-back hits ══════");
    check_read("b2b hit 1", make_addr(4, 0, 0));
    check_read("b2b hit 2", make_addr(4, 0, 1));
    check_read("b2b hit 3", make_addr(4, 0, 2));
    check_read("b2b hit 4", make_addr(4, 0, 3));

    // ════════════════════════════════════════
    //  TEST 9: Back-to-back misses (different sets)
    // ════════════════════════════════════════
    $display("\n══════ TEST 9: Back-to-back misses (different sets) ══════");
    check_read("miss set2",  make_addr(0, 2, 0));
    check_read("miss set3",  make_addr(0, 3, 0));
    check_read("miss set4",  make_addr(0, 4, 0));
    check_read("miss set5",  make_addr(0, 5, 0));

    // ════════════════════════════════════════
    //  TEST 10: Full set thrash (PLRU stress)
    //  Cycle through 6 tags in set 10 → exercises all eviction paths
    // ════════════════════════════════════════
    $display("\n══════ TEST 10: Set thrash — PLRU stress (set 10) ══════");
    for (int t = 0; t < 6; t++)
      check_read($sformatf("thrash tag%0d", t), make_addr(t, 10, 0));

    // Go back and hit the most recent 4
    check_read("thrash re-hit tag5", make_addr(5, 10, 0));
    check_read("thrash re-hit tag4", make_addr(4, 10, 0));
    check_read("thrash re-hit tag3", make_addr(3, 10, 0));

    // ════════════════════════════════════════
    //  TEST 11: Write then evict, read from memory
    //  Ensures dirty data survives the writeback round-trip
    // ════════════════════════════════════════
    $display("\n══════ TEST 11: Write → evict → re-read (writeback integrity) ══════");
    // Fill set 20 (ways 0-3)
    for (int t = 0; t < 4; t++)
      check_read($sformatf("fill set20 tag%0d", t), make_addr(t, 20, 0));

    // Write to tag0 in set 20
    checked_write("dirty set20 tag0", make_addr(0, 20, 0), 32'h1234_5678, 4'hF);

    // Evict by filling 4 new tags (pushes all old ones out)
    for (int t = 4; t < 8; t++)
      check_read($sformatf("evict set20 tag%0d", t), make_addr(t, 20, 0));

    // Read tag0 back — should come from memory with the dirty writeback value
    check_read("re-read evicted tag0", make_addr(0, 20, 0));

    // ════════════════════════════════════════
    //  FINAL REPORT
    // ════════════════════════════════════════
    repeat (10) @(posedge clk);
    $display("\n════════════════════════════════════════════");
    $display("  RESULTS:  %0d PASS  /  %0d FAIL  /  %0d total ops",
             pass_cnt, fail_cnt, total_ops);
    if (fail_cnt == 0)
      $display("  *** ALL TESTS PASSED ***");
    else
      $display("  *** FAILURES DETECTED ***");
    $display("════════════════════════════════════════════\n");
    $finish;
  end

endmodule
