// reverb_core.v — spring reverb: 3 тапи + decay + wet/dry мікс
//
// Архітектура:
//
//   audio_in ──┬──── × DRY_GAIN ────────────────────────────────────┐
//              │                                                     │
//              ├──→ delay_line1 [TAP1_DELAY] ──→ × DECAY1 ──→ +    │
//              ├──→ delay_line2 [TAP2_DELAY] ──→ × DECAY2 ──→ +    │
//              └──→ delay_line3 [TAP3_DELAY] ──→ × DECAY3 ──→ +    │
//                                                      │            │
//                                              wet_sum / 4          │
//                                                      │            │
//                                               × WET_GAIN          │
//                                                      │            │
//                                                      └──── + ─────┘
//                                                            │
//                                                        audio_out
//
// Fixed-point: Q1.15 (value = coefficient × 32768)
//   0.75 → 24576 = 16'sh6000
//   0.60 → 19661 = 16'sh4CCD
//   0.45 → 14746 = 16'sh399A
//
// RAM usage: 3 × delay_line(DEPTH=4096) ≈ 24 M9K блоки (з 30 наявних)
//
// Параметри для швидкої симуляції (testbench може переовзначити):
//   TAP1_DELAY=5, TAP2_DELAY=10, TAP3_DELAY=18 → перевірка за ~25 семплів

module reverb_core #(
    // Затримки в семплах (@ 48kHz: 1 sample ≈ 20.8 мкс)
    parameter [11:0] TAP1_DELAY  = 12'd1100,  // ~22.9 мс
    parameter [11:0] TAP2_DELAY  = 12'd2250,  // ~46.9 мс
    parameter [11:0] TAP3_DELAY  = 12'd3900,  // ~81.3 мс
    // Decay коефіцієнти Q1.15
    parameter [15:0] DECAY1      = 16'h6000,  // 0.750
    parameter [15:0] DECAY2      = 16'h4CCD,  // 0.600
    parameter [15:0] DECAY3      = 16'h399A   // 0.450
)(
    input  wire              clk,
    input  wire              we,              // 1-cycle pulse per audio sample
    input  wire signed [15:0] audio_in,
    input  wire [15:0]        wet_gain,       // Q1.15, з потенціометра або хардкод
    input  wire [15:0]        dry_gain,       // Q1.15, з потенціометра або хардкод
    output reg  signed [15:0] audio_out
);

// ── Три delay lines ───────────────────────────────────────────────
// Кожна — окремий circular buffer у Block RAM (M9K)
// Всі отримують одне і те саме audio_in, але з різною затримкою

wire signed [15:0] tap1_raw, tap2_raw, tap3_raw;

delay_line #(.DEPTH(4096), .ADDR_BITS(12)) dl1 (
    .clk          (clk),
    .we           (we),
    .audio_in     (audio_in),
    .delay_samples(TAP1_DELAY),
    .audio_out    (tap1_raw)
);

delay_line #(.DEPTH(4096), .ADDR_BITS(12)) dl2 (
    .clk          (clk),
    .we           (we),
    .audio_in     (audio_in),
    .delay_samples(TAP2_DELAY),
    .audio_out    (tap2_raw)
);

delay_line #(.DEPTH(4096), .ADDR_BITS(12)) dl3 (
    .clk          (clk),
    .we           (we),
    .audio_in     (audio_in),
    .delay_samples(TAP3_DELAY),
    .audio_out    (tap3_raw)
);

// ── Decay: кожен тап × коефіцієнт затухання ──────────────────────
// Q1.15 множення: (a × b) >> 15
// Результат масштабований назад до 16-бітного аудіо

wire signed [31:0] tap1_mul = $signed(tap1_raw) * $signed({1'b0, DECAY1[14:0]});
wire signed [31:0] tap2_mul = $signed(tap2_raw) * $signed({1'b0, DECAY2[14:0]});
wire signed [31:0] tap3_mul = $signed(tap3_raw) * $signed({1'b0, DECAY3[14:0]});

wire signed [15:0] tap1 = tap1_mul[30:15];
wire signed [15:0] tap2 = tap2_mul[30:15];
wire signed [15:0] tap3 = tap3_mul[30:15];

// ── Wet sum: складаємо тапи ───────────────────────────────────────
// Розширюємо до 18 біт (sign-extend) щоб не переповнитись при додаванні трьох
// Потім >> 2 (ділимо на 4) щоб повернутись до 16 біт без кліпування

wire signed [17:0] wet_sum_18 = {{2{tap1[15]}}, tap1}
                              + {{2{tap2[15]}}, tap2}
                              + {{2{tap3[15]}}, tap3};

wire signed [15:0] wet_sum = wet_sum_18[16:1];  // >> 1 = ÷2  (було [17:2] = ÷4, але реверб був тихий)

// ── Wet/Dry мікс ─────────────────────────────────────────────────
wire signed [31:0] wet_mul = $signed(wet_sum)  * $signed({1'b0, wet_gain[14:0]});
wire signed [31:0] dry_mul = $signed(audio_in) * $signed({1'b0, dry_gain[14:0]});

wire signed [15:0] wet_out = wet_mul[30:15];
wire signed [15:0] dry_out = dry_mul[30:15];

// ── Фінальний вихід з захистом від переповнення ───────────────────
// Sign-extend обидва до 17 біт → додаємо → перевіряємо біти [16:15]:
//   00 = позитивне, в межах  → беремо [15:0]
//   11 = негативне, в межах  → беремо [15:0]
//   01 = позитивне переповн. → +32767
//   10 = негативне переповн. → -32768
wire signed [16:0] mix_17 = {dry_out[15], dry_out} + {wet_out[15], wet_out};

always @(posedge clk) begin
    if (we) begin
        case (mix_17[16:15])
            2'b01:   audio_out <= 16'h7FFF;   // + overflow → +max
            2'b10:   audio_out <= 16'h8000;   // - overflow → -max
            default: audio_out <= mix_17[15:0];
        endcase
    end
end

endmodule
