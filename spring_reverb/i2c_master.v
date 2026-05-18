// i2c_master.v — читає ADS1115 канали A0 і A1 по I²C @ 100kHz
//
// A0 → volume_raw  (гучність)
// A1 → wet_raw     (wet/dry reverb)
//
// Цикл на канал: CONFIG → SET_POINTER → WAIT(~10ms) → READ → наступний канал

module i2c_master (
    input  wire        clk,
    output reg  [15:0] volume_raw = 16'h7FFF,  // A0: default = max volume
    output reg  [15:0] wet_raw    = 16'h0000,  // A1: default = reverb вимкнено
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

// ── Поточний канал ────────────────────────────────────────────────
reg ch = 1'b0;  // 0 = A0 (volume), 1 = A1 (wet)
// Single-shot mode (MODE=1) + OS=1 (start conversion now) + PGA=±4.096V
//   0xC3 = 1100_0011 : OS=1, MUX=100(AIN0vsGND), PGA=001, MODE=1
//   0xD3 = 1101_0011 : OS=1, MUX=101(AIN1vsGND), PGA=001, MODE=1
// Без OS=1 ADS1115 в continuous mode міг ігнорувати зміну каналу
wire [7:0] cfg_msb = ch ? 8'hD3 : 8'hC3;

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
                        adc_data[15:8] <= rxd;  // тимчасово — запис буде в S_R_STOP
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
                        adc_data[7:0] <= rxd;  // тимчасово — запис буде в S_R_STOP
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
                        S_P_STOP: begin wcnt <= 15'd0; state <= S_WAIT;    end  // чекаємо конверсію
                        S_R_STOP: begin
                            // Атомарний запис: обидва байти одночасно
                            if (ch == 1'b0) volume_raw <= adc_data;
                            else            wet_raw    <= adc_data;
                            ch    <= ~ch;
                            state <= S_C_START;
                        end
                    endcase
                end
            endcase
        end

        // ── WAIT ~10ms (ADS1115 @ 128 SPS = 7.8ms/conv) ──────────
        S_WAIT: begin
            scl_r <= 1'b1; sda_lo <= 1'b0;
            if (wcnt == 15'd5999)  // 15ms (@ 100kHz/4 тіків) — гарантія конверсії ADS1115
                state <= S_R_START;
            else
                wcnt <= wcnt + 15'd1;
        end

        default: state <= S_IDLE;
        endcase
    end
end

endmodule
