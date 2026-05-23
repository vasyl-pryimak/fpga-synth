// spring_reverb.v — Phase 6: Reverb + Pitch Shifter (A3)
//
// Ланцюжок сигналу:
//   PCM1808 → left_cap
//     → pitch_shifter (A3)      ← НОВИЙ ЕФЕКТ (Pitch Up/Down)
//     ├→ reverb_core (audio_in) ← затриманий (wet) шлях
//     └→ reverb_core (audio_dry)← прямий сигнал миттєво
//   reverb_core → × volume (A0) → CS4344

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

// ── MCLK / SCLK / LRCLK ──────────────────────────────────────────
reg mclk_r = 0, m_cnt = 0;
always @(posedge clk) begin
    m_cnt  <= m_cnt + 1;
    if (m_cnt == 1'd1) mclk_r <= ~mclk_r;
end
assign mclk = mclk_r;

reg       sclk_r = 0;
reg [2:0] s_cnt  = 0;
always @(posedge clk) begin
    s_cnt <= s_cnt + 1;
    if (s_cnt == 3'd7) sclk_r <= ~sclk_r;
end
assign sclk = sclk_r;

reg sclk_d = 0;
always @(posedge clk) sclk_d <= sclk_r;
wire sclk_fall = sclk_d & ~sclk_r;
wire sclk_rise = ~sclk_d & sclk_r;

reg [5:0] bit_cnt = 0;
always @(posedge clk)
    if (sclk_fall)
        bit_cnt <= (bit_cnt == 6'd63) ? 6'd0 : bit_cnt + 1;

reg lrclk_r = 0;
always @(posedge clk)
    if (sclk_fall) begin
        if      (bit_cnt == 6'd63) lrclk_r <= 1'b0;
        else if (bit_cnt == 6'd31) lrclk_r <= 1'b1;
    end
assign lrclk = lrclk_r;

// ── I²S приймач ───────────────────────────────────────────────────
reg [23:0] rx_buf    = 0;
reg signed [15:0] left_cap  = 0;

always @(posedge clk)
    if (sclk_rise)
        rx_buf <= {rx_buf[22:0], dout};

always @(posedge clk)
    if (sclk_fall) begin
        if (bit_cnt == 6'd24) left_cap  <= rx_buf[23:8];
    end

wire sample_rdy = sclk_fall && (bit_cnt == 6'd57);

// ── I²C master: читає A0..A3 ──────────────────────────────────────
wire [15:0] volume_raw;
wire [15:0] wet_raw;
wire [15:0] decay_raw;
wire [15:0] predelay_raw; // Тепер це Pitch Ratio

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
wire [15:0] wet_gain = {1'b0, wet_raw[14:0]};
wire [15:0] dry_gain = 16'h7FFF - wet_gain;

// Decay 0..0.85
wire [31:0] decay_scaled = (decay_raw[14:0] * 16'd27852) >> 15;
wire [15:0] decay_gain   = {1'b0, decay_scaled[14:0]};

// A3: Pitch Ratio mapping (Narrow range: 0.95 to 1.05)
// 0.95 * 16384 = 15565 (0x3CCD)
// 1.05 * 16384 = 17203 (0x4333)
// Span = 17203 - 15565 = 1638
wire [31:0] ratio_32 = ((predelay_raw[14:0] * 16'd1638) >> 15) + 16'd15565;
wire [15:0] pitch_ratio = ratio_32[15:0];

// ── Pitch Shifter (A3) ────────────────────────────────────────────
wire signed [15:0] pitched_out;
pitch_shifter #(.DEPTH(2048), .ADDR_BITS(11)) u_pitch (
    .clk      (clk),
    .we       (sample_rdy),
    .audio_in (left_cap),
    .ratio    (pitch_ratio),
    .audio_out(pitched_out)
);

// ── Spring Reverb Core ────────────────────────────────────────────
wire signed [15:0] reverb_out;

reverb_core u_reverb (
    .clk        (clk),
    .we         (sample_rdy),
    .audio_in   (pitched_out),// Ефект Pitch Shifter йде в реверб
    .audio_dry  (left_cap),   // Прямий сигнал залишається оригінальним
    .wet_gain   (wet_gain),
    .dry_gain   (dry_gain),
    .decay_gain (decay_gain),
    .audio_out  (reverb_out)
);

// ── Гучність (A0) ─────────────────────────────────────────────────
wire signed [31:0] left_vol  = $signed(reverb_out) * $signed(vol);
wire signed [15:0] left_out  = left_vol[30:15];

// ── I²S передавач ─────────────────────────────────────────────────
reg [31:0] shift_reg = 0;
always @(posedge clk)
    if (sclk_fall) begin
        if      (bit_cnt == 6'd0)  shift_reg <= {left_out,  16'h0000};
        else if (bit_cnt == 6'd32) shift_reg <= {left_out,  16'h0000}; 
        else                       shift_reg <= {shift_reg[30:0], 1'b0};
    end
assign sdin = shift_reg[31];

endmodule
