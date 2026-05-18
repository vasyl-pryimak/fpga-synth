// spring_reverb.v — Phase 5: Spring Reverb з 4 потенціометрами
//
// Ланцюжок сигналу:
//   PCM1808 → left_cap
//     → pre_delay_line (A3)     ← затримка перед реverbом (0..43ms)
//     → reverb_core             ← 3 Schroeder comb + decay (A2) + wet/dry (A1)
//     → × volume (A0)
//     → CS4344
//
// Потенціометри:
//   A0 → гучність
//   A1 → wet/dry (0=сухий, max=реверб)
//   A2 → decay / feedback (0=короткий хвіст, max=довгий хвіст, cap 0.75)
//   A3 → pre-delay (0=без затримки, max≈43ms)
//
// Піни:
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
wire sample_rdy = sclk_fall && (bit_cnt == 6'd57);

// ── I²C master: читає A0..A3 ──────────────────────────────────────
wire [15:0] volume_raw;
wire [15:0] wet_raw;
wire [15:0] decay_raw;
wire [15:0] predelay_raw;

i2c_master u_i2c (
    .clk          (clk),
    .volume_raw   (volume_raw),
    .wet_raw      (wet_raw),
    .decay_raw    (decay_raw),
    .predelay_raw (predelay_raw),
    .sda          (sda),
    .scl          (scl)
);

// ── Масштабування значень потенціометрів ──────────────────────────
wire [15:0] vol      = {1'b0, volume_raw[14:0]};
wire [15:0] wet_gain = {1'b0, wet_raw[14:0]};  // A1: скільки ревербу додати
wire [15:0] dry_gain = 16'h7FFF;               // dry завжди 100%

// Decay = feedback per comb filter: 0 → 0.75 max
// Кап 0x6000 = 24576 = 0.75 — вище починається "репіння"
wire [15:0] decay_uncapped = decay_raw + {3'b000, decay_raw[14:3]};  // × 1.125
wire [15:0] decay_gain     = (decay_uncapped > 16'h6000) ? 16'h6000 : decay_uncapped;

// Pre-delay: 0..43ms @ 48kHz
// DEPTH=2048 → 4 M9K (замість 8 для DEPTH=4096)
// predelay_raw 0..26400 → delay_samples 0..2047 (bits [13:3] = >> 3, кламп до 11 біт)
// Мінімум 40 семплів або 0 (bypass) — щоб уникнути comb filter рінгу
wire [10:0] predelay_raw_s = predelay_raw[13:3];
wire [10:0] predelay_samples = (predelay_raw_s < 11'd40) ? 11'd0 : predelay_raw_s;

// ── Pre-delay line (A3) ───────────────────────────────────────────
// При predelay_samples=0: bypass (left_cap напряму), бо delay_line
// з samples=0 читає з-під wr_ptr і дає 2048 семплів затримки замість 0
wire signed [15:0] predelay_out;

delay_line #(.DEPTH(2048), .ADDR_BITS(11)) u_predelay (
    .clk          (clk),
    .we           (sample_rdy),
    .audio_in     (left_cap),
    .delay_samples(predelay_samples),
    .audio_out    (predelay_out)
);

wire signed [15:0] predelayed = (|predelay_samples) ? predelay_out : left_cap;

// ── Spring Reverb Core ────────────────────────────────────────────
wire signed [15:0] reverb_out;

reverb_core u_reverb (
    .clk        (clk),
    .we         (sample_rdy),
    .audio_in   (predelayed),   // ← через pre-delay
    .wet_gain   (wet_gain),
    .dry_gain   (dry_gain),
    .decay_gain (decay_gain),
    .audio_out  (reverb_out)
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
