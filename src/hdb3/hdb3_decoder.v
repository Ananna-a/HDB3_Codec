// =============================================================================
// hdb3_decoder.v - HDB3 decoder
// =============================================================================
// +1/-1 symbols decode to bit 1. All other HDB3 symbols decode to bit 0.
// The top level supplies one symbol with sym_avail per cycle after start.
// =============================================================================

module hdb3_decoder (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,
    input  wire [10:0] total_syms,

    input  wire [2:0]  sym_in,
    input  wire        sym_avail,

    output reg         bit_out,
    output reg         bit_valid,
    output reg         done
);

    localparam SYM_P1 = 3'd1;
    localparam SYM_N1 = 3'd2;

    localparam S_IDLE   = 2'd0;
    localparam S_DECODE = 2'd1;
    localparam S_DONE   = 2'd2;

    reg [1:0]  state;
    reg [10:0] sym_idx;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            sym_idx   <= 11'd0;
            bit_out   <= 1'b0;
            bit_valid <= 1'b0;
            done      <= 1'b0;
        end
        else begin
            bit_valid <= 1'b0;
            done      <= 1'b0;

            case (state)
                S_IDLE: begin
                    sym_idx <= 11'd0;
                    if (start)
                        state <= (total_syms == 11'd0) ? S_DONE : S_DECODE;
                end

                S_DECODE: begin
                    if (sym_avail && sym_idx < total_syms) begin
                        bit_out   <= (sym_in == SYM_P1 || sym_in == SYM_N1);
                        bit_valid <= 1'b1;
                        sym_idx   <= sym_idx + 11'd1;
                        if (sym_idx == total_syms - 11'd1)
                            state <= S_DONE;
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
