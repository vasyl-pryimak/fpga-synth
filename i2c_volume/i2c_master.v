// i2c_master.v — читає ADS1115 канал A0 (потенціометр) по I²C @ 100kHz
//
// Конфігурація ADS1115 (0x4283):
//   Безперервна конверсія, AIN0 vs GND, ±4.096V, 128 SPS
//   Потенціометр 0..3.3V → volume_raw 0..~26400

module i2c_master (
    input  wire        clk,                    // 50 MHz
    output reg  [15:0] volume_raw = 16'h7FFF,  // 0..~26400 (full volume за замовчуванням)
    inout  wire        sda,                    // I²C SDA (open-drain)
    output wire        scl                     // I²C SCL
);

// Для 100kHz при 50MHz один повний такт I2C = 500 циклів clk.
// Ділимо його на 4 фази: кожна фаза = 125 циклів (0..124).
localparam QUARTER_PERIOD = 7'd124;

// ── SDA open-drain + SCL ──────────────────────────────────────────
reg scl_r  = 1'b1;
reg sda_lo = 1'b0;   // 1 = тягнемо SDA до 0; 0 = відпускаємо (pull-up → 1)

assign sda = sda_lo ? 1'b0 : 1'bz;
assign scl = scl_r;

// ── Таймер чверть-періоду ──────────────────────────────────────────
reg [6:0] tmr = 7'd0;
wire tick = (tmr == QUARTER_PERIOD);
always @(posedge clk) tmr <= tick ? 7'd0 : tmr + 7'd1;

// ── Стани FSM ─────────────────────────────────────────────────────
localparam [4:0]
    S_IDLE    = 5'd0,
    // Запис конфігурації (один раз при старті)
    S_C_START = 5'd1,   // START
    S_C_ADDR  = 5'd2,   // 0x90 = адреса + write
    S_C_REG   = 5'd3,   // 0x01 = config register
    S_C_DMSB  = 5'd4,   // 0x42 = config MSB
    S_C_DLSB  = 5'd5,   // 0x83 = config LSB
    S_C_STOP  = 5'd6,   // STOP
    // Встановлення вказівника на регістр конверсії
    S_P_START = 5'd7,
    S_P_ADDR  = 5'd8,   // 0x90
    S_P_REG   = 5'd9,   // 0x00 = conversion register
    S_P_STOP  = 5'd10,
    // Читання конверсії (цикл)
    S_R_START = 5'd11,
    S_R_ADDR  = 5'd12,  // 0x91 = адреса + read
    S_R_MSB   = 5'd13,  // прийом MSB + надсилаємо ACK
    S_R_LSB   = 5'd14,  // прийом LSB + надсилаємо NACK
    S_R_STOP  = 5'd15,
    S_WAIT    = 5'd16;  // ~10ms пауза між читаннями

reg [4:0]  state = S_IDLE;
reg [3:0]  bcnt  = 4'd0;   // лічильник бітів (0..8)
reg [1:0]  cph   = 2'd0;   // 4 фази (00, 01, 10, 11) для стабілізації біта
reg [14:0] wcnt  = 15'd0;  // лічильник паузи (~10ms)
reg [7:0]  txd   = 8'd0;
reg [7:0]  rxd   = 8'd0;

