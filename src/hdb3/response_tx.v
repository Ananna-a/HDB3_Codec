// =============================================================================
// response_tx.v - UART response frame sender
// Frame: AA 55 | cmd | status | len_l | len_h | payload[0..N-1] | cs
// =============================================================================

module response_tx (
    input  wire       clk,
    input  wire       rst_n,

    input  wire       start,
    input  wire [7:0] resp_cmd,
    input  wire [7:0] resp_status,
    input  wire [7:0] resp_len,

    output wire [7:0] payload_addr,
    input  wire [7:0] payload_data,

    output reg        send_en,
    output reg  [7:0] send_data,
    input  wire       tx_done,
    input  wire       tx_busy,

    output reg        resp_done
);

    localparam S_IDLE = 2'd0;
    localparam S_SEND = 2'd1;
    localparam S_WAIT = 2'd2;
    localparam S_DONE = 2'd3;

    reg [1:0] state, next_state;
    reg [8:0] byte_idx;
    reg [8:0] total_bytes;
    reg [7:0] cs_val;

    assign payload_addr = byte_idx[7:0] - 8'd6;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= S_IDLE;
        else
            state <= next_state;
    end

    always @(*) begin
        next_state = state;
        case (state)
            S_IDLE: if (start) next_state = S_SEND;
            S_SEND: next_state = S_WAIT;
            S_WAIT: begin
                if (tx_done)
                    next_state = (byte_idx == total_bytes) ? S_DONE : S_SEND;
            end
            S_DONE: next_state = S_IDLE;
            default: next_state = S_IDLE;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            send_en     <= 1'b0;
            send_data   <= 8'd0;
            byte_idx    <= 9'd0;
            total_bytes <= 9'd0;
            cs_val      <= 8'd0;
            resp_done   <= 1'b0;
        end
        else begin
            send_en   <= 1'b0;
            resp_done <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        total_bytes <= 9'd7 + {1'b0, resp_len};
                        byte_idx    <= 9'd0;
                        cs_val      <= resp_cmd + resp_status + resp_len;
                    end
                end

                S_SEND: begin
                    send_en <= 1'b1;
                    case (byte_idx)
                        9'd0: send_data <= 8'hAA;
                        9'd1: send_data <= 8'h55;
                        9'd2: send_data <= resp_cmd;
                        9'd3: send_data <= resp_status;
                        9'd4: send_data <= resp_len;
                        9'd5: send_data <= 8'h00;
                        default: begin
                            if (byte_idx < total_bytes - 9'd1) begin
                                send_data <= payload_data;
                                cs_val    <= cs_val + payload_data;
                            end
                            else begin
                                send_data <= cs_val;
                            end
                        end
                    endcase
                    byte_idx <= byte_idx + 9'd1;
                end

                S_DONE: begin
                    resp_done <= 1'b1;
                end
            endcase
        end
    end

endmodule
