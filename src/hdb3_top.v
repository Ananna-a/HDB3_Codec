// =============================================================================
// hdb3_top.v - HDB3 codec FPGA top module
// =============================================================================
// Instantiates communication, codec, DAC playback, response, and debug logic.
//
// Encode path: RX -> parser -> encoder -> DAC0 + loop decoder -> DAC1 -> response
// Decode path: RX -> parser -> decoder -> DAC1 + DAC0 input-symbol view -> response
// =============================================================================

module hdb3_top (
    input  wire       clk_50m,          // 50MHz system clock
    input  wire       rst_n,            // async reset, active low

    input  wire       uart_rx,          // UART RX pin
    output wire       uart_tx,          // UART TX pin

    output wire [7:0] DA0_Data,         // DAC channel A
    output wire       DA0_Clk,
    output wire [7:0] DA1_Data,         // DAC channel B
    output wire       DA1_Clk,

    output wire [7:0] led,              // Board LEDs
    output reg        sh_cp,            // 7-seg 74HC595 shift clock
    output reg        st_cp,            // 7-seg 74HC595 latch clock
    output reg        ds                // 7-seg 74HC595 serial data
);

    localparam [7:0] MAX_FRAME_ITEMS = 8'd64;
    localparam [7:0] MAX_BIT_BYTES   = 8'd8;

    // ============================================================
    // Internal wires
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
    wire [7:0] enc_addr;             // byte address requested by encoder
    reg  [7:0] enc_byte;             // byte data supplied by top
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
    wire       dac_playing;

    // response_tx
    reg        resp_start;
    reg  [7:0] resp_cmd, resp_status, resp_len;
    wire [5:0] resp_payload_addr;
    wire [7:0] resp_payload_data;
    wire       resp_send_en, tx_done, tx_busy;
    wire [7:0] resp_send_data;
    wire       resp_done;

    // ============================================================
    // Internal storage arrays owned by the top module
    // ============================================================
    reg [7:0] payload_buf [0:63];    // received payload, limited by PC app
    reg [7:0] sym_buf [0:63];        // response/DAC symbol buffer
    reg [7:0] bit_buf [0:7];         // packed encode bits, 64 bits max

    // ============================================================
    // Submodule instances
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
        .DA0_Data(DA0_Data), .DA1_Data(DA1_Data), .DA_Clk(DA0_Clk),
        .playing_out(dac_playing)
    );
    assign DA1_Clk = DA0_Clk;

    response_tx u_resp (
        .clk(clk_50m), .rst_n(rst_n),
        .start(resp_start), .resp_cmd(resp_cmd), .resp_status(resp_status), .resp_len(resp_len),
        .payload_addr(resp_payload_addr), .payload_data(resp_payload_data),
        .send_en(resp_send_en), .send_data(resp_send_data),
        .tx_done(tx_done), .tx_busy(tx_busy), .resp_done(resp_done)
    );

    uart_byte_tx #(.CLK_FREQ(50_000_000), .BAUD_RATE(115200))
    u_tx (.clk(clk_50m), .rst_n(rst_n), .send_en(resp_send_en), .data_byte(resp_send_data),
          .uart_tx(uart_tx), .tx_done(tx_done), .tx_busy(tx_busy));

    assign resp_payload_data = sym_buf[resp_payload_addr];
    // ============================================================
    // Store parser payload bytes into payload_buf
    // ============================================================
    reg [7:0] pl_idx;
    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n)
            pl_idx <= 8'd0;
        else if (cmd_done)
            pl_idx <= 8'd0;
        else if (parsed_pvalid && pl_idx < MAX_FRAME_ITEMS) begin
            payload_buf[pl_idx] <= parsed_pdata;
            pl_idx <= pl_idx + 8'd1;
        end
    end

    // ============================================================
    // Drive encoder bit byte input
    // ============================================================
    always @(*) begin
        enc_byte = bit_buf[enc_addr];
    end

    // ============================================================
    // Main control FSM
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

    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) m_state <= M_IDLE;
        else        m_state <= m_next;
    end

    always @(*) begin
        m_next = m_state;
        case (m_state)
            M_IDLE: begin
                if (cmd_done) begin
                    if (parsed_cmd == 8'h01) begin
                        if (parsed_len >= 8'd2 && parsed_len <= (MAX_BIT_BYTES + 8'd2))
                            m_next = M_ENC_PREP;
                        else
                            m_next = M_ERR_SEND;
                    end
                    else if (parsed_cmd == 8'h02) begin
                        if (parsed_len > 8'd0 && parsed_len <= MAX_FRAME_ITEMS)
                            m_next = M_DEC_PREP;
                        else
                            m_next = M_ERR_SEND;
                    end
                    else begin
                        m_next = M_ERR_SEND;
                    end
                end
            end
            M_ENC_PREP: begin
                if (m_idx < ({3'b0, parsed_len} - 11'd2))
                    m_next = M_ENC_PREP;
                else if ({payload_buf[1], payload_buf[0]} == 16'd0 || {payload_buf[1], payload_buf[0]} > {8'd0, MAX_FRAME_ITEMS})
                    m_next = M_ERR_SEND;
                else
                    m_next = M_ENC_RUN;
            end
            M_ENC_RUN:   if (enc_done) m_next = M_ENC_LOOP;
            M_ENC_LOOP:  if (dec_done) m_next = M_START_DAC;
            M_DEC_PREP: begin
                if (m_idx < {3'b0, parsed_len})
                    m_next = M_DEC_PREP;
                else
                    m_next = M_DEC_RUN;
            end
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
            resp_start  <= 1'b0;
            m_idx       <= 11'd0; m_wr0      <= 11'd0; m_wr1 <= 11'd0;
            m_sym_cnt   <= 11'd0;
            resp_cmd    <= 8'd0; resp_status <= 8'd0; resp_len <= 8'd0;
        end
        else begin
            enc_start   <= 1'b0; dec_start   <= 1'b0; dec_sym_vld <= 1'b0;
            dac_wr0_en  <= 1'b0; dac_wr1_en  <= 1'b0;
            dac_load    <= 1'b0; dac_stop    <= 1'b0;
            resp_start  <= 1'b0;

            case (m_state)
                M_IDLE: begin
                    m_idx    <= 11'd0; m_wr0 <= 11'd0; m_wr1 <= 11'd0;
                    m_sym_cnt <= 11'd0;
                    resp_status <= 8'h00;
                end

                M_ENC_PREP: begin
                    // Encode prep: payload[0..1] = bit_cnt, payload[2..] = bit data.
                    resp_cmd   <= 8'h01;
                    dac_stop   <= 1'b1;
                    // Copy payload bit data into bit_buf.
                    if (m_idx < parsed_len - 8'd2) begin
                        bit_buf[m_idx] <= payload_buf[m_idx + 2];
                        m_idx <= m_idx + 11'd1;
                    end
                    else begin
                        enc_total_bits <= {3'b0, payload_buf[0]};
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
                    if (m_idx == 11'd0) begin
                        dec_start      <= 1'b1;
                        dec_total_syms <= m_sym_cnt;
                        m_idx          <= 11'd1;
                    end
                    else if (m_idx == 11'd1) begin
                        m_idx <= 11'd2;
                    end
                    else if (m_idx <= m_sym_cnt + 11'd1) begin
                        dec_sym_in   <= sym_buf[m_idx - 11'd2][2:0];
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
                    dac_stop <= 1'b1;
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
                    if (m_idx == 11'd0) begin
                        m_idx <= 11'd1;
                    end
                    else if (m_idx <= {3'b0, parsed_len}) begin
                        dec_sym_in   <= payload_buf[m_idx - 11'd1][2:0];
                        dec_sym_vld  <= 1'b1;
                        m_idx        <= m_idx + 11'd1;
                    end
                    if (dec_bit_vld) begin
                        dac_wr1_en   <= 1'b1;
                        dac_wr1_addr <= m_wr1;
                        dac_wr1_data <= {7'b0, dec_bit};
                        sym_buf[m_wr1] <= {7'b0, dec_bit};
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
                    m_idx <= {3'b0, resp_len};
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
    // Decode-mode bit collection placeholder; writes are handled in the main FSM.
    // ============================================================
    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            // nop
        end
        else if (m_state == M_DEC_RUN && dec_bit_vld) begin
            // sym_buf writes are handled in the main FSM.
        end
    end

    // ============================================================
    // Heartbeat and debug LEDs
    // ============================================================
    reg [24:0] heartbeat_cnt;
    reg        led0;
    reg [23:0] led_rx_cnt;
    reg [23:0] led_cmd_ok_cnt;
    reg [23:0] led_cmd_err_cnt;
    reg [23:0] led_resp_cnt;

    assign led = {led_resp_cnt != 24'd0, dac_playing, tx_busy, (m_state != M_IDLE),
                  led_cmd_err_cnt != 24'd0, led_cmd_ok_cnt != 24'd0,
                  led_rx_cnt != 24'd0, led0};

    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n) begin
            led_rx_cnt      <= 24'd0;
            led_cmd_ok_cnt  <= 24'd0;
            led_cmd_err_cnt <= 24'd0;
            led_resp_cnt    <= 24'd0;
        end
        else begin
            if (rx_done)
                led_rx_cnt <= 24'd12_500_000;
            else if (led_rx_cnt != 24'd0)
                led_rx_cnt <= led_rx_cnt - 24'd1;

            if (cmd_done)
                led_cmd_ok_cnt <= 24'd12_500_000;
            else if (led_cmd_ok_cnt != 24'd0)
                led_cmd_ok_cnt <= led_cmd_ok_cnt - 24'd1;

            if (cmd_error || m_state == M_ERR_SEND)
                led_cmd_err_cnt <= 24'd12_500_000;
            else if (led_cmd_err_cnt != 24'd0)
                led_cmd_err_cnt <= led_cmd_err_cnt - 24'd1;

            if (resp_done)
                led_resp_cnt <= 24'd12_500_000;
            else if (led_resp_cnt != 24'd0)
                led_resp_cnt <= led_resp_cnt - 24'd1;
        end
    end

    // Heartbeat counter: 50MHz / 25000000 = 2Hz toggle.
    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n)
            heartbeat_cnt <= 25'd0;
        else if (heartbeat_cnt == 25'd24_999_999)
            heartbeat_cnt <= 25'd0;
        else
            heartbeat_cnt <= heartbeat_cnt + 25'd1;
    end

    // LED0 heartbeat.
    always @(posedge clk_50m or negedge rst_n) begin
        if (!rst_n)
            led0 <= 1'b0;
        else
            led0 <= heartbeat_cnt[24];
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
