`timescale 1ns / 1ps

// HDB3 编译码顶层
// clk 使用 2 倍码元时钟：一个时钟周期对应半个码元。
// 顶层内部产生 bit_tick，并在每个码元前半段输出归零脉冲。
module hdb3_top(
    input  wire clk,
    input  wire rst_n,
    input  wire data_in,
    output wire hdb3_pos,
    output wire hdb3_neg,
    output wire hdb3_sym_pos,
    output wire hdb3_sym_neg,
    output wire hdb3_valid,
    output wire data_out,
    output wire data_valid,
    output wire code_error
);

    reg phase;
    wire bit_tick;

    assign bit_tick = phase;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase <= 1'b1;
        end else begin
            phase <= ~phase;
        end
    end

    hdb3_encoder u_encoder(
        .clk(clk),
        .rst_n(rst_n),
        .bit_tick(bit_tick),
        .data_in(data_in),
        .code_pos(hdb3_sym_pos),
        .code_neg(hdb3_sym_neg),
        .code_valid(hdb3_valid)
    );

    // 双极性归零码：只在码元前半段输出正/负脉冲，后半段回到 0。
    assign hdb3_pos = hdb3_valid && (phase == 1'b0) && hdb3_sym_pos;
    assign hdb3_neg = hdb3_valid && (phase == 1'b0) && hdb3_sym_neg;

    hdb3_decoder u_decoder(
        .clk(clk),
        .rst_n(rst_n),
        .bit_tick(bit_tick),
        .code_pos(hdb3_sym_pos),
        .code_neg(hdb3_sym_neg),
        .code_valid(hdb3_valid),
        .data_out(data_out),
        .data_valid(data_valid),
        .code_error(code_error)
    );

endmodule
