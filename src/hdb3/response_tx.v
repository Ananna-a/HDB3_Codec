// =============================================================================
// response_tx.v — 应答帧发送器
// =============================================================================
// 帧结构: AA 55 | cmd | status | len_l | len_h | payload[0..N-1] | cs
//   校验和: cs = (cmd + status + len_l + len_h + Σpayload) & 0xFF
//
// 用法: 顶层在 start 前通过 wr_en/wr_addr/wr_data 写入 payload 数据到内部缓冲,
//       然后设置 resp_cmd/resp_status/resp_len 并拉高 start
// =============================================================================

module response_tx (
    input  wire       clk,              // 系统时钟 50MHz
    input  wire       rst_n,            // 复位, 低有效

    // 启动
    input  wire       start,            // 启动发送脉冲

    // 应答帧参数
    input  wire [7:0] resp_cmd,         // 应答命令码
    input  wire [7:0] resp_status,      // 状态码
    input  wire [7:0] resp_len,         // payload 字节数

    // payload 写入接口 (在 start 之前写入)
    input  wire [7:0] wr_data,          // 写入数据
    input  wire [7:0] wr_addr,          // 写入地址
    input  wire       wr_en,            // 写使能

    // UART 发送接口
    output reg        send_en,          // 发送使能
    output reg  [7:0] send_data,        // 待发送字节
    input  wire       tx_done,          // 发送完成脉冲
    input  wire       tx_busy,          // 发送忙标志

    // 状态
    output reg        resp_done         // 应答发送完成
);

    // ---- 内部 payload 缓冲 ----
    reg [7:0] payload_buf [0:255];
    
    // 写入
    always @(posedge clk) begin
        if (wr_en) payload_buf[wr_addr] <= wr_data;
    end

    // ---- 状态定义 ----
    localparam S_IDLE    = 2'd0;  // 空闲
    localparam S_SEND    = 2'd1;  // 逐个发送字节
    localparam S_WAIT    = 2'd2;  // 等待 UART 完成
    localparam S_DONE    = 2'd3;  // 完成

    reg [1:0]  state, next_state;
    reg [7:0]  byte_idx;             // 当前发送字节索引
    reg [7:0]  total_bytes;          // 总发送字节数
    reg [7:0]  cs_val;               // 校验和累加
    reg        first_send;           // 第一次发送标志

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
            S_IDLE:  if (start) next_state = S_SEND;
            S_SEND:  next_state = S_WAIT;
            S_WAIT:  if (tx_done) begin
                         if (byte_idx == total_bytes) next_state = S_DONE;
                         else next_state = S_SEND;
                     end
            S_DONE:  next_state = S_IDLE;
            default: next_state = S_IDLE;
        endcase
    end

    // ---- 发送控制 ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            send_en     <= 1'b0;
            send_data   <= 8'd0;
            byte_idx    <= 8'd0;
            total_bytes <= 8'd0;
            cs_val      <= 8'd0;
            first_send  <= 1'b0;
            resp_done   <= 1'b0;
        end
        else begin
            send_en   <= 1'b0;
            resp_done <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        total_bytes <= 8'd6 + resp_len + 8'd1;  // 帧头2+cmd+status+len2 + payload + cs
                        byte_idx    <= 8'd0;
                        first_send  <= 1'b1;
                        cs_val      <= resp_cmd + resp_status + resp_len;
                    end
                end

                S_SEND: begin
                    send_en <= 1'b1;

                    case (byte_idx)
                        8'd0:  send_data <= 8'hAA;
                        8'd1:  send_data <= 8'h55;
                        8'd2:  send_data <= resp_cmd;
                        8'd3:  send_data <= resp_status;
                        8'd4:  send_data <= resp_len;
                        8'd5:  send_data <= 8'h00;  // len_h = 0
                        default: begin
                            if (byte_idx < total_bytes - 8'd1) begin
                                // payload 数据
                                send_data <= payload_buf[byte_idx - 8'd6];
                                cs_val    <= cs_val + payload_buf[byte_idx - 8'd6];
                            end
                            else begin
                                // 校验和
                                send_data <= cs_val;
                            end
                        end
                    endcase
                    byte_idx <= byte_idx + 8'd1;
                end

                S_WAIT: begin
                    // 等待 tx_done
                end

                S_DONE: begin
                    resp_done <= 1'b1;
                end
            endcase
        end
    end

endmodule
