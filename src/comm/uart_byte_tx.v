// =============================================================================
// uart_byte_tx.v — UART 字节发送模块
// =============================================================================
// 功能：UART 发送，8N1 帧格式，LSB 先发
// 时钟: 50MHz (参数化), 波特率 115200 (参数化)
//
// 接口：
//   clk, rst_n     — 时钟与复位
//   send_en        — 发送使能脉冲
//   data_byte[7:0] — 待发送字节
//   uart_tx        — UART 发送引脚
//   tx_done        — 发送完成脉冲
//   tx_busy        — 发送忙标志
// =============================================================================

module uart_byte_tx #(
    parameter CLK_FREQ  = 50_000_000,  // 系统时钟频率
    parameter BAUD_RATE = 115200       // 波特率
) (
    input  wire       clk,              // 系统时钟
    input  wire       rst_n,            // 异步复位，低有效
    input  wire       send_en,          // 发送使能脉冲
    input  wire [7:0] data_byte,        // 待发送字节
    output reg        uart_tx,          // UART 发送引脚
    output reg        tx_done,          // 发送完成脉冲 (单周期)
    output reg        tx_busy           // 发送忙标志
);

    // ---- 波特率产生 ----
    // 分频系数 = CLK_FREQ / BAUD_RATE
    // 50MHz / 115200 = 50000000 / 115200 ≈ 434
    localparam BPS_LIMIT = CLK_FREQ / BAUD_RATE;

    reg [15:0] div_cnt;               // 分频计数器
    wire       bps_clk;               // 波特率时钟

    reg  [3:0] bps_cnt;               // 位计数器 (0~11, 共 12 拍)
    reg  [7:0] data_reg;              // 发送数据锁存

    // =================================================================
    // 发送状态
    // =================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            tx_busy <= 1'b0;
        else if (send_en)
            tx_busy <= 1'b1;
        else if (bps_cnt == 4'd11 && bps_clk)
            tx_busy <= 1'b0;
    end

    // =================================================================
    // 数据锁存
    // =================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            data_reg <= 8'd0;
        else if (send_en)
            data_reg <= data_byte;
    end

    // =================================================================
    // 波特率时钟产生
    // =================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            div_cnt <= 16'd0;
        else if (tx_busy) begin
            if (div_cnt == BPS_LIMIT - 1)
                div_cnt <= 16'd0;
            else
                div_cnt <= div_cnt + 1'b1;
        end
        else
            div_cnt <= 16'd0;
    end

    assign bps_clk = (div_cnt == 16'd1);

    // =================================================================
    // 位计数器
    // =================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            bps_cnt <= 4'd0;
        else if (tx_busy) begin
            if (bps_clk) begin
                if (bps_cnt == 4'd11)
                    bps_cnt <= 4'd0;
                else
                    bps_cnt <= bps_cnt + 1'b1;
            end
        end
        else
            bps_cnt <= 4'd0;
    end

    // =================================================================
    // tx_done 脉冲
    // =================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            tx_done <= 1'b0;
        else if (bps_cnt == 4'd11 && bps_clk)
            tx_done <= 1'b1;
        else
            tx_done <= 1'b0;
    end

    // =================================================================
    // UART 串行输出 (1 起始 + 8 数据 LSB + 1 停止)
    // =================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            uart_tx <= 1'b1;  // 空闲态高电平
        else if (tx_busy) begin
            case (bps_cnt)
                4'd0:  uart_tx <= 1'b1;           // 空闲 (第一个 bps 周期)
                4'd1:  uart_tx <= 1'b0;           // 起始位
                4'd2:  uart_tx <= data_reg[0];    // LSB
                4'd3:  uart_tx <= data_reg[1];
                4'd4:  uart_tx <= data_reg[2];
                4'd5:  uart_tx <= data_reg[3];
                4'd6:  uart_tx <= data_reg[4];
                4'd7:  uart_tx <= data_reg[5];
                4'd8:  uart_tx <= data_reg[6];
                4'd9:  uart_tx <= data_reg[7];    // MSB
                4'd10: uart_tx <= 1'b1;           // 停止位
                default: uart_tx <= 1'b1;
            endcase
        end
        else
            uart_tx <= 1'b1;
    end

endmodule
