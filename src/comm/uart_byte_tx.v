// =============================================================================
// uart_byte_tx.v - 8N1 UART byte transmitter
// Clock: 50 MHz by default, baud: 115200 by default.
// =============================================================================

module uart_byte_tx #(
    parameter CLK_FREQ = 50_000_000,
    parameter BAUD_RATE = 115200
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       send_en,
    input  wire [7:0] data_byte,
    output reg        uart_tx,
    output reg        tx_done,
    output reg        tx_busy
);

    localparam BPS_LIMIT = CLK_FREQ / BAUD_RATE;

    reg [15:0] div_cnt;
    reg [3:0]  bit_cnt;
    reg [7:0]  data_reg;

    wire bps_tick = (div_cnt == BPS_LIMIT - 1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_busy <= 1'b0;
            data_reg <= 8'd0;
        end
        else begin
            if (send_en && !tx_busy) begin
                tx_busy <= 1'b1;
                data_reg <= data_byte;
            end
            else if (bit_cnt == 4'd10 && bps_tick) begin
                tx_busy <= 1'b0;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            div_cnt <= 16'd0;
        else if (!tx_busy)
            div_cnt <= 16'd0;
        else if (bps_tick)
            div_cnt <= 16'd0;
        else
            div_cnt <= div_cnt + 16'd1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            bit_cnt <= 4'd0;
        else if (!tx_busy)
            bit_cnt <= 4'd0;
        else if (bps_tick)
            bit_cnt <= bit_cnt + 4'd1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            uart_tx <= 1'b1;
            tx_done <= 1'b0;
        end
        else begin
            tx_done <= 1'b0;
            if (!tx_busy) begin
                uart_tx <= 1'b1;
            end
            else if (bps_tick) begin
                case (bit_cnt)
                    4'd0: uart_tx <= 1'b0;
                    4'd1: uart_tx <= data_reg[0];
                    4'd2: uart_tx <= data_reg[1];
                    4'd3: uart_tx <= data_reg[2];
                    4'd4: uart_tx <= data_reg[3];
                    4'd5: uart_tx <= data_reg[4];
                    4'd6: uart_tx <= data_reg[5];
                    4'd7: uart_tx <= data_reg[6];
                    4'd8: uart_tx <= data_reg[7];
                    4'd9: uart_tx <= 1'b1;
                    4'd10: begin
                        uart_tx <= 1'b1;
                        tx_done <= 1'b1;
                    end
                    default: uart_tx <= 1'b1;
                endcase
            end
        end
    end

endmodule
