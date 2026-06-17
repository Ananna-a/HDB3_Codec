`timescale 1ns / 1ps

module tb_hdb3;

    reg clk;
    reg rst_n;
    reg data_in;

    wire hdb3_pos;
    wire hdb3_neg;
    wire hdb3_sym_pos;
    wire hdb3_sym_neg;
    wire hdb3_valid;
    wire data_out;
    wire data_valid;
    wire code_error;

    integer i;
    integer in_count;
    integer out_count;
    integer err_count;

    // 固定短序列，便于观察开头、四连零替换和后续极性交替。
    // 输入序列：1 0 0 0 0 1 0 0 0 0 1 1 1 1 0 0
    reg [0:15] test_bits;
    reg [0:31] ref_bits;

    hdb3_top dut(
        .clk(clk),
        .rst_n(rst_n),
        .data_in(data_in),
        .hdb3_pos(hdb3_pos),
        .hdb3_neg(hdb3_neg),
        .hdb3_sym_pos(hdb3_sym_pos),
        .hdb3_sym_neg(hdb3_sym_neg),
        .hdb3_valid(hdb3_valid),
        .data_out(data_out),
        .data_valid(data_valid),
        .code_error(code_error)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;     // 半码元时钟，码元周期为 20 ns
    end

    initial begin
        test_bits = 16'b1000010000111100;

        rst_n = 1'b0;
        data_in = test_bits[0];
        in_count = 0;
        out_count = 0;
        err_count = 0;

        for (i = 0; i < 32; i = i + 1) begin
            ref_bits[i] = 1'b0;
        end

        #37;
        rst_n = 1'b1;
        ref_bits[in_count] = test_bits[0];
        in_count = in_count + 1;

        for (i = 1; i < 16; i = i + 1) begin
            @(posedge dut.phase);
            #1;
            data_in = test_bits[i];
            ref_bits[in_count] = test_bits[i];
            in_count = in_count + 1;
        end

        // 编码器和解码器都有流水线延迟，所以最后一位输入后要多等一段时间。
        // 当前 clk 是半码元时钟，16 个 clk 周期 = 8 个码元周期，足够看到完整译码输出。
        repeat (16) @(posedge clk);

        if (err_count == 0) begin
            $display("HDB3 短序列仿真结束，已比较位数=%0d", out_count);
        end else begin
            $display("HDB3 短序列仿真发现错误，错误数=%0d", err_count);
        end
        $finish;
    end

    always @(negedge clk) begin
        if (rst_n && data_valid && (out_count < in_count)) begin
            if (data_out !== ref_bits[out_count]) begin
                $display("解码不匹配：序号=%0d 期望=%0b 实际=%0b 时间=%0t",
                         out_count, ref_bits[out_count], data_out, $time);
                err_count = err_count + 1;
            end
            out_count = out_count + 1;
        end

        if (code_error) begin
            $display("非法 HDB3 双线状态：时间=%0t", $time);
            err_count = err_count + 1;
        end
    end

endmodule
