// Behavioral memory model
// - Writes: accepted one beat at a time in M_IDLE (stays IDLE between beats)
// - Reads:  single request accepted, LATENCY-cycle wait, then 4-beat burst response
// - Init:   each word-aligned address holds its own address value (easy debug)

module mem_model #(
  parameter LATENCY  = 2,        // cycles between read-accept and first response beat
  parameter AW       = 32,
  parameter DW       = 32,
  parameter BEATS    = 4
)(
  input  logic          clk,
  input  logic          rst_n,

  input  logic          req_valid,
  output logic          req_ready,
  input  logic [AW-1:0] req_addr,
  input  logic          req_we,
  input  logic [DW-1:0] req_wdata,

  output logic          resp_valid,
  output logic [DW-1:0] resp_rdata
);

  // ── Storage (byte-addressable, fixed-size) ──
  logic [7:0] storage [0:32767];  // 32KB

  // ── Initialize: word at address A = A ──
  initial begin
    for (int i = 0; i < 32768; i += 4) begin
      storage[i]   = i[7:0];
      storage[i+1] = i[15:8];
      storage[i+2] = i[23:16];
      storage[i+3] = i[31:24];
    end
  end

  // ── Internal state ──
  typedef enum logic [1:0] {M_IDLE, M_WAIT, M_BURST} mstate_t;
  mstate_t mstate;

  logic [AW-1:0] burst_base;
  int            wait_cnt;
  int            burst_cnt;

  assign req_ready = (mstate == M_IDLE);

  // Helper: read a 32-bit word from byte-addressable storage
  function automatic logic [DW-1:0] read_word(input int unsigned addr);
    return {storage[addr+3], storage[addr+2], storage[addr+1], storage[addr]};
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mstate     <= M_IDLE;
      resp_valid <= 1'b0;
      resp_rdata <= '0;
      wait_cnt   <= 0;
      burst_cnt  <= 0;
      burst_base <= '0;
    end else begin
      resp_valid <= 1'b0;  // default: no response

      case (mstate)
        // ────────────────────────────────────
        M_IDLE: begin
          if (req_valid && req_ready) begin
            if (req_we) begin
              // Write beat — store and stay IDLE for next beat
              storage[req_addr]   = req_wdata[7:0];
              storage[req_addr+1] = req_wdata[15:8];
              storage[req_addr+2] = req_wdata[23:16];
              storage[req_addr+3] = req_wdata[31:24];
            end else begin
              // Read request — start latency countdown
              burst_base <= req_addr;
              if (LATENCY <= 1) begin
                mstate    <= M_BURST;
                burst_cnt <= 0;
              end else begin
                mstate   <= M_WAIT;
                wait_cnt <= 1;
              end
            end
          end
        end

        // ────────────────────────────────────
        M_WAIT: begin
          if (wait_cnt >= LATENCY - 1) begin
            mstate    <= M_BURST;
            burst_cnt <= 0;
          end else begin
            wait_cnt <= wait_cnt + 1;
          end
        end

        // ────────────────────────────────────
        M_BURST: begin
          resp_valid <= 1'b1;
          resp_rdata <= read_word(burst_base + burst_cnt * (DW/8));

          if (burst_cnt >= BEATS - 1)
            mstate <= M_IDLE;

          burst_cnt <= burst_cnt + 1;
        end

        default: mstate <= M_IDLE;
      endcase
    end
  end

endmodule
