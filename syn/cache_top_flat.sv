// ============================================================
// cache_top — flattened for Yosys synthesis
// Package params inlined, SV constructs adapted for Yosys
// ============================================================

// ── Base parameters (override at top-level) ──
  parameter ADDR_WIDTH     = 32;
  parameter DATA_WIDTH     = 32;
  parameter NUM_WAYS       = 4;
  parameter NUM_SETS       = 64;
  parameter LINE_SIZE_BITS = 128;

  // ── Derived constants ──
  parameter WORDS_PER_LINE = LINE_SIZE_BITS / DATA_WIDTH;           // 4
  parameter BYTE_OFFSET_W  = 2;                // 2
  parameter WORD_OFFSET_W  = 2;                // 2
  parameter INDEX_W        = 6;                      // 6
  parameter TAG_W          = 22;       // 22
  parameter WAY_W          = 2;                      // 2
  parameter PLRU_BITS      = NUM_WAYS - 1;                          // 3
  parameter BE_WIDTH       = DATA_WIDTH / 8;                        // 4

  // ── Address field boundaries ──
  parameter BYTE_LO  = 0;
  parameter BYTE_HI  = BYTE_OFFSET_W - 1;
  parameter WORD_LO  = BYTE_OFFSET_W;
  parameter WORD_HI  = BYTE_OFFSET_W + WORD_OFFSET_W - 1;
  parameter INDEX_LO = BYTE_OFFSET_W + WORD_OFFSET_W;
  parameter INDEX_HI = BYTE_OFFSET_W + WORD_OFFSET_W + INDEX_W - 1;
  parameter TAG_LO   = INDEX_HI + 1;
  parameter TAG_HI   = ADDR_WIDTH - 1;

  // ── FSM states ──
  typedef enum logic [2:0] {
    IDLE,
    TAG_CHECK,
    WRITEBACK,
    ALLOCATE,
    REFILL_DONE
  } cache_state_t;

