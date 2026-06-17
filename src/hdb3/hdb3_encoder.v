// =============================================================================
// hdb3_encoder.v - HDB3 encoder (streaming batch reader)
// =============================================================================
// The encoder reads the prepared bit buffer sequentially and emits one HDB3
// symbol at a time. Up to three zero symbols are delayed so B00V can be emitted
// without a large local symbol RAM or a back-write pass.
// =============================================================================

module hdb3_encoder (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,
    input  wire [10:0] total_bits,

    output wire [7:0]  bit_buf_addr,
    input  wire [7:0]  bit_buf_byte,

    output reg  [2:0]  sym_out,
    output reg         sym_valid,
    output reg         sym_wr_en,
    output reg         done
);

    localparam SYM_0  = 3'd0;
    localparam SYM_P1 = 3'd1;
    localparam SYM_N1 = 3'd2;
    localparam SYM_PV = 3'd3;
    localparam SYM_NV = 3'd4;
    localparam SYM_PB = 3'd5;
    localparam SYM_NB = 3'd6;

    localparam S_IDLE  = 3'd0;
    localparam S_READ  = 3'd1;
    localparam S_FLUSH = 3'd2;
    localparam S_SUBST = 3'd3;
    localparam S_DONE  = 3'd4;

    reg [2:0]  state;
    reg [10:0] bit_idx;
    reg        ami_pol;          // 0=positive next 1, 1=negative next 1
    reg        last_pol;         // 0=positive previous pulse, 1=negative previous pulse
    reg        pulse_parity;     // number of data-1 pulses since last V: 0=even, 1=odd
    reg [1:0]  zero_cnt;         // delayed zeros waiting to be emitted, 0..3

    reg [1:0]  flush_cnt;
    reg        flush_to_done;

    reg [2:0]  subst_buf [0:3];
    reg [1:0]  subst_idx;

    wire [2:0] bit_pos = 3'd7 - bit_idx[2:0];
    wire       current_bit = bit_buf_byte[bit_pos];

    assign bit_buf_addr = bit_idx[10:3];

    task emit_symbol;
        input [2:0] symbol;
        begin
            sym_out   <= symbol;
            sym_valid <= 1'b1;
            sym_wr_en <= 1'b1;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            bit_idx       <= 11'd0;
            ami_pol       <= 1'b0;
            last_pol      <= 1'b0;
            pulse_parity  <= 1'b0;
            zero_cnt      <= 2'd0;
            flush_cnt     <= 2'd0;
            flush_to_done <= 1'b0;
            subst_idx     <= 2'd0;
            sym_out       <= SYM_0;
            sym_valid     <= 1'b0;
            sym_wr_en     <= 1'b0;
            done          <= 1'b0;
        end
        else begin
            sym_valid <= 1'b0;
            sym_wr_en <= 1'b0;
            done      <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        bit_idx       <= 11'd0;
                        ami_pol       <= 1'b0;
                        last_pol      <= 1'b0;
                        pulse_parity  <= 1'b0;
                        zero_cnt      <= 2'd0;
                        flush_cnt     <= 2'd0;
                        flush_to_done <= 1'b0;
                        subst_idx     <= 2'd0;
                        state         <= (total_bits == 11'd0) ? S_DONE : S_READ;
                    end
                end

                S_READ: begin
                    if (bit_idx == total_bits) begin
                        if (zero_cnt != 2'd0) begin
                            flush_cnt     <= zero_cnt;
                            flush_to_done <= 1'b1;
                            zero_cnt      <= 2'd0;
                            state         <= S_FLUSH;
                        end
                        else begin
                            state <= S_DONE;
                        end
                    end
                    else if (current_bit) begin
                        if (zero_cnt != 2'd0) begin
                            flush_cnt     <= zero_cnt;
                            flush_to_done <= 1'b0;
                            zero_cnt      <= 2'd0;
                            state         <= S_FLUSH;
                        end
                        else begin
                            if (ami_pol == 1'b0) begin
                                emit_symbol(SYM_P1);
                                last_pol <= 1'b0;
                            end
                            else begin
                                emit_symbol(SYM_N1);
                                last_pol <= 1'b1;
                            end
                            ami_pol      <= ~ami_pol;
                            pulse_parity <= ~pulse_parity;
                            bit_idx      <= bit_idx + 11'd1;
                        end
                    end
                    else begin
                        if (zero_cnt == 2'd3) begin
                            if (pulse_parity == 1'b0) begin
                                if (last_pol == 1'b0) begin
                                    subst_buf[0] <= SYM_NB;
                                    subst_buf[3] <= SYM_NV;
                                    ami_pol      <= 1'b0;
                                    last_pol     <= 1'b1;
                                end
                                else begin
                                    subst_buf[0] <= SYM_PB;
                                    subst_buf[3] <= SYM_PV;
                                    ami_pol      <= 1'b1;
                                    last_pol     <= 1'b0;
                                end
                            end
                            else begin
                                subst_buf[0] <= SYM_0;
                                subst_buf[3] <= (last_pol == 1'b0) ? SYM_PV : SYM_NV;
                                ami_pol      <= ~last_pol;
                            end

                            subst_buf[1] <= SYM_0;
                            subst_buf[2] <= SYM_0;
                            subst_idx    <= 2'd0;
                            zero_cnt     <= 2'd0;
                            pulse_parity <= 1'b0;
                            bit_idx      <= bit_idx + 11'd1;
                            state        <= S_SUBST;
                        end
                        else begin
                            zero_cnt <= zero_cnt + 2'd1;
                            bit_idx  <= bit_idx + 11'd1;
                        end
                    end
                end

                S_FLUSH: begin
                    emit_symbol(SYM_0);
                    if (flush_cnt <= 2'd1) begin
                        flush_cnt <= 2'd0;
                        state     <= flush_to_done ? S_DONE : S_READ;
                    end
                    else begin
                        flush_cnt <= flush_cnt - 2'd1;
                    end
                end

                S_SUBST: begin
                    emit_symbol(subst_buf[subst_idx]);
                    if (subst_idx == 2'd3) begin
                        subst_idx <= 2'd0;
                        state     <= S_READ;
                    end
                    else begin
                        subst_idx <= subst_idx + 2'd1;
                    end
                end

                S_DONE: begin
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
