// reverb_core.v — Schroeder comb filters + wet/dry mix
//
// Архітектура (3 паралельних comb filter):
//
//   audio_in ──┬──────────────────────────────── × dry_gain ─────────┐
//              │                                                      │
//         ┌────┴────────────────────────────────────────────┐        │
//         │                                                 │        │
//      dl1_in = audio_in + tap1×decay           dl3_in = ...        │
//         │         ↑                                                 │
//      [dl1: 1100s] │feedback                                        │
//         │         └── tap1_raw                                     │
//         │                                                          │
//      dl2_in = audio_in + tap2×decay                               │
//         │         ↑                                                 │
//      [dl2: 2250s] │                                               │
//         │         └── tap2_raw                                     │
//         │                                                          │
//      dl3_in = audio_in + tap3×decay                               │
//         │         ↑                                                 │
//      [dl3: 3900s] │                                               │
//                   └── tap3_raw                                     │
//                                                                    │
//   wet_sum = (tap1 + tap2 + tap3) / 2                              │
//   wet_out = wet_sum × wet_gain ──────────────────────── + ────────┘
//                                                          │
//                                                      audio_out
//
// decay_gain (A2): 0 = сухі відлуння, ~0.75 max = довгий хвіст
// Кожен comb filter резонує на своїй частоті → немає "репіння"

module reverb_core #(
    parameter [11:0] TAP1_DELAY = 12'd1100,  // ~22.9 мс @ 48kHz
    parameter [11:0] TAP2_DELAY = 12'd2250,  // ~46.9 мс
    parameter [11:0] TAP3_DELAY = 12'd3900   // ~81.3 мс
)(
    input  wire               clk,
    input  wire               we,
    input  wire signed [15:0] audio_in,
    input  wire        [15:0] wet_gain,    // Q1.15, A1
    input  wire        [15:0] dry_gain,    // Q1.15, = 0x7FFF
    input  wire        [15:0] decay_gain,  // Q1.15, A2 — feedback (capped at 0.75)
    output reg  signed [15:0] audio_out
);

// ── Три delay lines (читають свій вихід на кожен такт) ────────────
wire signed [15:0] tap1_raw, tap2_raw, tap3_raw;

// ── Per-tap feedback: кожен dl ← audio_in + власний вихід × decay ─
// Schroeder: dl_in = audio_in + tap × decay_gain
// tap вже доступний з попереднього такту (синхронне RAM читання)

wire signed [31:0] fb1_mul = $signed(tap1_raw) * $signed({1'b0, decay_gain[14:0]});
wire signed [31:0] fb2_mul = $signed(tap2_raw) * $signed({1'b0, decay_gain[14:0]});
wire signed [31:0] fb3_mul = $signed(tap3_raw) * $signed({1'b0, decay_gain[14:0]});

wire signed [15:0] fb1 = fb1_mul[30:15];
wire signed [15:0] fb2 = fb2_mul[30:15];
wire signed [15:0] fb3 = fb3_mul[30:15];

// Saturation на вході кожного delay line
wire signed [16:0] din1_17 = {audio_in[15], audio_in} + {fb1[15], fb1};
wire signed [16:0] din2_17 = {audio_in[15], audio_in} + {fb2[15], fb2};
wire signed [16:0] din3_17 = {audio_in[15], audio_in} + {fb3[15], fb3};

wire signed [15:0] din1 = (din1_17[16:15]==2'b01) ? 16'h7FFF : (din1_17[16:15]==2'b10) ? 16'h8000 : din1_17[15:0];
wire signed [15:0] din2 = (din2_17[16:15]==2'b01) ? 16'h7FFF : (din2_17[16:15]==2'b10) ? 16'h8000 : din2_17[15:0];
wire signed [15:0] din3 = (din3_17[16:15]==2'b01) ? 16'h7FFF : (din3_17[16:15]==2'b10) ? 16'h8000 : din3_17[15:0];

delay_line #(.DEPTH(4096), .ADDR_BITS(12)) dl1 (
    .clk(clk), .we(we), .audio_in(din1), .delay_samples(TAP1_DELAY), .audio_out(tap1_raw)
);
delay_line #(.DEPTH(4096), .ADDR_BITS(12)) dl2 (
    .clk(clk), .we(we), .audio_in(din2), .delay_samples(TAP2_DELAY), .audio_out(tap2_raw)
);
delay_line #(.DEPTH(4096), .ADDR_BITS(12)) dl3 (
    .clk(clk), .we(we), .audio_in(din3), .delay_samples(TAP3_DELAY), .audio_out(tap3_raw)
);

// ── Wet sum ───────────────────────────────────────────────────────
wire signed [17:0] wet_sum_18 = {{2{tap1_raw[15]}}, tap1_raw}
                              + {{2{tap2_raw[15]}}, tap2_raw}
                              + {{2{tap3_raw[15]}}, tap3_raw};
wire signed [15:0] wet_sum = wet_sum_18[16:1];  // ÷2

// ── Wet/Dry мікс ─────────────────────────────────────────────────
wire signed [31:0] wet_mul = $signed(wet_sum)  * $signed({1'b0, wet_gain[14:0]});
wire signed [31:0] dry_mul = $signed(audio_in) * $signed({1'b0, dry_gain[14:0]});
wire signed [15:0] wet_out = wet_mul[30:15];
wire signed [15:0] dry_out = dry_mul[30:15];

wire signed [16:0] mix_17 = {dry_out[15], dry_out} + {wet_out[15], wet_out};

always @(posedge clk) begin
    if (we) begin
        case (mix_17[16:15])
            2'b01:   audio_out <= 16'h7FFF;
            2'b10:   audio_out <= 16'h8000;
            default: audio_out <= mix_17[15:0];
        endcase
    end
end

endmodule
