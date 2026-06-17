// =============================================================================
// dac_wave_ram.v — DAC 波形缓冲 RAM (同步写/同步读)
// =============================================================================
// 参考 arb_wave_ram_simple.v 写法：纯 reg 数组 + 独立读写时序
// 深度 2048 x 8bit，GowinSyn 综合时自动推断为 BSRAM
// 若推断失败再改用 Gowin IP Generator 例化
// =============================================================================

module dac_wave_ram (
    input  wire        clk,              // 读写共用时钟 50MHz
    input  wire        rst_n,            // 复位, 低有效

    // 写端口
    input  wire        wr_en,            // 写使能
    input  wire [10:0] wr_addr,          // 写地址 (0~2047)
    input  wire [7:0]  wr_data,          // 写数据

    // 读端口
    input  wire [10:0] rd_addr,          // 读地址 (0~2047)
    output reg  [7:0]  rd_data           // 读数据
);

    // 存储数组 — 综合工具自动推断为 BSRAM
    reg [7:0] mem [0:2047];

    // 同步写 (与 arb_wave_ram_simple.v 写法一致)
    always @(posedge clk) begin
        if (wr_en)
            mem[wr_addr] <= wr_data;
    end

    // 同步读 (读延迟 1 周期)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rd_data <= 8'h80;  // 复位值: 0V 中点
        else
            rd_data <= mem[rd_addr];
    end

endmodule
