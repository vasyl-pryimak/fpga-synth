// i2c_master.v — читає ADS1115 канали A0..A3 по I²C @ 100kHz
//
// A0 (AIN0) → volume_raw    (гучність)
// A1 (AIN1) → wet_raw       (wet/dry)
// A2 (AIN2) → decay_raw     (довжина реверб-хвоста)
// A3 (AIN3) → predelay_raw  (затримка перед реverbом)
//
// Цикл: CONFIG → SET_POINTER → WAIT(15ms) → READ → наступний канал (0→1→2→3→0)

module i2c_master (
    input  wire        clk,
    output reg  [15:0] volume_raw   = 16'h7FFF,  // A0: default = max volume
    output reg  [15:0] wet_raw      = 16'h0000,  // A1: default = reverb вимкнено
    output reg  [15:0] decay_raw    = 16'h0000,  // A2: default = no decay
    output reg  [15:0] predelay_raw = 16'h0000,  // A3: default = без pre-delay
    inout  wire        sda,
    output wire        scl
);

localparam QUARTER_PERIOD = 7'd124;  // 100kHz @ 50MHz, 4-phase

reg scl_r  = 1'b1;
reg sda_lo = 1'b0;
assign sda = sda_lo ? 1'b0 : 1'bz;
assign scl = scl_r;

reg [6:0] tmr = 7'd0;
wire tick = (tmr == QUARTER_PERIOD);
always @(posedge clk) tmr <= tick ? 7'd0 : tmr + 7'd1;

// ── Поточний канал 0..3 ───────────────────────────────────────────
reg [1:0] ch = 2'd0;

// Single-shot mode, PGA=±4.096V (PGA=001), MODE=1, OS=1
//   A0: MUX=100 → 1_100_001_1 = 0xC3
//   A1: MUX=101 → 1_101_001_1 = 0xD3
//   A2: MUX=110 → 1_110_001_1 = 0xE3
//   A3: MUX=111 → 1_111_001_1 = 0xF3
reg [7:0] cfg_msb;
always @(*) case (ch)
    2'd0: cfg_msb = 8'hC3;
    2'd1: cfg_msb = 8'hD3;
    2'd2: cfg_msb = 8'hE3;
    2'd3: cfg_msb = 8'hF3;
endcase

// ── Стани FSM ─────────────────────────────────────────────────────
localparam [4:0]
    S_IDLE    = 5'd0,
    S_C_START = 5'd1,
    S_C_ADDR  = 5'd2,
    S_C_REG   = 5'd3,
    S_C_DMSB  = 5'd4,
    S_C_DLSB  = 5'd5,
    S_C_STOP  = 5'd6,
    S_P_START = 5'd7,
    S_P_ADDR  = 5'd8,
    S_P_REG   = 5'd9,
    S_P_STOP  = 5'd10,
    S_R_START = 5'd11,
    S_R_ADDR  = 5'd12,
    S_R_MSB   = 5'd13,
    S_R_LSB   = 5'd14,
    S_R_STOP  = 5'd15,
    S_WAIT    = 5'd16;

reg [4:0]  state    = S_IDLE;
reg [3:0]  bcnt     = 4'd0;
reg [1:0]  cph      = 2'd0;
reg [14:0] wcnt     = 15'd0;
reg [7:0]  txd      = 8'd0;
reg [7:0]  rxd      = 8'd0;
reg [15:0] adc_data = 16'h0000;  // буфер для атомарного запису

