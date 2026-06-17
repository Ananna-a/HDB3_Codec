`timescale 1ns / 1ps

// HDB3 编码器
// 输入为单极性二进制码 data_in。
// 输出用两根线表示三电平码元：
//   code_pos=1, code_neg=0 表示 +V 码元
//   code_pos=0, code_neg=1 表示 -V 码元
//   code_pos=0, code_neg=0 表示  0 码元
// 归零脉冲由顶层用半码元相位门控产生，本模块只产生完整码元的极性。
module hdb3_encoder(
    input  wire clk,
    input  wire rst_n,
    input  wire bit_tick,
    input  wire data_in,
    output reg  code_pos,
    output reg  code_neg,
    output reg  code_valid
);

    reg [2:0] data_delay;
    reg [1:0] zero_cnt;
    reg [2:0] valid_cnt;

    reg last_pol;       // 0 表示上一个非零码元为负，1 表示为正
    reg ones_parity;    // 两次破坏点之间普通 1 码元个数的奇偶

    reg [2:0] sched_v;
    reg [2:0] sched_pos;

    reg out_pos_next;
    reg out_neg_next;
    reg subst_now;
    reg new_pol;
    reg b_pol;
    reg v_pol;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_delay  <= 3'b000;
            zero_cnt    <= 2'd0;
            valid_cnt   <= 3'd0;
            last_pol    <= 1'b0;
            ones_parity <= 1'b0;
            sched_v     <= 3'b000;
            sched_pos   <= 3'b000;
            code_pos    <= 1'b0;
            code_neg    <= 1'b0;
            code_valid  <= 1'b0;
        end else if (bit_tick) begin
            subst_now = (zero_cnt == 2'd3) && (data_in == 1'b0);
            out_pos_next = 1'b0;
            out_neg_next = 1'b0;

            if (subst_now) begin
                if (ones_parity) begin
                    // 000V：前三个 0 保持为 0，第四个 0 变为破坏码 V。
                    v_pol = last_pol;
                    sched_v   <= 3'b100;
                    sched_pos <= {v_pol, 2'b00};
                    out_pos_next = 1'b0;
                    out_neg_next = 1'b0;
                end else begin
                    // B00V：B 为平衡码，V 与 B 同极性，形成 AMI 极性破坏。
                    b_pol = ~last_pol;
                    v_pol = b_pol;
                    sched_v   <= 3'b100;
                    sched_pos <= {v_pol, 2'b00};
                    out_pos_next = b_pol;
                    out_neg_next = ~b_pol;
                    last_pol     <= b_pol;
                end
                ones_parity <= 1'b0;
            end else if (sched_v[0]) begin
                out_pos_next = sched_pos[0];
                out_neg_next = ~sched_pos[0];
                sched_v   <= {1'b0, sched_v[2:1]};
                sched_pos   <= {1'b0, sched_pos[2:1]};
            end else begin
                sched_v   <= {1'b0, sched_v[2:1]};
                sched_pos   <= {1'b0, sched_pos[2:1]};

                if (data_delay[2]) begin
                    new_pol = ~last_pol;
                    out_pos_next = new_pol;
                    out_neg_next = ~new_pol;
                    last_pol <= new_pol;
                    ones_parity <= ~ones_parity;
                end
            end

            if (data_in) begin
                zero_cnt <= 2'd0;
            end else if (subst_now) begin
                zero_cnt <= 2'd0;
            end else begin
                zero_cnt <= zero_cnt + 2'd1;
            end

            data_delay <= {data_delay[1:0], data_in};

            if (valid_cnt < 3'd4) begin
                valid_cnt <= valid_cnt + 3'd1;
            end

            code_pos   <= out_pos_next;
            code_neg   <= out_neg_next;
            code_valid <= (valid_cnt >= 3'd3);
        end
    end

endmodule
