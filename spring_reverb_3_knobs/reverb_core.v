// reverb_core.v — Schroeder comb filters + crossfading wet/dry mix
//
// Focused on A1 (Wet/Dry) and A2 (Decay). A3 removed for now.

module reverb_core #(
    parameter [11:0] TAP1_DELAY = 12'd1100,
    parameter [11:0] TAP2_DELAY = 12'd2250,
    parameter [11:0] TAP3_DELAY = 12'd3900
)(
    input  wire               clk,
    input  wire               we,
    input  wire signed [15:0] audio_in,
    input  wire signed [15:0] audio_dry,
    input  wire        [15:0] wet_gain,
    input  wire        [15:0] dry_gain,
    input  wire        [15:0] decay_gain,
    output reg  signed [15:0] audio_out
);

// ── Feedback calculation ──────────────────────────────────────────
wire signed [15:0] tap1_raw, tap2_raw, tap3_raw;

wire signed [31:0] fb1_mul = $signed(tap1_raw) * $signed({1'b0, decay_gain[14:0]});
wire signed [31:0] fb2_mul = $signed(tap2_raw) * $signed({1'b0, decay_gain[14:0]});
wire signed [31:0] fb3_mul = $signed(tap3_raw) * $signed({1'b0, decay_gain[14:0]});

wire signed [15:0] fb1 = fb1_mul[30:15];
wire signed [15:0] fb2 = fb2_mul[30:15];
wire signed [15:0] fb3 = fb3_mul[30:15];

function signed [15:0] sat17;
    input signed [16:0] val;
    begin
        case (val[16:15])
            2'b01:   sat17 = 16'sh7FFF;
            2'b10:   sat17 = 16'sh8000;
            default: sat17 = val[15:0];
        endcase
    end
endfunction

// Reverted: input is NOT scaled by decay_gain to fix volume drop issues
wire signed [16:0] din1_17 = {audio_in[15], audio_in} + {fb1[15], fb1};
wire signed [16:0] din2_17 = {audio_in[15], audio_in} + {fb2[15], fb2};
wire signed [16:0] din3_17 = {audio_in[15], audio_in} + {fb3[15], fb3};

delay_line #(.DEPTH(4096), .ADDR_BITS(12)) dl1 (
    .clk(clk), .we(we), .audio_in(sat17(din1_17)), .delay_samples(TAP1_DELAY), .audio_out(tap1_raw)
);
delay_line #(.DEPTH(4096), .ADDR_BITS(12)) dl2 (
    .clk(clk), .we(we), .audio_in(sat17(din2_17)), .delay_samples(TAP2_DELAY), .audio_out(tap2_raw)
);
delay_line #(.DEPTH(4096), .ADDR_BITS(12)) dl3 (
    .clk(clk), .we(we), .audio_in(sat17(din3_17)), .delay_samples(TAP3_DELAY), .audio_out(tap3_raw)
);

// ── Wet sum ───────────────────────────────────────────────────────
wire signed [17:0] wet_sum_18 = {{2{tap1_raw[15]}}, tap1_raw}
                              + {{2{tap2_raw[15]}}, tap2_raw}
                              + {{2{tap3_raw[15]}}, tap3_raw};
wire signed [15:0] wet_sum = sat17(wet_sum_18[17:1]);

// ── Crossfading Wet/Dry mix ───────────────────────────────────────
wire signed [31:0] wet_mul = $signed(wet_sum)   * $signed({1'b0, wet_gain[14:0]});
wire signed [31:0] dry_mul = $signed(audio_dry) * $signed({1'b0, dry_gain[14:0]});

wire signed [15:0] wet_out = wet_mul[30:15];
wire signed [15:0] dry_out = dry_mul[30:15];

wire signed [16:0] mix_17 = {dry_out[15], dry_out} + {wet_out[15], wet_out};

always @(posedge clk) begin
    if (we) begin
        audio_out <= sat17(mix_17);
    end
end

endmodule
