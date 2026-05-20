// i2c_volume.v — I²S pass-through з керуванням гучністю через потенціометр
// Phase 3: FPGA Spring Reverb
//
// Підключення:
//   PIN_24   → clk (50 MHz)
//   PIN_110  → mclk  → CS4344 MCLK  + PCM1808 SCKI
//   PIN_111  → lrclk → CS4344 LRCLK + PCM1808 LRCK
//   PIN_112  → sclk  → CS4344 SCLK  + PCM1808 BCK
//   PIN_113  → sdin  → CS4344 SDIN
//   PIN_115  ← dout  ← PCM1808 DOUT
//   PIN_119  ↔ sda   ↔ ADS1115 SDA (I²C)
//   PIN_120  → scl   → ADS1115 SCL (I²C)

module i2c_volume (
    input  wire clk,
    output wire mclk,
    output wire lrclk,
    output wire sclk,
    output wire sdin,
    input  wire dout,
    inout  wire sda,
    output wire scl,
	 output wire [4:0] led   // ← додай сюди
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
reg [15:0] left_cap  = 0;
reg [15:0] right_cap = 0;

always @(posedge clk)
    if (sclk_rise)
        rx_buf <= {rx_buf[22:0], dout};

always @(posedge clk)
    if (sclk_fall) begin
        if (bit_cnt == 6'd24) left_cap  <= rx_buf[23:8];
        if (bit_cnt == 6'd56) right_cap <= rx_buf[23:8];
    end

// ── I²C master: читає потенціометр → volume_raw ───────────────────
wire [15:0] volume_raw;

i2c_master u_i2c (
    .clk        (clk),
    .volume_raw (volume_raw),
    .sda        (sda),
    .scl        (scl)
);

// ── Множення на гучність ──────────────────────────────────────────
// Обмежуємо volume до 15 біт (0..32767) — захист від сміття по I²C (0xFFFF = клопінг)
//wire [15:0] vol = {1'b0, volume_raw[14:0]};
//wire signed [31:0] left_vol  = $signed(left_cap)  * $signed(vol);
//wire signed [31:0] right_vol = $signed(right_cap) * $signed(vol);
//wire signed [15:0] left_out  = left_vol[30:15];
//wire signed [15:0] right_out = right_vol[30:15];


// Безпечне розширення та множення
// volume_raw — це те, що прийшло з вашого i2c_master (наприклад, 16'h6566)
wire [15:0] volume_swapped = {volume_raw[7:0], volume_raw[15:8]}; // Стане 16'h6665

// ── Множення на гучність (тепер використовуємо volume_swapped) ──────────────────
// Обмежуємо захистом від сміття вже розгорнуте число
wire [15:0] vol_lin = {1'b0, volume_raw[14:0]};
wire [31:0] vol_sq  = vol_lin * vol_lin;  // квадрат
wire [15:0] vol     = vol_sq[30:15];      // нормалізуємо назад до 16 біт
						
wire signed [31:0] left_vol  = $signed(left_cap)  * $signed(vol);
wire signed [31:0] right_vol = $signed(right_cap) * $signed(vol);
wire signed [15:0] left_out  = left_vol[30:15];
wire signed [15:0] right_out = right_vol[30:15];

assign led[0] = (volume_raw != 16'd0);  // світить якщо є хоч якесь значення
assign led[1] = (volume_raw > 16'd5000);
assign led[2] = (volume_raw > 16'd10000);
assign led[3] = (volume_raw > 16'd18000);
assign led[4] = (volume_raw > 16'd24000);



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
