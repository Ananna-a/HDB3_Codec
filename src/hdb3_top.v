// =============================================================================
// hdb3_top.v — HDB3 编解码器 FPGA 顶层模块
// =============================================================================
// 功能: 例化所有子模块, 主控状态机调度命令/编码/解码/DAC/应答全流程
//
// 数据流 (编码): RX → parser → encoder → DAC0 + 回环decoder → DAC1 → 应答
// 数据流 (解码): RX → parser → decoder → DAC1 + DAC0(输入符号显示) → 应答
// =============================================================================

module hdb3_top (
    input  wire       clk_50m,          // 50MHz 系统时钟
    input  wire       rst_n,            // 异步复位 (低有效)

    input  wire       uart_rx,          // UART 接收引脚
    output wire       uart_tx,          // UART 发送引脚

    output wire [7:0] DA0_Data,         // DAC channel A
    output wire       DA0_Clk,
    output wire [7:0] DA1_Data,         // DAC channel B
    output wire       DA1_Clk,

    output wire [7:0] led,              // Board LEDs, active low
    output reg        sh_cp,            // 7-seg 74HC595 shift clock
    output reg        st_cp,            // 7-seg 74HC595 latch clock
    output reg        ds                // 7-seg 74HC595 serial data
);

    // ============================================================
    // 内部连线
    // ============================================================
    // UART
    wire [7:0] rx_byte;
    wire       rx_done;

    // packet_parser
    wire [7:0] parsed_cmd, parsed_len, parsed_pdata;
    wire       parsed_pvalid, cmd_done, cmd_error;

    // encoder
    reg        enc_start;
    reg [10:0] enc_total_bits;
    wire [7:0] enc_addr;             // encoder 请求的字节地址
    reg  [7:0] enc_byte;            // 顶层提供的字节数据
    wire [2:0] enc_sym;
    wire       enc_sym_vld, enc_done;

    // decoder
    reg        dec_start;
    reg [10:0] dec_total_syms;
    reg  [2:0] dec_sym_in;
    reg        dec_sym_vld;
    wire       dec_bit, dec_bit_vld, dec_done;

    // dac_playback
    reg  [7:0] dac_wr0_data, dac_wr1_data;
    reg        dac_wr0_en, dac_wr1_en;
    reg [10:0] dac_wr0_addr, dac_wr1_addr;
    reg        dac_load, dac_stop;
    reg [10:0] dac_len0, dac_len1;

    // response_tx
    reg        resp_start;
    reg  [7:0] resp_cmd, resp_status, resp_len;
    reg  [7:0] resp_wr_data, resp_wr_addr;
    reg        resp_wr_en;
    wire       resp_send_en, tx_done, tx_busy;
    wire [7:0] resp_send_data;
    wire       resp_done;

    // ============================================================
    // 内部存储数组 (仅顶层拥有数组, 端口全部扁平)
    // ============================================================
    reg [7:0] payload_buf [0:255];   // 接收到的 payload
    reg [7:0] sym_buf [0:511];       // 编码符号暂存 (用于回环+应答)
    reg [7:0] bit_buf [0:255];       // 编码用比特数据

    // ============================================================
    // 子模块例化
    // ============================================================
    uart_byte_rx #(.CLK_FREQ(50_000_000), .BAUD_RATE(115200))
    u_rx (.clk(clk_50m), .rst_n(rst_n), .uart_rx(uart_rx), .data_byte(rx_byte), .rx_done(rx_done));

    packet_parser u_parser (
        .clk(clk_50m), .rst_n(rst_n),
        .rx_data(rx_byte), .rx_valid(rx_done),
        .cmd_code(parsed_cmd), .payload_len(parsed_len),
        .payload_data(parsed_pdata), .payload_valid(parsed_pvalid),
        .cmd_done(cmd_done), .cmd_error(cmd_error)
    );

    hdb3_encoder u_enc (
        .clk(clk_50m), .rst_n(rst_n),
        .start(enc_start), .total_bits(enc_total_bits),
        .bit_buf_byte(enc_byte), .bit_buf_addr(enc_addr),
        .sym_out(enc_sym), .sym_valid(enc_sym_vld),
        .sym_wr_en(), .done(enc_done)
    );

    hdb3_decoder u_dec (
        .clk(clk_50m), .rst_n(rst_n),
        .start(dec_start), .total_syms(dec_total_syms),
        .sym_in(dec_sym_in), .sym_avail(dec_sym_vld),
        .bit_out(dec_bit), .bit_valid(dec_bit_vld), .done(dec_done)
    );

    dac_playback u_dac (
        .clk(clk_50m), .rst_n(rst_n),
        .wr_data0(dac_wr0_data), .wr_en0(dac_wr0_en), .wr_addr0(dac_wr0_addr),
        .wr_data1(dac_wr1_data), .wr_en1(dac_wr1_en), .wr_addr1(dac_wr1_addr),
        .load_done(dac_load), .play_len0(dac_len0), .play_len1(dac_len1),
        .stop(dac_stop),
        .DA0_Data(DA0_Data), .DA1_Data(DA1_Data), .DA_Clk(DA0_Clk)
    );
    assign DA1_Clk = DA0_Clk;

    response_tx u_resp (
        .clk(clk_50m), .rst_n(rst_n),
        .start(resp_start), .resp_cmd(resp_cmd), .resp_status(resp_status), .resp_len(resp_len),
        .wr_data(resp_wr_data), .wr_addr(resp_wr_addr), .wr_en(resp_wr_en),
        .send_en(resp_send_en), .send_data(resp_send_data),
        .tx_done(tx_done), .tx_busy(tx_busy), .resp_done(resp_done)
    );

    uart_byte_tx #(.CLK_FREQ(50_000_000), .BAUD_RATE(115200))
    u_tx (.clk(clk_50m), .rst_n(rst_n), .send_en(resp_send_en), .data_byte(resp_send_data),
          .uart_tx(uart_tx), .tx_done(tx_done), .tx_busy(tx_busy));
    // ============================================================
    // payload 接收: 从 parser 的逐字节输出存入内部数组
    // ============================================================
    reg [7:0] pl_idx;
    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n)
            pl_idx <= 8'd0;
        else if (cmd_done)
            pl_idx <= 8'd0;
        else if (parsed_pvalid) begin
            payload_buf[pl_idx] <= parsed_pdata;
            pl_idx <= pl_idx + 8'd1;
        end
    end

    // ============================================================
    // encoder bit_buf_byte 驱动
    // ============================================================
    always @(*) begin
        enc_byte = bit_buf[enc_addr];
    end

    // ============================================================
    // 主控状态机
    // ============================================================
    localparam M_IDLE        = 4'd0;
    localparam M_ENC_PREP    = 4'd1;
    localparam M_ENC_RUN     = 4'd2;
    localparam M_ENC_LOOP    = 4'd3;
    localparam M_DEC_PREP    = 4'd4;
    localparam M_DEC_RUN     = 4'd5;
    localparam M_START_DAC   = 4'd6;
    localparam M_RESP_WRITE  = 4'd7;
    localparam M_RESP_SEND   = 4'd8;
    localparam M_ERR_SEND    = 4'd9;

    reg [3:0]  m_state, m_next;
    reg [10:0] m_idx, m_wr0, m_wr1, m_sym_cnt;
    reg [15:0] total_bits;

    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) m_state <= M_IDLE;
        else        m_state <= m_next;
    end

    always @(*) begin
        m_next = m_state;
        case (m_state)
            M_IDLE: begin
                if (cmd_done) begin
                    if (parsed_cmd == 8'h01)  m_next = M_ENC_PREP;
                    else if (parsed_cmd == 8'h02) m_next = M_DEC_PREP;
                    else m_next = M_ERR_SEND;
                end
            end
            M_ENC_PREP:  m_next = M_ENC_RUN;
            M_ENC_RUN:   if (enc_done) m_next = M_ENC_LOOP;
            M_ENC_LOOP:  if (dec_done) m_next = M_START_DAC;
            M_DEC_PREP:  m_next = M_DEC_RUN;
            M_DEC_RUN:   if (dec_done) m_next = M_START_DAC;
            M_START_DAC: m_next = M_RESP_WRITE;
            M_RESP_WRITE: if (m_idx == resp_len) m_next = M_RESP_SEND;
            M_RESP_SEND: if (resp_done) m_next = M_IDLE;
            M_ERR_SEND:  if (resp_done) m_next = M_IDLE;
            default:     m_next = M_IDLE;
        endcase
    end

    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            enc_start   <= 1'b0; dec_start   <= 1'b0; dec_sym_vld <= 1'b0;
            dac_wr0_en  <= 1'b0; dac_wr1_en  <= 1'b0;
            dac_load    <= 1'b0; dac_stop    <= 1'b0;
            resp_start  <= 1'b0; resp_wr_en  <= 1'b0;
            m_idx       <= 11'd0; m_wr0      <= 11'd0; m_wr1 <= 11'd0;
            m_sym_cnt   <= 11'd0; total_bits  <= 16'd0;
            resp_cmd    <= 8'd0; resp_status <= 8'd0; resp_len <= 8'd0;
        end
        else begin
            enc_start   <= 1'b0; dec_start   <= 1'b0; dec_sym_vld <= 1'b0;
            dac_wr0_en  <= 1'b0; dac_wr1_en  <= 1'b0;
            dac_load    <= 1'b0; dac_stop    <= 1'b0;
            resp_start  <= 1'b0; resp_wr_en  <= 1'b0;

            case (m_state)
                M_IDLE: begin
                    m_idx    <= 11'd0; m_wr0 <= 11'd0; m_wr1 <= 11'd0;
                    m_sym_cnt <= 11'd0;
                    dac_stop <= 1'b1;
                    resp_status <= 8'h00;
                end

                M_ENC_PREP: begin
                    // 编码准备: payload[0..1] = bit_cnt, [2..] = bit_data
                    total_bits <= {payload_buf[1], payload_buf[0]};
                    resp_cmd   <= 8'h01;
                    // 将 payload 中 bit_data 复制到 bit_buf
                    if (m_idx < parsed_len - 8'd2) begin
                        bit_buf[m_idx] <= payload_buf[m_idx + 2];
                        m_idx <= m_idx + 11'd1;
                    end
                    else begin
                        enc_total_bits <= total_bits[10:0];
                        enc_start      <= 1'b1;
                        m_idx          <= 11'd0;
                    end
                end

                M_ENC_RUN: begin
                    if (enc_sym_vld) begin
                        dac_wr0_en   <= 1'b1;
                        dac_wr0_addr <= m_wr0;
                        dac_wr0_data <= {5'b0, enc_sym};
                        m_wr0        <= m_wr0 + 11'd1;
                        sym_buf[m_sym_cnt] <= {5'b0, enc_sym};
                        m_sym_cnt    <= m_sym_cnt + 11'd1;
                    end
                    if (enc_done) begin
                        dac_len0  <= m_wr0;
                        m_wr0     <= 11'd0;
                    end
                end

                M_ENC_LOOP: begin
                    if (!dec_start && m_idx == 11'd0) begin
                        dec_start      <= 1'b1;
                        dec_total_syms <= m_sym_cnt;
                        m_idx          <= 11'd1;  // 标记已启动
                    end
                    // 逐符号送入 decoder
                    if (m_idx > 0 && m_idx <= m_sym_cnt) begin
                        dec_sym_in   <= sym_buf[m_idx - 1][2:0];
                        dec_sym_vld  <= 1'b1;
                        m_idx        <= m_idx + 11'd1;
                    end
                    if (dec_bit_vld) begin
                        dac_wr1_en   <= 1'b1;
                        dac_wr1_addr <= m_wr1;
                        dac_wr1_data <= {7'b0, dec_bit};
                        m_wr1        <= m_wr1 + 11'd1;
                    end
                    if (dec_done) begin
                        dac_len1 <= m_wr1;
                        resp_len <= m_sym_cnt[7:0];
                        m_wr1    <= 11'd0;
                    end
                end

                M_DEC_PREP: begin
                    resp_cmd <= 8'h02;
                    if (m_idx < parsed_len) begin
                        dac_wr0_en   <= 1'b1;
                        dac_wr0_addr <= m_idx;
                        dac_wr0_data <= payload_buf[m_idx];
                        m_idx        <= m_idx + 11'd1;
                    end
                    else begin
                        dac_len0     <= {3'b0, parsed_len};
                        dec_start    <= 1'b1;
                        dec_total_syms <= {3'b0, parsed_len};
                        m_idx        <= 11'd0;
                    end
                end

                M_DEC_RUN: begin
                    if (m_idx < parsed_len) begin
                        dec_sym_in   <= payload_buf[m_idx][2:0];
                        dec_sym_vld  <= 1'b1;
                        m_idx        <= m_idx + 11'd1;
                    end
                    if (dec_bit_vld) begin
                        dac_wr1_en   <= 1'b1;
                        dac_wr1_addr <= m_wr1;
                        dac_wr1_data <= {7'b0, dec_bit};
                        m_wr1        <= m_wr1 + 11'd1;
                    end
                    if (dec_done) begin
                        dac_len1 <= m_wr1;
                        resp_len <= m_wr1[7:0];
                        m_wr1    <= 11'd0;
                    end
                end

                M_START_DAC: begin
                    dac_load <= 1'b1;
                    m_idx <= 11'd0;
                end

                M_RESP_WRITE: begin
                    if (resp_cmd == 8'h01 && m_idx < m_sym_cnt) begin
                        resp_wr_en   <= 1'b1;
                        resp_wr_addr <= m_idx[7:0];
                        resp_wr_data <= sym_buf[m_idx];
                        m_idx        <= m_idx + 11'd1;
                    end
                    else if (resp_cmd == 8'h02 && m_idx < {3'b0, resp_len}) begin
                        resp_wr_en   <= 1'b1;
                        resp_wr_addr <= m_idx[7:0];
                        resp_wr_data <= sym_buf[m_idx];
                        m_idx        <= m_idx + 11'd1;
                    end
                    else begin
                        m_idx <= {3'b0, resp_len};
                    end
                end

                M_RESP_SEND: begin
                    if (!resp_start) begin
                        resp_status <= 8'h00;
                        resp_start  <= 1'b1;
                    end
                end

                M_ERR_SEND: begin
                    if (!resp_start) begin
                        resp_status <= 8'h03;
                        resp_cmd    <= parsed_cmd;
                        resp_len    <= 8'd0;
                        resp_start  <= 1'b1;
                    end
                end
            endcase
        end
    end

    // ============================================================
    // 解码模式: 收集解码 bit 到 sym_buf (用于应答)
    // ============================================================
    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            // nop
        end
        else if (m_state == M_DEC_RUN && dec_bit_vld) begin
            sym_buf[m_wr1] <= {7'b0, dec_bit};
        end
    end

    // ============================================================
    // 心跳灯
    // ============================================================
    reg [24:0] heartbeat_cnt;
    reg        led0;

    assign led = {7'b111_1111, led0};

    // 心跳计数器: 50MHz / 25000000 = 2Hz 翻转
    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n)
            heartbeat_cnt <= 25'd0;
        else if (heartbeat_cnt == 25'd24_999_999)
            heartbeat_cnt <= 25'd0;
        else
            heartbeat_cnt <= heartbeat_cnt + 25'd1;
    end

    // LED0 心跳: 低有效
    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n)
            led0 <= 1'b1;
        else
            led0 <= (heartbeat_cnt < 25'd12_500_000) ? 1'b0 : 1'b1;
    end

    // Blank the board 7-segment display through its 74HC595 chain. If these
    // pins are left unmanaged, the external registers can keep random power-up
    // or stale latch states after FPGA configuration.
    localparam [15:0] SEG_BLANK_WORD = 16'hFF00;

    reg [1:0]  seg_div_cnt;
    reg [5:0]  seg_phase;
    reg [15:0] seg_shift;

    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            seg_div_cnt <= 2'd0;
            seg_phase   <= 6'd0;
            seg_shift   <= SEG_BLANK_WORD;
            sh_cp       <= 1'b0;
            st_cp       <= 1'b0;
            ds          <= 1'b0;
        end
        else if (seg_div_cnt == 2'd1) begin
            seg_div_cnt <= 2'd0;
            st_cp <= 1'b0;

            if (seg_phase < 6'd32) begin
                if (!seg_phase[0]) begin
                    sh_cp <= 1'b0;
                    ds    <= seg_shift[15];
                end
                else begin
                    sh_cp     <= 1'b1;
                    seg_shift <= {seg_shift[14:0], 1'b0};
                end
                seg_phase <= seg_phase + 6'd1;
            end
            else begin
                sh_cp     <= 1'b0;
                st_cp     <= 1'b1;
                seg_phase <= 6'd0;
                seg_shift <= SEG_BLANK_WORD;
            end
        end
        else begin
            seg_div_cnt <= seg_div_cnt + 2'd1;
        end
    end

endmodule
