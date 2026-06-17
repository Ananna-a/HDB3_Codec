// =============================================================================
// dac_playback.v - dual-channel DAC waveform playback
// =============================================================================
// Channel 0 stores HDB3 symbols. Channel 1 stores decoded bits.
// Symbol playback rate: 50 MHz / 500 = 100 ksym/s.
// DAC sample clock: 200 kHz, two samples per symbol.
// CH0 is rendered as RZ: first half pulse, second half zero.
// CH1 keeps the decoded bit value for the full symbol width.
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
    output reg         DA_Clk,
    output wire        playing_out
);

    localparam [7:0] DAC_ZERO = 8'h80;
    localparam [7:0] DAC_POS  = 8'h00;
    localparam [7:0] DAC_NEG  = 8'hFF;

    assign playing_out = playing;

    wire [7:0] rd_data0;
    wire [7:0] rd_data1;
    reg [10:0] rd_addr0;
    reg [10:0] rd_addr1;
    reg        playing;
    reg [7:0]  sample_cnt;
    reg        rz_phase;

    wire half_tick = (sample_cnt == 8'd249);
    wire addr_prep_tick = (sample_cnt == 8'd248);

    function [7:0] hdb3_symbol_to_dac;
        input [7:0] sym;
        begin
            case (sym)
                8'h01,
                8'h03,
                8'h05: hdb3_symbol_to_dac = DAC_POS;
                8'h02,
                8'h04,
                8'h06: hdb3_symbol_to_dac = DAC_NEG;
                default: hdb3_symbol_to_dac = DAC_ZERO;
            endcase
        end
    endfunction

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
            sample_cnt <= 8'd0;
            rz_phase   <= 1'b0;
            DA_Clk     <= 1'b0;
        end
        else if (playing) begin
            sample_cnt <= half_tick ? 8'd0 : sample_cnt + 8'd1;
            if (half_tick)
                rz_phase <= ~rz_phase;
            DA_Clk <= (sample_cnt >= 8'd125);
        end
        else begin
            sample_cnt <= 8'd0;
            rz_phase   <= 1'b0;
            DA_Clk     <= 1'b0;
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
        else if (playing && rz_phase && addr_prep_tick) begin
            rd_addr0 <= (play_len0 <= 11'd1 || rd_addr0 == play_len0 - 11'd1) ? 11'd0 : rd_addr0 + 11'd1;
            rd_addr1 <= (play_len1 <= 11'd1 || rd_addr1 == play_len1 - 11'd1) ? 11'd0 : rd_addr1 + 11'd1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            DA0_Data <= DAC_ZERO;
            DA1_Data <= DAC_ZERO;
        end
        else if (!playing) begin
            DA0_Data <= DAC_ZERO;
            DA1_Data <= DAC_ZERO;
        end
        else if (sample_cnt == 8'd0) begin
            DA0_Data <= rz_phase ? DAC_ZERO : hdb3_symbol_to_dac(rd_data0);
            DA1_Data <= (rd_data1 == 8'h00) ? DAC_ZERO : DAC_POS;
        end
    end

endmodule
