package cache_pkg;

  // ── Base parameters (override at top-level) ──
  parameter ADDR_WIDTH     = 32;
  parameter DATA_WIDTH     = 32;
  parameter NUM_WAYS       = 4;
  parameter NUM_SETS       = 64;
  parameter LINE_SIZE_BITS = 128;

  // ── Derived constants ──
  parameter WORDS_PER_LINE = LINE_SIZE_BITS / DATA_WIDTH;           // 4
  parameter BYTE_OFFSET_W  = $clog2(DATA_WIDTH / 8);                // 2
  parameter WORD_OFFSET_W  = $clog2(WORDS_PER_LINE);                // 2
  parameter INDEX_W        = $clog2(NUM_SETS);                      // 6
  parameter TAG_W          = ADDR_WIDTH - INDEX_W
                             - WORD_OFFSET_W - BYTE_OFFSET_W;       // 22
  parameter WAY_W          = $clog2(NUM_WAYS);                      // 2
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

endpackage
