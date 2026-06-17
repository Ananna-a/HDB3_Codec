// =============================================================================
// uart_byte_rx.v — UART 字节接收模块
// =============================================================================
// 功能：16 倍过采样 UART 接收，8N1 帧格式
// 时钟: 50MHz (参数化), 波特率 115200 (参数化)
//
// 接口：
//   clk, rst_n        — 时钟与复位
//   uart_rx           — UART 接收引脚
//   data_byte[7:0]    — 接收到的字节
//   rx_done           — 接收完成脉冲 (单周期)
// =============================================================================

module uart_byte_rx #(
    parameter CLK_FREQ   = 50_000_000,  // 系统时钟频率
    parameter BAUD_RATE  = 115200,      // 波特率
    parameter OVERSAMPLE = 16           // 过采样倍率
) (
    input  wire       clk,             // 系统时钟
    input  wire       rst_n,           // 异步复位，低有效
    input  wire       uart_rx,         // UART 接收引脚
    output reg  [7:0] data_byte,       // 接收到的字节数据
    output reg        rx_done          // 接收完成脉冲 (单周期高电平)
);

    // ---- 同步寄存器 (消除亚稳态) ----
    reg uart_rx_sync1;
    reg uart_rx_sync2;

    // ---- 边沿检测 ----
    reg uart_rx_reg1;
    reg uart_rx_reg2;
    wire uart_rx_nedge;                // 下降沿 (起始位检测)

    // ---- 波特率产生 ----
    // 分频系数 = CLK_FREQ / (BAUD_RATE * OVERSAMPLE)
    // 50MHz / (115200 * 16) = 50000000 / 1843200 ≈ 27
    localparam BPS_LIMIT = CLK_FREQ / (BAUD_RATE * OVERSAMPLE);

    reg [15:0] div_cnt;                // 分频计数器
    wire       bps_clk;                // 过采样时钟 (波特率 × 16)

    // ---- 采样计数器 ----
    reg  [7:0] bps_cnt;                // 位采样计数器 (0~159, 10bit×16-1)
    reg        uart_state;             // 接收状态 (0=空闲, 1=接收中)

    // ---- 16 倍过采样数据累计 (抗噪) ----
    reg  [2:0] start_bit_acc;          // 起始位采样累计 (6 次采样中取多数)
    reg  [2:0] stop_bit_acc;           // 停止位采样累计
    reg  [2:0] data_bit_acc [0:7];     // 8 个数据位采样累计

    // =================================================================
    // 同步 + 边沿检测
    // =================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            uart_rx_sync1 <= 1'b0;
            uart_rx_sync2 <= 1'b0;
            uart_rx_reg1  <= 1'b0;
            uart_rx_reg2  <= 1'b0;
        end
        else begin
            uart_rx_sync1 <= uart_rx;
            uart_rx_sync2 <= uart_rx_sync1;
            uart_rx_reg1  <= uart_rx_sync2;
            uart_rx_reg2  <= uart_rx_reg1;
        end
    end

    assign uart_rx_nedge = !uart_rx_reg1 && uart_rx_reg2;

    // =================================================================
    // 过采样时钟产生
    // =================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            div_cnt <= 16'd0;
        else if (uart_state) begin
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
    // 位采样计数器 (bps_cnt)
    // 一个 UART 帧 = 1 起始 + 8 数据 + 1 停止 = 10 bit
    // 每 bit 16 次过采样 → 10 * 16 = 160, 计数 0~159
    // =================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            bps_cnt <= 8'd0;
        else if (bps_cnt == 8'd159 || (bps_cnt == 8'd12 && (start_bit_acc > 2)))
            bps_cnt <= 8'd0;
        else if (bps_clk)
            bps_cnt <= bps_cnt + 1'b1;
    end

    // =================================================================
    // 16 倍过采样数据采集 — 每 bit 6 次中间采样取多数
    // 起始位: bps_cnt=6~11, 数据位0: 22~27, 数据位1: 38~43, ...
    // =================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            start_bit_acc <= 3'd0;
            stop_bit_acc  <= 3'd0;
            data_bit_acc[0] <= 3'd0;
            data_bit_acc[1] <= 3'd0;
            data_bit_acc[2] <= 3'd0;
            data_bit_acc[3] <= 3'd0;
            data_bit_acc[4] <= 3'd0;
            data_bit_acc[5] <= 3'd0;
            data_bit_acc[6] <= 3'd0;
            data_bit_acc[7] <= 3'd0;
        end
        else if (bps_clk) begin
            case (bps_cnt)
                // 起始位采样 bps_cnt = 6,7,8,9,10,11
                6,7,8,9,10,11:
                    start_bit_acc <= start_bit_acc + uart_rx_sync2;
                // 数据位 0: bps_cnt = 22~27
                22,23,24,25,26,27:
                    data_bit_acc[0] <= data_bit_acc[0] + uart_rx_sync2;
                // 数据位 1: bps_cnt = 38~43
                38,39,40,41,42,43:
                    data_bit_acc[1] <= data_bit_acc[1] + uart_rx_sync2;
                // 数据位 2: bps_cnt = 54~59
                54,55,56,57,58,59:
                    data_bit_acc[2] <= data_bit_acc[2] + uart_rx_sync2;
                // 数据位 3: bps_cnt = 70~75
                70,71,72,73,74,75:
                    data_bit_acc[3] <= data_bit_acc[3] + uart_rx_sync2;
                // 数据位 4: bps_cnt = 86~91
                86,87,88,89,90,91:
                    data_bit_acc[4] <= data_bit_acc[4] + uart_rx_sync2;
                // 数据位 5: bps_cnt = 102~107
                102,103,104,105,106,107:
                    data_bit_acc[5] <= data_bit_acc[5] + uart_rx_sync2;
                // 数据位 6: bps_cnt = 118~123
                118,119,120,121,122,123:
                    data_bit_acc[6] <= data_bit_acc[6] + uart_rx_sync2;
                // 数据位 7: bps_cnt = 134~139
                134,135,136,137,138,139:
                    data_bit_acc[7] <= data_bit_acc[7] + uart_rx_sync2;
                // 停止位采样 bps_cnt = 150~155
                150,151,152,153,154,155:
                    stop_bit_acc <= stop_bit_acc + uart_rx_sync2;
                default: ;  // 保持
            endcase
        end
    end

    // =================================================================
    // 数据输出 (采样结束, 取多数表决值)
    // =================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            data_byte <= 8'd0;
        else if (bps_cnt == 8'd159) begin
            data_byte[0] <= data_bit_acc[0][2];  // 3 bit 多数表决: >3 → 1
            data_byte[1] <= data_bit_acc[1][2];
            data_byte[2] <= data_bit_acc[2][2];
            data_byte[3] <= data_bit_acc[3][2];
            data_byte[4] <= data_bit_acc[4][2];
            data_byte[5] <= data_bit_acc[5][2];
            data_byte[6] <= data_bit_acc[6][2];
            data_byte[7] <= data_bit_acc[7][2];
        end
    end

    // =================================================================
    // rx_done 脉冲
    // =================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rx_done <= 1'b0;
        else if (bps_cnt == 8'd159)
            rx_done <= 1'b1;
        else
            rx_done <= 1'b0;
    end

    // =================================================================
    // 接收状态机 (uart_state)
    // =================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            uart_state <= 1'b0;
        else if (uart_rx_nedge)
            uart_state <= 1'b1;
        else if (rx_done || (bps_cnt == 8'd12 && (start_bit_acc > 2)) || (bps_cnt == 8'd155 && (stop_bit_acc < 3)))
            uart_state <= 1'b0;
    end

endmodule
