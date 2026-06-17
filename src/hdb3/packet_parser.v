// =============================================================================
// packet_parser.v — 55 AA 帧协议解析器
// =============================================================================
// 功能: 从 UART 字节流中解析命令帧, 校验通过后输出 cmd_code 和 payload
//
// 帧结构: 55 AA | cmd | len_l | len_h | payload[0..N-1] | cs
//   校验和: cs = (cmd + len_l + len_h + Σpayload) & 0xFF
//
// 抗干扰: S_HEAD2 收到非 AA 时, 若为 55 则保持 S_HEAD2 (帧头重叠保护)
// =============================================================================

module packet_parser (
    input  wire       clk,              // 系统时钟 50MHz
    input  wire       rst_n,            // 复位, 低有效

    // UART 接收接口
    input  wire [7:0] rx_data,          // 接收到的字节
    input  wire       rx_valid,         // 字节有效脉冲

    // 解析结果
    output reg  [7:0] cmd_code,         // 命令码
    output reg  [7:0] payload_len,      // payload 字节数 (低字节)
    // payload 逐字节输出 (顶层需自行存入内部数组)
    output reg  [7:0] payload_data,     // payload 字节数据
    output reg        payload_valid,    // payload 字节有效 (单周期)
    output reg        cmd_done,         // 解析成功脉冲
    output reg        cmd_error         // 解析失败脉冲
);

    // ---- 状态定义 ----
    localparam S_IDLE    = 4'd0;  // 等待 0x55
    localparam S_HEAD2   = 4'd1;  // 等待 0xAA
    localparam S_CMD     = 4'd2;  // 接收命令码
    localparam S_LEN_L   = 4'd3;  // 接收长度低字节
    localparam S_LEN_H   = 4'd4;  // 接收长度高字节
    localparam S_PAYLOAD = 4'd5;  // 接收 payload
    localparam S_CS      = 4'd6;  // 校验和验证
    localparam S_DONE    = 4'd7;  // 完成
    localparam S_ERROR   = 4'd8;  // 错误

    reg [3:0] state, next_state;
    reg [7:0] cs_calc;              // 累加计算的校验和
    reg [15:0] payload_total;       // payload 总字节数
    reg [7:0] payload_idx;          // payload 接收索引

    // ---- 状态转移 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= S_IDLE;
        else
            state <= next_state;
    end

    always @(*) begin
        next_state = state;
        case (state)
            S_IDLE: begin
                if (rx_valid && rx_data == 8'h55)
                    next_state = S_HEAD2;
            end
            S_HEAD2: begin
                if (rx_valid) begin
                    if (rx_data == 8'hAA)
                        next_state = S_CMD;
                    else if (rx_data == 8'h55)
                        next_state = S_HEAD2;  // 帧头重叠保护
                    else
                        next_state = S_IDLE;
                end
            end
            S_CMD:     if (rx_valid) next_state = S_LEN_L;
            S_LEN_L:   if (rx_valid) next_state = S_LEN_H;
            S_LEN_H: begin
                if (rx_valid) begin
                    if (payload_total > 0)
                        next_state = S_PAYLOAD;
                    else
                        next_state = S_CS;
                end
            end
            S_PAYLOAD: begin
                if (rx_valid && payload_idx == payload_total - 1)
                    next_state = S_CS;
            end
            S_CS: begin
                if (rx_valid) begin
                    if (cs_calc == rx_data)
                        next_state = S_DONE;
                    else
                        next_state = S_ERROR;
                end
            end
            S_DONE:  next_state = S_IDLE;
            S_ERROR: next_state = S_IDLE;
            default: next_state = S_IDLE;
        endcase
    end

    // ---- 数据处理 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cs_calc       <= 8'd0;
            payload_total <= 16'd0;
            payload_idx   <= 8'd0;
            cmd_code      <= 8'd0;
            payload_len   <= 8'd0;
            payload_data  <= 8'd0;
            payload_valid <= 1'b0;
            cmd_done      <= 1'b0;
            cmd_error     <= 1'b0;
        end
        else begin
            cmd_done      <= 1'b0;
            cmd_error     <= 1'b0;
            payload_valid <= 1'b0;

            case (state)
                S_IDLE: begin
                    cs_calc     <= 8'd0;
                    payload_idx <= 8'd0;
                end

                S_CMD: begin
                    if (rx_valid) begin
                        cmd_code <= rx_data;
                        cs_calc  <= rx_data;
                    end
                end

                S_LEN_L: begin
                    if (rx_valid) begin
                        payload_total[7:0] <= rx_data;
                        cs_calc <= cs_calc + rx_data;
                    end
                end

                S_LEN_H: begin
                    if (rx_valid) begin
                        payload_total[15:8] <= rx_data;
                        cs_calc <= cs_calc + rx_data;
                    end
                end

                S_PAYLOAD: begin
                    if (rx_valid) begin
                        payload_data  <= rx_data;
                        payload_valid <= 1'b1;
                        cs_calc <= cs_calc + rx_data;
                        payload_idx <= payload_idx + 8'd1;
                    end
                end

                S_DONE: begin
                    payload_len <= payload_total[7:0];
                    cmd_done    <= 1'b1;
                end

                S_ERROR: begin
                    cmd_error <= 1'b1;
                end
            endcase
        end
    end

endmodule
