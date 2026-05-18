// spring_reverb.v — Phase 4: Spring Reverb DSP
// Top-level модуль: I²S + I²C + reverb DSP
//
// Ланцюжок сигналу:
//   PCM1808 → left_cap/right_cap
//     → mono_in = (L + R) / 2       ← моно вхід для reverb
//     → reverb_core                  ← 3 тапи + decay + wet/dry
//     → left_rev / right_rev         ← reverb_out + dry L/R
//     → × volume (ADS1115)           ← керування гучністю
//     → CS4344
//
// Піни (без змін відносно Phase 3):
//   PIN_24   → clk   50 MHz
//   PIN_110  → mclk  CS4344 MCLK  + PCM1808 SCKI
//   PIN_111  → lrclk CS4344 LRCLK + PCM1808 LRCK
//   PIN_112  → sclk  CS4344 SCLK  + PCM1808 BCK
//   PIN_113  → sdin  CS4344 SDIN
//   PIN_115  ← dout  PCM1808 DOUT
//   PIN_119  ↔ sda   ADS1115 SDA (I²C)
//   PIN_120  → scl   ADS1115 SCL  (I²C)

module spring_reverb (
    input  wire clk,
    output wire mclk,
    output wire lrclk,
    output wire sclk,
    output wire sdin,
    input  wire dout,
    inout  wire sda,
    output wire scl
);

// ── MCLK: 50 MHz / 4 = 12.5 MHz ──────────────────────────────────
reg mclk_r = 0, m_cnt = 0;
always @(posedge clk) begin
    m_cnt  <= m_cnt + 1;
    if (m_cnt == 1'd1) mclk_r <= ~mclk_r;
end
assign mclk = mclk_r;

// ── SCLK: 50 MHz / 16 = 3.125 MHz ────────────────────────────────
reg       sclk_r = 0;
reg [2:0] s_cnt  = 0;
always @(posedge clk) begin
    s_cnt <= s_cnt + 1;
    if (s_cnt == 3'd7) sclk_r <= ~sclk_r;
end
assign sclk = sclk_r;

// ── Детектори фронтів SCLK ────────────────────────────────────────
reg sclk_d = 0;
always @(posedge clk) sclk_d <= sclk_r;
wire sclk_fall = sclk_d & ~sclk_r;
wire sclk_rise = ~sclk_d & sclk_r;

// ── Лічильник бітів 0..63 ─────────────────────────────────────────
reg [5:0] bit_cnt = 0;
always @(posedge clk)
    if (sclk_fall)
        bit_cnt <= (bit_cnt == 6'd63) ? 6'd0 : bit_cnt + 1;

// ── LRCLK ─────────────────────────────────────────────────────────
reg lrclk_r = 0;
always @(posedge clk)
    if (sclk_fall) begin
        if      (bit_cnt == 6'd63) lrclk_r <= 1'b0;
        else if (bit_cnt == 6'd31) lrclk_r <= 1'b1;
    end
assign lrclk = lrclk_r;

// ── I²S приймач: PCM1808 DOUT → rx_buf → left_cap / right_cap ─────
reg [23:0] rx_buf    = 0;
reg signed [15:0] left_cap  = 0;
reg signed [15:0] right_cap = 0;

always @(posedge clk)
    if (sclk_rise)
        rx_buf <= {rx_buf[22:0], dout};

always @(posedge clk)
    if (sclk_fall) begin
        if (bit_cnt == 6'd24) left_cap  <= rx_buf[23:8];
        if (bit_cnt == 6'd56) right_cap <= rx_buf[23:8];
    end

// ── sample_rdy: 1-cycle pulse після захоплення обох каналів ───────
// bit_cnt=56 → right_cap захоплено; bit_cnt=57 → обидва стабільні
wire sample_rdy = sclk_fall && (bit_cnt == 6'd57);

// ── Моно вхід для reverb: лівий канал ────────────────────────────
// Використовуємо left_cap напряму — без ділення, щоб не втрачати гучність
wire signed [15:0] mono_in = left_cap;

// ── Spring Reverb Core ────────────────────────────────────────────
// Моно: один екземпляр для L+R → 3 M9K delay_lines
//
// Затримки @ 48kHz:
//   TAP1: 1100 семплів ≈ 22.9 мс
//   TAP2: 2250 семплів ≈ 46.9 мс
//   TAP3: 3900 семплів ≈ 81.3 мс
//
// A0 → гучність (vol)
// A1 → wet/dry crossfade: 0=сухий, max=тільки реверб

// ── I²C master: читає A0 (volume) і A1 (wet) ─────────────────────
wire [15:0] volume_raw;
wire [15:0] wet_raw;

i2c_master u_i2c (
    .clk        (clk),
    .volume_raw (volume_raw),
    .wet_raw    (wet_raw),
    .sda        (sda),
    .scl        (scl)
);

// ── Гучність (A0) та Wet (A1) ─────────────────────────────────────
wire [15:0] vol      = volume_raw[15] ? 16'h0000 : {1'b0, volume_raw[14:0]};
wire [15:0] wet_gain = wet_raw[15]    ? 16'h0000 : {1'b0, wet_raw[14:0]};
// Crossfade: A1=0 → тільки dry, A1=max → тільки wet
wire [15:0] dry_gain = 16'h7FFF - wet_gain;

// ── Spring Reverb Core ────────────────────────────────────────────
wire signed [15:0] reverb_out;

reverb_core u_reverb (
    .clk      (clk),
    .we       (sample_rdy),
    .audio_in (mono_in),
    .wet_gain (wet_gain),
    .dry_gain (dry_gain),
    .audio_out(reverb_out)
);

// ── Гучність (A0) × reverb_out → вихід ───────────────────────────
wire signed [31:0] left_vol  = $signed(reverb_out) * $signed(vol);
wire signed [31:0] right_vol = $signed(reverb_out) * $signed(vol);
wire signed [15:0] left_out  = left_vol[30:15];
wire signed [15:0] right_out = right_vol[30:15];

// ── I²S передавач: → shift_reg → CS4344 SDIN ─────────────────────
reg [31:0] shift_reg = 0;
always @(posedge clk)
    if (sclk_fall) begin
        if      (bit_cnt == 6'd0)  shift_reg <= {left_out,  16'h0000};
        else if (bit_cnt == 6'd32) shift_reg <= {right_out, 16'h0000};
        else                       shift_reg <= {shift_reg[30:0], 1'b0};
    end
assign sdin = shift_reg[31];

endmodule
