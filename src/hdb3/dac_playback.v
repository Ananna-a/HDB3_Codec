// =============================================================================
// dac_playback.v - dual-channel DAC waveform playback
// =============================================================================
// Channel 0 stores HDB3 symbols. Channel 1 stores decoded bits.
// Symbol playback rate: 50 MHz / 500 = 100 kHz.
// =============================================================================

module dac_playback (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [7:0]  wr_data0,
    input  wire        wr_en0,
    input  wire [10:0] wr_addr0,

    input  wire [7:0]  wr_data1,
    input  wire        wr_en1,
    input  wire [10:0] wr_addr1,

    input  wire        load_done,
    input  wire [10:0] play_len0,
    input  wire [10:0] play_len1,
    input  wire        stop,

    output reg  [7:0]  DA0_Data,
    output reg  [7:0]  DA1_Data,
    output reg         DA_Clk
);

    wire [7:0] rd_data0;
    wire [7:0] rd_data1;
    reg [10:0] rd_addr0;
    reg [10:0] rd_addr1;
    reg        playing;
    reg [8:0]  tick_cnt;

    wire sym_tick = (tick_cnt == 9'd499);

    dac_wave_ram u_ram0 (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(wr_en0),
        .wr_addr(wr_addr0),
        .wr_data(wr_data0),
        .rd_addr(rd_addr0),
        .rd_data(rd_data0)
    );

    dac_wave_ram u_ram1 (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(wr_en1),
        .wr_addr(wr_addr1),
        .wr_data(wr_data1),
        .rd_addr(rd_addr1),
        .rd_data(rd_data1)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tick_cnt <= 9'd0;
            DA_Clk   <= 1'b0;
        end
        else if (playing) begin
            tick_cnt <= sym_tick ? 9'd0 : tick_cnt + 9'd1;
            DA_Clk   <= (tick_cnt >= 9'd250);
        end
        else begin
            tick_cnt <= 9'd0;
            DA_Clk   <= 1'b0;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            playing  <= 1'b0;
            rd_addr0 <= 11'd0;
            rd_addr1 <= 11'd0;
        end
        else if (stop) begin
            playing  <= 1'b0;
            rd_addr0 <= 11'd0;
            rd_addr1 <= 11'd0;
        end
        else if (load_done) begin
            playing  <= 1'b1;
            rd_addr0 <= 11'd0;
            rd_addr1 <= 11'd0;
        end
        else if (playing && sym_tick) begin
            rd_addr0 <= (play_len0 <= 11'd1 || rd_addr0 == play_len0 - 11'd1) ? 11'd0 : rd_addr0 + 11'd1;
            rd_addr1 <= (play_len1 <= 11'd1 || rd_addr1 == play_len1 - 11'd1) ? 11'd0 : rd_addr1 + 11'd1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            DA0_Data <= 8'h80;
            DA1_Data <= 8'h80;
        end
        else if (!playing) begin
            DA0_Data <= 8'h80;
            DA1_Data <= 8'h80;
        end
        else begin
            case (rd_data0)
                8'h00: DA0_Data <= 8'h80;
                8'h01,
                8'h03,
                8'h05: DA0_Data <= 8'hFF;
                8'h02,
                8'h04,
                8'h06: DA0_Data <= 8'h00;
                default: DA0_Data <= 8'h80;
            endcase

            DA1_Data <= (rd_data1 == 8'h00) ? 8'h80 : 8'hFF;
        end
    end

endmodule
