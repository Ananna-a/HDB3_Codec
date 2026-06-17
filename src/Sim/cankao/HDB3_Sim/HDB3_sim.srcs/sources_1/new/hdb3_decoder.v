`timescale 1ns / 1ps

// HDB3 解码器
// 输入为 HDB3 三电平码元的双线数字表示。
// 当检测到与前一个非零码元同极性的 V 码时，将当前及前三个码元还原为 0000。
module hdb3_decoder(
    input  wire clk,
    input  wire rst_n,
    input  wire bit_tick,
    input  wire code_pos,
    input  wire code_neg,
    input  wire code_valid,
    output reg  data_out,
    output reg  data_valid,
    output reg  code_error
);

    reg [2:0] bit_delay;
    reg [2:0] valid_delay;
    reg last_pol;
    reg have_last;

    reg nonzero;
    reg cur_pol;
    reg violation;
    reg raw_bit;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bit_delay   <= 3'b000;
            valid_delay <= 3'b000;
            last_pol    <= 1'b0;
            have_last   <= 1'b0;
            data_out    <= 1'b0;
            data_valid  <= 1'b0;
            code_error  <= 1'b0;
        end else if (bit_tick) begin
            nonzero   = code_pos ^ code_neg;
            cur_pol   = code_pos;
            violation = code_valid && nonzero && have_last && (cur_pol == last_pol);
            raw_bit   = code_valid && nonzero;

            code_error <= code_valid && code_pos && code_neg;

            if (code_valid && nonzero) begin
                last_pol  <= cur_pol;
                have_last <= 1'b1;
            end

            if (violation) begin
                data_out    <= 1'b0;
                data_valid  <= 1'b1;
                bit_delay   <= 3'b000;
                valid_delay <= 3'b111;
            end else begin
                data_out    <= bit_delay[2];
                data_valid  <= valid_delay[2];
                bit_delay   <= {bit_delay[1:0], raw_bit};
                valid_delay <= {valid_delay[1:0], code_valid};
            end
        end else begin
            data_valid <= 1'b0;
            code_error <= 1'b0;
        end
    end

endmodule