module cache_top
(
  input  logic                  clk,
  input  logic                  rst_n,

  // ── CPU interface (valid/ready handshake) ──
  input  logic                  cpu_req_valid,
  output logic                  cpu_req_ready,
  input  logic [ADDR_WIDTH-1:0] cpu_req_addr,
  input  logic [DATA_WIDTH-1:0] cpu_req_wdata,
  input  logic                  cpu_req_we,
  input  logic [BE_WIDTH-1:0]   cpu_req_be,
  output logic                  cpu_resp_valid,
  output logic [DATA_WIDTH-1:0] cpu_resp_rdata,

  // ── Memory interface (valid/ready handshake, 4-beat bursts) ──
  output logic                  mem_req_valid,
  input  logic                  mem_req_ready,
  output logic [ADDR_WIDTH-1:0] mem_req_addr,
  output logic                  mem_req_we,
  output logic [DATA_WIDTH-1:0] mem_req_wdata,
  input  logic                  mem_resp_valid,
  input  logic [DATA_WIDTH-1:0] mem_resp_rdata
);

  // ════════════════════════════════════════════
  //  Address decomposition
  // ════════════════════════════════════════════
  logic [TAG_W-1:0]         req_tag;
  logic [INDEX_W-1:0]       req_index;
  logic [WORD_OFFSET_W-1:0] req_word;

  assign req_tag   = cpu_req_addr[TAG_HI:TAG_LO];
  assign req_index = cpu_req_addr[INDEX_HI:INDEX_LO];
  assign req_word  = cpu_req_addr[WORD_HI:WORD_LO];

  // Byte offset bits [1:0] intentionally unused
  /* verilator lint_off UNUSEDSIGNAL */
  wire _unused_byte_offset = &{1'b0, cpu_req_addr[BYTE_HI:BYTE_LO]};
  /* verilator lint_on UNUSEDSIGNAL */

  // ════════════════════════════════════════════
  //  Latched CPU request
  // ════════════════════════════════════════════
  logic [TAG_W-1:0]         lat_tag;
  logic [INDEX_W-1:0]       lat_index;
  logic [WORD_OFFSET_W-1:0] lat_word;
  logic [DATA_WIDTH-1:0]    lat_wdata;
  logic                     lat_we;
  logic [BE_WIDTH-1:0]      lat_be;

  always_ff @(posedge clk) begin
    if (cpu_req_valid && cpu_req_ready) begin
      lat_tag   <= req_tag;
      lat_index <= req_index;
      lat_word  <= req_word;
      lat_wdata <= cpu_req_wdata;
      lat_we    <= cpu_req_we;
      lat_be    <= cpu_req_be;
    end
  end

  // ════════════════════════════════════════════
  //  FSM state register
  // ════════════════════════════════════════════
  cache_state_t state, nxt_state;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) state <= IDLE;
    else        state <= nxt_state;
  end

  // ════════════════════════════════════════════
  //  Tag storage (inlined — Icarus-safe)
  // ════════════════════════════════════════════
  logic [NUM_WAYS-1:0] valid_arr [NUM_SETS];
  logic [NUM_WAYS-1:0] dirty_arr [NUM_SETS];
  logic [TAG_W-1:0]    tag_arr   [NUM_SETS][NUM_WAYS];

  // Tag read signals
  logic [NUM_WAYS-1:0] tag_rd_valid;
  logic [NUM_WAYS-1:0] tag_rd_dirty;
  logic [TAG_W-1:0]    tag_rd_tag [NUM_WAYS];

  // Generate-based reads (continuous assigns — Icarus-safe)
  assign tag_rd_valid = valid_arr[lat_index];
  assign tag_rd_dirty = dirty_arr[lat_index];

  genvar gi;
  generate
    for (gi = 0; gi < NUM_WAYS; gi++) begin : gen_tag_rd
      assign tag_rd_tag[gi] = tag_arr[lat_index][gi];
    end
  endgenerate

  // Tag write control signals
  logic             tag_wr_en;
  logic [WAY_W-1:0] tag_wr_way;
  logic             tag_wr_valid;
  logic             tag_wr_dirty;
  logic [TAG_W-1:0] tag_wr_tag;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int s = 0; s < NUM_SETS; s++) begin
        valid_arr[s] <= '0;
        dirty_arr[s] <= '0;
      end
    end else if (tag_wr_en) begin
      valid_arr[lat_index][tag_wr_way] <= tag_wr_valid;
      dirty_arr[lat_index][tag_wr_way] <= tag_wr_dirty;
      tag_arr[lat_index][tag_wr_way]   <= tag_wr_tag;
    end
  end

  // ════════════════════════════════════════════
  //  Data storage (inlined — Icarus-safe)
  // ════════════════════════════════════════════
  logic [DATA_WIDTH-1:0] data_arr [NUM_SETS][NUM_WAYS][WORDS_PER_LINE];

  // Data read controls
  logic [INDEX_W-1:0]       data_rd_idx;
  logic [WORD_OFFSET_W-1:0] data_rd_word;
  logic [DATA_WIDTH-1:0]    data_rd [NUM_WAYS];

  // Generate-based reads (continuous assigns — Icarus-safe)
  generate
    for (gi = 0; gi < NUM_WAYS; gi++) begin : gen_data_rd
      assign data_rd[gi] = data_arr[data_rd_idx][gi][data_rd_word];
    end
  endgenerate

  // Data write controls
  logic                      data_wr_en;
  logic [WAY_W-1:0]          data_wr_way;
  logic [WORD_OFFSET_W-1:0]  data_wr_word;
  logic [BE_WIDTH-1:0]       data_wr_be;
  logic [DATA_WIDTH-1:0]     data_wr_data;

  // Data write with byte enables — no reset needed
  always_ff @(posedge clk) begin
    if (data_wr_en) begin
      for (int b = 0; b < BE_WIDTH; b++) begin
        if (data_wr_be[b])
          data_arr[data_rd_idx][data_wr_way][data_wr_word][b*8 +: 8] <= data_wr_data[b*8 +: 8];
      end
    end
  end

  // ════════════════════════════════════════════
  //  Hit detection
  // ════════════════════════════════════════════
  logic [NUM_WAYS-1:0] hit_vec;
  logic                cache_hit;
  logic [WAY_W-1:0]    hit_way;

  always_comb begin
    for (int w = 0; w < NUM_WAYS; w++)
      hit_vec[w] = tag_rd_valid[w] && (tag_rd_tag[w] == lat_tag);

    cache_hit = |hit_vec;

    hit_way = '0;
    for (int w = NUM_WAYS - 1; w >= 0; w--)
      if (hit_vec[w]) hit_way = w[WAY_W-1:0];
  end

  // ════════════════════════════════════════════
  //  PLRU — tree-based, 3 bits per set for 4-way
  // ════════════════════════════════════════════
  logic [PLRU_BITS-1:0] plru_arr [NUM_SETS];
  logic [PLRU_BITS-1:0] plru_cur;
  logic [WAY_W-1:0]     plru_victim;

  assign plru_cur = plru_arr[lat_index];

  always_comb begin
    if (!plru_cur[0])
      plru_victim = plru_cur[1] ? 2'd1 : 2'd0;
    else
      plru_victim = plru_cur[2] ? 2'd3 : 2'd2;
  end

  function automatic logic [PLRU_BITS-1:0] plru_update(
    input logic [PLRU_BITS-1:0] cur,
    input logic [WAY_W-1:0]     accessed
  );
    logic [PLRU_BITS-1:0] nxt;
    nxt = cur;
    case (accessed)
      2'd0: begin nxt[0] = 1'b1; nxt[1] = 1'b1; end
      2'd1: begin nxt[0] = 1'b1; nxt[1] = 1'b0; end
      2'd2: begin nxt[0] = 1'b0; nxt[2] = 1'b1; end
      2'd3: begin nxt[0] = 1'b0; nxt[2] = 1'b0; end
      default: nxt = cur;
    endcase
    plru_update = nxt;
  endfunction

  // ════════════════════════════════════════════
  //  Invalid-way detection (prefer empty slot)
  // ════════════════════════════════════════════
  logic             has_invalid;
  logic [WAY_W-1:0] first_invalid;

  always_comb begin
    has_invalid   = 1'b0;
    first_invalid = '0;
    for (int w = NUM_WAYS - 1; w >= 0; w--) begin
      if (!tag_rd_valid[w]) begin
        has_invalid   = 1'b1;
        first_invalid = w[WAY_W-1:0];
      end
    end
  end

  logic [WAY_W-1:0] victim_way;
  assign victim_way = has_invalid ? first_invalid : plru_victim;

  // ════════════════════════════════════════════
  //  Latched victim info
  // ════════════════════════════════════════════
  logic [WAY_W-1:0] victim_way_r;
  logic [TAG_W-1:0] victim_tag_r;

  always_ff @(posedge clk) begin
    if (state == TAG_CHECK && !cache_hit) begin
      victim_way_r <= victim_way;
      victim_tag_r <= tag_rd_tag[victim_way];
    end
  end

  // ════════════════════════════════════════════
  //  Beat counter
  // ════════════════════════════════════════════
  logic [WORD_OFFSET_W-1:0] beat_cnt;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      beat_cnt <= '0;
    end else if (state == WRITEBACK && mem_req_valid && mem_req_ready) begin
      beat_cnt <= beat_cnt + 1'b1;
    end else if (state == ALLOCATE && mem_resp_valid) begin
      beat_cnt <= beat_cnt + 1'b1;
    end else if (state != WRITEBACK && state != ALLOCATE) begin
      beat_cnt <= '0;
    end
  end

  logic alloc_req_sent;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      alloc_req_sent <= 1'b0;
    else if (state == ALLOCATE && mem_req_valid && mem_req_ready)
      alloc_req_sent <= 1'b1;
    else if (state != ALLOCATE)
      alloc_req_sent <= 1'b0;
  end

  localparam logic [WORD_OFFSET_W-1:0] LAST_BEAT = (WORDS_PER_LINE - 1);
  wire wb_last    = (state == WRITEBACK) && mem_req_valid && mem_req_ready
                    && (beat_cnt == LAST_BEAT);
  wire alloc_last = (state == ALLOCATE) && mem_resp_valid
                    && (beat_cnt == LAST_BEAT);

  // ════════════════════════════════════════════
  //  PLRU update
  // ════════════════════════════════════════════
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int s = 0; s < NUM_SETS; s++)
        plru_arr[s] <= '0;
    end else if (state == TAG_CHECK && cache_hit) begin
      plru_arr[lat_index] <= plru_update(plru_cur, hit_way);
    end else if (state == REFILL_DONE) begin
      plru_arr[lat_index] <= plru_update(plru_cur, victim_way_r);
    end
  end

  // ════════════════════════════════════════════
  //  Next-state logic
  // ════════════════════════════════════════════
  always_comb begin
    nxt_state = state;
    case (state)
      IDLE:        if (cpu_req_valid) nxt_state = TAG_CHECK;
      TAG_CHECK: begin
        if (cache_hit)
          nxt_state = IDLE;
        else if (tag_rd_valid[victim_way] && tag_rd_dirty[victim_way])
          nxt_state = WRITEBACK;
        else
          nxt_state = ALLOCATE;
      end
      WRITEBACK:   if (wb_last)    nxt_state = ALLOCATE;
      ALLOCATE:    if (alloc_last) nxt_state = REFILL_DONE;
      REFILL_DONE: nxt_state = IDLE;
      default:     nxt_state = IDLE;
    endcase
  end

  // ════════════════════════════════════════════
  //  CPU-side outputs
  // ════════════════════════════════════════════
  assign cpu_req_ready = (state == IDLE);

  always_comb begin
    cpu_resp_valid = 1'b0;
    cpu_resp_rdata = '0;
    case (state)
      TAG_CHECK: begin
        if (cache_hit) begin
          cpu_resp_valid = 1'b1;
          cpu_resp_rdata = data_rd[hit_way];
        end
      end
      REFILL_DONE: begin
        cpu_resp_valid = 1'b1;
        cpu_resp_rdata = data_rd[victim_way_r];
      end
      default: ;
    endcase
  end

  // ════════════════════════════════════════════
  //  Data read address mux
  // ════════════════════════════════════════════
  always_comb begin
    data_rd_idx  = lat_index;
    data_rd_word = lat_word;
    if (state == WRITEBACK)
      data_rd_word = beat_cnt;
  end

  // ════════════════════════════════════════════
  //  Memory-side outputs
  // ════════════════════════════════════════════
  always_comb begin
    mem_req_valid = 1'b0;
    mem_req_addr  = '0;
    mem_req_we    = 1'b0;
    mem_req_wdata = '0;
    case (state)
      WRITEBACK: begin
        mem_req_valid = 1'b1;
        mem_req_we    = 1'b1;
        mem_req_addr  = {victim_tag_r, lat_index, beat_cnt, {BYTE_OFFSET_W{1'b0}}};
        mem_req_wdata = data_rd[victim_way_r];
      end
      ALLOCATE: begin
        mem_req_valid = ~alloc_req_sent;
        mem_req_we    = 1'b0;
        mem_req_addr  = {lat_tag, lat_index, {WORD_OFFSET_W{1'b0}}, {BYTE_OFFSET_W{1'b0}}};
      end
      default: ;
    endcase
  end

  // ════════════════════════════════════════════
  //  Data write control
  // ════════════════════════════════════════════
  always_comb begin
    data_wr_en   = 1'b0;
    data_wr_way  = '0;
    data_wr_word = '0;
    data_wr_be   = '0;
    data_wr_data = '0;
    case (state)
      TAG_CHECK: begin
        if (cache_hit && lat_we) begin
          data_wr_en   = 1'b1;
          data_wr_way  = hit_way;
          data_wr_word = lat_word;
          data_wr_be   = lat_be;
          data_wr_data = lat_wdata;
        end
      end
      ALLOCATE: begin
        if (mem_resp_valid) begin
          data_wr_en   = 1'b1;
          data_wr_way  = victim_way_r;
          data_wr_word = beat_cnt;
          data_wr_be   = {BE_WIDTH{1'b1}};
          data_wr_data = mem_resp_rdata;
        end
      end
      REFILL_DONE: begin
        if (lat_we) begin
          data_wr_en   = 1'b1;
          data_wr_way  = victim_way_r;
          data_wr_word = lat_word;
          data_wr_be   = lat_be;
          data_wr_data = lat_wdata;
        end
      end
      default: ;
    endcase
  end

  // ════════════════════════════════════════════
  //  Tag write control
  // ════════════════════════════════════════════
  always_comb begin
    tag_wr_en    = 1'b0;
    tag_wr_way   = '0;
    tag_wr_valid = 1'b1;
    tag_wr_dirty = 1'b0;
    tag_wr_tag   = lat_tag;
    case (state)
      TAG_CHECK: begin
        if (cache_hit && lat_we) begin
          tag_wr_en    = 1'b1;
          tag_wr_way   = hit_way;
          tag_wr_dirty = 1'b1;
          tag_wr_tag   = lat_tag;
        end
      end
      REFILL_DONE: begin
        tag_wr_en    = 1'b1;
        tag_wr_way   = victim_way_r;
        tag_wr_valid = 1'b1;
        tag_wr_dirty = lat_we;
        tag_wr_tag   = lat_tag;
      end
      default: ;
    endcase
  end

endmodule