// ── Головний FSM (крок раз на чверть-періоду) ────────────────────────
always @(posedge clk) begin
    if (tick) begin
        case (state)

        S_IDLE: begin
            scl_r  <= 1'b1; 
            sda_lo <= 1'b0;
            cph    <= 2'd0; 
            state  <= S_C_START;
        end

        // ── Умова START (Формування) ─────────────────────────────────
        S_C_START, S_P_START, S_R_START: begin
            case (cph)
                2'b00: begin scl_r <= 1'b1; sda_lo <= 1'b0; cph <= 2'b01; end // Вільна шина
                2'b01: begin scl_r <= 1'b1; sda_lo <= 1'b1; cph <= 2'b10; end // SDA падає -> START
                2'b10: begin scl_r <= 1'b0; sda_lo <= 1'b1; cph <= 2'b11; end // SCL падає
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

        // ── Передача байта TX (Майстер пише, Слейв слухає) ─────────────
        S_C_ADDR, S_C_REG, S_C_DMSB, S_C_DLSB, S_P_ADDR, S_P_REG, S_R_ADDR: begin
            case (cph)
                2'b00: begin // Фаза 0: SCL=0, міняємо/виставляємо дані
                    scl_r <= 1'b0;
                    if (bcnt < 4'd8)
                        sda_lo <= ~txd[7 - bcnt[2:0]]; // Виставляємо біт даних (інверсія для open-drain)
                    else
                        sda_lo <= 1'b0; // Біт 8: відпускаємо SDA для ACK від чипа
                    cph <= 2'b01;
                end
                2'b01: begin // Фаза 1: Утримуємо SCL=0, даємо лінії заспокоїтись
                    cph <= 2'b10;
                end
                2'b10: begin // Фаза 2: Піднімаємо SCL=1, чип зчитує наш біт
                    scl_r <= 1'b1;
                    cph   <= 2'b11;
                end
                2'b11: begin // Фаза 3: SCL=1, готуємо перехід до наступного біта
                    scl_r <= 1'b0; // Опускаємо для наступного циклу
                    cph   <= 2'b00;
                    if (bcnt == 4'd8) begin
                        bcnt <= 4'd0;
                        case (state)
                            S_C_ADDR: begin txd <= 8'h01; state <= S_C_REG;  end
                            S_C_REG:  begin txd <= 8'h42; state <= S_C_DMSB; end
                            S_C_DMSB: begin txd <= 8'h83; state <= S_C_DLSB; end
                            S_C_DLSB: begin cph <= 2'b00; state <= S_C_STOP; end
                            S_P_ADDR: begin txd <= 8'h00; state <= S_P_REG;  end
                            S_P_REG:  begin cph <= 2'b00; state <= S_P_STOP; end
                            S_R_ADDR: begin rxd <= 8'd0;  state <= S_R_MSB;  end
                            default:  state <= S_IDLE;
                        endcase
                    end else begin
                        bcnt <= bcnt + 4'd1;
                    end
                end
            endcase
        end

        // ── Прийом старшого байта MSB (+ стабільний ACK) ───────────────
        S_R_MSB: begin
            case (cph)
                2'b00: begin // Фаза 0: SCL=0, відпускаємо SDA або тримаємо ACK
                    scl_r  <= 1'b0;
                    sda_lo <= (bcnt == 4'd8) ? 1'b1 : 1'b0; // На 8-му такті затискаємо ACK ("хочу ще байт")
                    cph    <= 2'b01;
                end
                2'b01: begin // Фаза 1: Чекаємо стабілізації даних від ADS1115
                    cph <= 2'b10;
                end
                2'b10: begin // Фаза 2: Піднімаємо SCL=1, шина зафіксована
                    scl_r <= 1'b1;
                    cph   <= 2'b11;
                end
                2'b11: begin // Фаза 3: Останній чверть-період High — БЕЗПЕЧНЕ ЧИТАННЯ
                    if (bcnt < 4'd8)
                        rxd <= {rxd[6:0], sda}; // Надійно ковтаємо біт суворо при стабільному SCL=1
                    
                    scl_r <= 1'b0; // Опускаємо SCL
                    cph   <= 2'b00;
                    
                    if (bcnt == 4'd8) begin
                        volume_raw[15:8] <= rxd; // Зберігаємо MSB
                        rxd  <= 8'd0; 
                        bcnt <= 4'd0;
                        state <= S_R_LSB;
                    end else begin
                        bcnt <= bcnt + 4'd1;
                    end
                end
            endcase
        end

        // ── Прийом молодшого байта LSB (+ стабільний NACK) ──────────────
        S_R_LSB: begin
            case (cph)
                2'b00: begin // Фаза 0: SCL=0, відпускаємо лінію назавжди
                    scl_r  <= 1'b0;
                    sda_lo <= 1'b0; // NACK на 8-му такті (відпускаємо SDA -> pull-up підніме в 1, "досить")
                    cph    <= 2'b01;
                end
                2'b01: begin
                    cph <= 2'b10;
                end
                2'b10: begin
                    scl_r <= 1'b1;
                    cph   <= 2'b11;
                end
                2'b11: begin // Фаза 3: БЕЗПЕЧНЕ ЧИТАННЯ ЛІНІЇ
                    if (bcnt < 4'd8)
                        rxd <= {rxd[6:0], sda};
                    
                    scl_r <= 1'b0;
                    cph   <= 2'b00;
                    
                    if (bcnt == 4'd8) begin
                        volume_raw[7:0] <= rxd; // Зберігаємо LSB
                        bcnt <= 4'd0; 
                        cph  <= 2'b00;
                        state <= S_R_STOP;
                    end else begin
                        bcnt <= bcnt + 4'd1;
                    end
                end
            endcase
        end

        // ── Умова STOP (Формування) ───────────────────────────────────
        S_C_STOP, S_P_STOP, S_R_STOP: begin
            case (cph)
                2'b00: begin scl_r <= 1'b0; sda_lo <= 1'b1; cph <= 2'b01; end // Притискаємо SDA до 0
                2'b01: begin scl_r <= 1'b1; sda_lo <= 1'b1; cph <= 2'b10; end // Піднімаємо SCL
                2'b10: begin scl_r <= 1'b1; sda_lo <= 1'b0; cph <= 2'b11; end // ВІДПУСКАЄМО SDA в 1 при SCL=1 -> STOP
                2'b11: begin
                    scl_r <= 1'b1; cph <= 2'b00;
                    case (state)
                        S_C_STOP: state <= S_P_START;
                        S_P_STOP: state <= S_R_START;
                        S_R_STOP: begin wcnt <= 15'd0; state <= S_WAIT; end
                    endcase
                end
            endcase
        end

        // ── Пауза ~10ms між циклами вимірювань ─────────────────────────
        S_WAIT: begin
            scl_r  <= 1'b1; 
            sda_lo <= 1'b0;
            // 4000 тіків по чверть-періоду (125 тактів) = 500 000 тактів = 10мс при 50MHz
            if (wcnt == 15'd3999)
                state <= S_R_START;
            else
                wcnt <= wcnt + 15'd1;
        end

        default: state <= S_IDLE;
        endcase
    end
end

endmodule