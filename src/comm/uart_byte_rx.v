// =============================================================================
// uart_byte_rx.v - 8N1 UART byte receiver
// Clock: 50 MHz by default, baud: 115200 by default.
// =============================================================================

module uart_byte_rx #(
    parameter CLK_FREQ   = 50_000_000,
    parameter BAUD_RATE  = 115200,
    parameter OVERSAMPLE = 16
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       uart_rx,
    output reg  [7:0] data_byte,
    output reg        rx_done
);

    localparam SAMPLE_DIV = CLK_FREQ / (BAUD_RATE * OVERSAMPLE);

    reg uart_rx_sync1;
    reg uart_rx_sync2;
    reg uart_rx_d1;
    reg uart_rx_d2;
    wire start_edge = uart_rx_d2 && !uart_rx_d1;

    reg        receiving;
    reg [15:0] div_cnt;
    reg [7:0]  sample_cnt;
    wire       sample_tick = (div_cnt == SAMPLE_DIV - 1);

    reg [2:0] start_acc;
    reg [2:0] stop_acc;
    reg [2:0] data_acc [0:7];

    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            uart_rx_sync1 <= 1'b1;
            uart_rx_sync2 <= 1'b1;
            uart_rx_d1    <= 1'b1;
            uart_rx_d2    <= 1'b1;
        end
        else begin
            uart_rx_sync1 <= uart_rx;
            uart_rx_sync2 <= uart_rx_sync1;
            uart_rx_d1    <= uart_rx_sync2;
            uart_rx_d2    <= uart_rx_d1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            div_cnt <= 16'd0;
        else if (!receiving)
            div_cnt <= 16'd0;
        else if (sample_tick)
            div_cnt <= 16'd0;
        else
            div_cnt <= div_cnt + 16'd1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            receiving  <= 1'b0;
            sample_cnt <= 8'd0;
            rx_done    <= 1'b0;
            data_byte  <= 8'd0;
            start_acc  <= 3'd0;
            stop_acc   <= 3'd0;
            for (i = 0; i < 8; i = i + 1)
                data_acc[i] <= 3'd0;
        end
        else begin
            rx_done <= 1'b0;

            if (!receiving) begin
                sample_cnt <= 8'd0;
                if (start_edge) begin
                    receiving <= 1'b1;
                    start_acc <= 3'd0;
                    stop_acc  <= 3'd0;
                    for (i = 0; i < 8; i = i + 1)
                        data_acc[i] <= 3'd0;
                end
            end
            else if (sample_tick) begin
                case (sample_cnt)
                    8'd6,  8'd7,  8'd8,  8'd9,  8'd10, 8'd11: start_acc <= start_acc + uart_rx_sync2;
                    8'd22, 8'd23, 8'd24, 8'd25, 8'd26, 8'd27: data_acc[0] <= data_acc[0] + uart_rx_sync2;
                    8'd38, 8'd39, 8'd40, 8'd41, 8'd42, 8'd43: data_acc[1] <= data_acc[1] + uart_rx_sync2;
                    8'd54, 8'd55, 8'd56, 8'd57, 8'd58, 8'd59: data_acc[2] <= data_acc[2] + uart_rx_sync2;
                    8'd70, 8'd71, 8'd72, 8'd73, 8'd74, 8'd75: data_acc[3] <= data_acc[3] + uart_rx_sync2;
                    8'd86, 8'd87, 8'd88, 8'd89, 8'd90, 8'd91: data_acc[4] <= data_acc[4] + uart_rx_sync2;
                    8'd102,8'd103,8'd104,8'd105,8'd106,8'd107: data_acc[5] <= data_acc[5] + uart_rx_sync2;
                    8'd118,8'd119,8'd120,8'd121,8'd122,8'd123: data_acc[6] <= data_acc[6] + uart_rx_sync2;
                    8'd134,8'd135,8'd136,8'd137,8'd138,8'd139: data_acc[7] <= data_acc[7] + uart_rx_sync2;
                    8'd150,8'd151,8'd152,8'd153,8'd154,8'd155: stop_acc <= stop_acc + uart_rx_sync2;
                    default: ;
                endcase

                if (sample_cnt == 8'd12 && start_acc > 3'd2) begin
                    receiving <= 1'b0;
                    sample_cnt <= 8'd0;
                end
                else if (sample_cnt == 8'd155 && stop_acc < 3'd3) begin
                    receiving <= 1'b0;
                    sample_cnt <= 8'd0;
                end
                else if (sample_cnt == 8'd159) begin
                    data_byte[0] <= data_acc[0][2];
                    data_byte[1] <= data_acc[1][2];
                    data_byte[2] <= data_acc[2][2];
                    data_byte[3] <= data_acc[3][2];
                    data_byte[4] <= data_acc[4][2];
                    data_byte[5] <= data_acc[5][2];
                    data_byte[6] <= data_acc[6][2];
                    data_byte[7] <= data_acc[7][2];
                    rx_done      <= 1'b1;
                    receiving    <= 1'b0;
                    sample_cnt   <= 8'd0;
                end
                else begin
                    sample_cnt <= sample_cnt + 8'd1;
                end
            end
        end
    end

endmodule