always @(posedge clk) begin
    if (tick) begin
        case (state)

        S_IDLE: begin
            scl_r <= 1'b1; sda_lo <= 1'b0;
            cph <= 2'd0; state <= S_C_START;
        end

        // ── START ─────────────────────────────────────────────────
        S_C_START, S_P_START, S_R_START: begin
            case (cph)
                2'b00: begin scl_r <= 1'b1; sda_lo <= 1'b0; cph <= 2'b01; end
                2'b01: begin scl_r <= 1'b1; sda_lo <= 1'b1; cph <= 2'b10; end
                2'b10: begin scl_r <= 1'b0; sda_lo <= 1'b1; cph <= 2'b11; end
                2'b11: begin
                    scl_r <= 1'b0; cph <= 2'b00; bcnt <= 4'd0;
                    case (state)
                        S_C_START: begin txd <= 8'h90; state <= S_C_ADDR; end
                        S_P_START: begin txd <= 8'h90; state <= S_P_ADDR; end
                        S_R_START: begin txd <= 8'h91; state <= S_R_ADDR; end
                    endcase
                end
            endcase
        end

        // ── TX байт ───────────────────────────────────────────────
        S_C_ADDR, S_C_REG, S_C_DMSB, S_C_DLSB, S_P_ADDR, S_P_REG, S_R_ADDR: begin
            case (cph)
                2'b00: begin
                    scl_r  <= 1'b0;
                    sda_lo <= (bcnt < 4'd8) ? ~txd[7 - bcnt[2:0]] : 1'b0;
                    cph    <= 2'b01;
                end
                2'b01: begin cph <= 2'b10; end
                2'b10: begin scl_r <= 1'b1; cph <= 2'b11; end
                2'b11: begin
                    scl_r <= 1'b0; cph <= 2'b00;
                    if (bcnt == 4'd8) begin
                        bcnt <= 4'd0;
                        case (state)
                            S_C_ADDR: begin txd <= 8'h01;    state <= S_C_REG;  end
                            S_C_REG:  begin txd <= cfg_msb;  state <= S_C_DMSB; end
                            S_C_DMSB: begin txd <= 8'h83;    state <= S_C_DLSB; end
                            S_C_DLSB: begin cph <= 2'b00;    state <= S_C_STOP; end
                            S_P_ADDR: begin txd <= 8'h00;    state <= S_P_REG;  end
                            S_P_REG:  begin cph <= 2'b00;    state <= S_P_STOP; end
                            S_R_ADDR: begin rxd <= 8'd0;     state <= S_R_MSB;  end
                            default:  state <= S_IDLE;
                        endcase
                    end else
                        bcnt <= bcnt + 4'd1;
                end
            endcase
        end

        // ── RX MSB + ACK ──────────────────────────────────────────
        S_R_MSB: begin
            case (cph)
                2'b00: begin
                    scl_r  <= 1'b0;
                    sda_lo <= (bcnt == 4'd8) ? 1'b1 : 1'b0;
                    cph    <= 2'b01;
                end
                2'b01: begin cph <= 2'b10; end
                2'b10: begin scl_r <= 1'b1; cph <= 2'b11; end
                2'b11: begin
                    if (bcnt < 4'd8) rxd <= {rxd[6:0], sda};
                    scl_r <= 1'b0; cph <= 2'b00;
                    if (bcnt == 4'd8) begin
                        adc_data[15:8] <= rxd;
                        rxd <= 8'd0; bcnt <= 4'd0;
                        state <= S_R_LSB;
                    end else
                        bcnt <= bcnt + 4'd1;
                end
            endcase
        end

        // ── RX LSB + NACK ─────────────────────────────────────────
        S_R_LSB: begin
            case (cph)
                2'b00: begin scl_r <= 1'b0; sda_lo <= 1'b0; cph <= 2'b01; end
                2'b01: begin cph <= 2'b10; end
                2'b10: begin scl_r <= 1'b1; cph <= 2'b11; end
                2'b11: begin
                    if (bcnt < 4'd8) rxd <= {rxd[6:0], sda};
                    scl_r <= 1'b0; cph <= 2'b00;
                    if (bcnt == 4'd8) begin
                        adc_data[7:0] <= rxd;
                        bcnt <= 4'd0; cph <= 2'b00;
                        state <= S_R_STOP;
                    end else
                        bcnt <= bcnt + 4'd1;
                end
            endcase
        end

        // ── STOP ──────────────────────────────────────────────────
        S_C_STOP, S_P_STOP, S_R_STOP: begin
            case (cph)
                2'b00: begin scl_r <= 1'b0; sda_lo <= 1'b1; cph <= 2'b01; end
                2'b01: begin scl_r <= 1'b1; sda_lo <= 1'b1; cph <= 2'b10; end
                2'b10: begin scl_r <= 1'b1; sda_lo <= 1'b0; cph <= 2'b11; end
                2'b11: begin
                    scl_r <= 1'b1; cph <= 2'b00;
                    case (state)
                        S_C_STOP: state <= S_P_START;
                        S_P_STOP: begin wcnt <= 15'd0; state <= S_WAIT; end
                        S_R_STOP: begin
                            // Атомарний запис: обидва байти одночасно
                            // A2(AIN2) → decay_raw, A3(AIN3) → predelay_raw
                            case (ch)
                                2'd0: volume_raw   <= adc_data[15] ? 16'h0000 : adc_data;
                                2'd1: wet_raw      <= adc_data[15] ? 16'h0000 : adc_data;
                                2'd2: decay_raw    <= adc_data[15] ? 16'h0000 : adc_data;
                                2'd3: predelay_raw <= adc_data[15] ? 16'h0000 : adc_data;
                            endcase
                            ch    <= ch + 2'd1;  // 0→1→2→3→0 (автоматичний wrap)
                            state <= S_C_START;
                        end
                    endcase
                end
            endcase
        end

        // ── WAIT 15ms (ADS1115 @ 128 SPS, max конверсія 8.6ms) ───
        S_WAIT: begin
            scl_r <= 1'b1; sda_lo <= 1'b0;
            if (wcnt == 15'd5999)
                state <= S_R_START;
            else
                wcnt <= wcnt + 15'd1;
        end

        default: state <= S_IDLE;
        endcase
    end
end

endmodule
