// =============================================================================
// i2s_passthrough.v — I²S pass-through: PCM1808 ADC → FPGA → CS4344 DAC
// Phase 2: FPGA Spring Reverb
//
// Підключення:
//   PIN_24   → clk (50 MHz)
//   PIN_110  → mclk  (12.5 MHz)   → CS4344 MCLK  + PCM1808 SCKI
//   PIN_111  → lrclk (~48.8 kHz)  → CS4344 LRCLK + PCM1808 LRCK
//   PIN_112  → sclk  (3.125 MHz)  → CS4344 SCLK  + PCM1808 BCK
//   PIN_113  → sdin               → CS4344 SDIN
//   PIN_115  ← dout               ← PCM1808 DOUT
//
// Таймінг I²S (FMT=LOW, стандарт Philips):
//   MSB з'являється через 1 BCK після зміни LRCK.
//   Лівий канал: зрушуємо rx_buf на sclk_rise bit_cnt=0..24 (25 зрушень:
//   1 пустий + 24 дані). Після 25-го зрушення garbage виходить за межі
//   24-бітного регістра → rx_buf[23:8] = top-16 семпла. Захоплення: bit_cnt=24.
//   Правий канал: аналогічно, gap bit_cnt=32, дані 33..56, захоплення: bit_cnt=56.
//
// 1-frame затримка (~20 мкс) між захопленням і відтворенням — нечутна.
// =============================================================================

module i2s_passthrough (
    input  wire clk,    // 50 MHz
    output wire mclk,   // 12.5 MHz → CS4344 MCLK + PCM1808 SCKI
    output wire lrclk,  // ~48.8 kHz → CS4344 LRCLK + PCM1808 LRCK
    output wire sclk,   // 3.125 MHz → CS4344 SCLK + PCM1808 BCK
    output wire sdin,   // → CS4344 SDIN
    input  wire dout    // ← PCM1808 DOUT
);

// ── MCLK: 50 MHz / 4 = 12.5 MHz ─────────────────────────────────────────────
reg mclk_r = 0;
reg m_cnt  = 0;
always @(posedge clk) begin
    m_cnt  <= m_cnt + 1;
    if (m_cnt == 1'd1) mclk_r <= ~mclk_r;
end
assign mclk = mclk_r;

// ── SCLK: 50 MHz / 16 = 3.125 MHz ───────────────────────────────────────────
reg        sclk_r = 0;
reg [2:0]  s_cnt  = 0;
always @(posedge clk) begin
    s_cnt <= s_cnt + 1;
    if (s_cnt == 3'd7) sclk_r <= ~sclk_r;
end
assign sclk = sclk_r;

// ── Детектори фронтів SCLK ───────────────────────────────────────────────────
reg sclk_d = 0;
always @(posedge clk) sclk_d <= sclk_r;
wire sclk_fall = sclk_d & ~sclk_r;    // 1-цикловий імпульс на спаді
wire sclk_rise = ~sclk_d & sclk_r;    // 1-цикловий імпульс на підйомі

// ── Лічильник бітів 0..63 ────────────────────────────────────────────────────
reg [5:0] bit_cnt = 0;
always @(posedge clk)
    if (sclk_fall)
        bit_cnt <= (bit_cnt == 6'd63) ? 6'd0 : bit_cnt + 1;

// ── LRCLK ────────────────────────────────────────────────────────────────────
reg lrclk_r = 0;
always @(posedge clk)
    if (sclk_fall) begin
        if      (bit_cnt == 6'd63) lrclk_r <= 1'b0;  // лівий канал
        else if (bit_cnt == 6'd31) lrclk_r <= 1'b1;  // правий канал
    end
assign lrclk = lrclk_r;

// ── I²S приймач: PCM1808 DOUT → rx_buf → left_cap / right_cap ────────────────
reg [23:0] rx_buf    = 0;
reg [15:0] left_cap  = 0;
reg [15:0] right_cap = 0;

always @(posedge clk)
    if (sclk_rise)
        rx_buf <= {rx_buf[22:0], dout};   // зсуваємо MSB-first

always @(posedge clk)
    if (sclk_fall) begin
        if (bit_cnt == 6'd24) left_cap  <= rx_buf[23:8]; // top 16 of 24-bit
        if (bit_cnt == 6'd56) right_cap <= rx_buf[23:8];
    end

// ── I²S передавач: left_cap / right_cap → shift_reg → CS4344 SDIN ────────────
reg [31:0] shift_reg = 0;
always @(posedge clk)
    if (sclk_fall) begin
        if      (bit_cnt == 6'd0)  shift_reg <= {left_cap,  16'h0000};
        else if (bit_cnt == 6'd32) shift_reg <= {right_cap, 16'h0000};
        else                       shift_reg <= {shift_reg[30:0], 1'b0};
    end
assign sdin = shift_reg[31];

endmodule
