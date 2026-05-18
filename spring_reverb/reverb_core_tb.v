// reverb_core_tb.v — testbench для reverb_core
//
// Використовує КОРОТКІ затримки (5/10/18 семплів замість 1100/2250/3900)
// щоб симуляція завершилась за ~30 семплів, а не за 4000.
//
// Тест: impulse response
//   Посилаємо 10000 на семпл 0 (impulse), решта — нулі.
//   Очікуємо: загасаючі ехо на виході через TAP1, TAP2, TAP3 семплів.
//
// Запуск:
//   iverilog -o reverb_core.vvp delay_line.v reverb_core.v reverb_core_tb.v
//   vvp reverb_core.vvp

`timescale 1ns/1ps

module reverb_core_tb;

// ── Тактовий сигнал 50 MHz ────────────────────────────────────────
reg clk = 0;
always #10 clk = ~clk;

// ── Audio sample clock: 48 kHz ────────────────────────────────────
reg     we     = 0;
integer we_ctr = 0;
always @(posedge clk) begin
    if (we_ctr == 1040) begin we_ctr <= 0; we <= 1'b1; end
    else                begin we_ctr <= we_ctr + 1; we <= 1'b0; end
end

// ── DUT з короткими затримками для швидкої симуляції ─────────────
// TAP1=5, TAP2=10, TAP3=18 семплів
// decay: 0.75 / 0.60 / 0.45
// wet=0.50, dry=0.75

reg  signed [15:0] audio_in  = 16'sd0;
wire signed [15:0] audio_out;

reverb_core #(
    .TAP1_DELAY (12'd5),
    .TAP2_DELAY (12'd10),
    .TAP3_DELAY (12'd18),
    .DECAY1     (16'h6000),   // 0.750
    .DECAY2     (16'h4CCD),   // 0.600
    .DECAY3     (16'h399A),   // 0.450
    .WET_GAIN   (16'h4000),   // 0.500
    .DRY_GAIN   (16'h6000)    // 0.750
) dut (
    .clk      (clk),
    .we       (we),
    .audio_in (audio_in),
    .audio_out(audio_out)
);

// ── Impulse: тільки перший семпл ненульовий ───────────────────────
integer sample_num = 0;
always @(posedge clk) begin
    if (we) begin
        audio_in   <= (sample_num == 0) ? 16'sd10000 : 16'sd0;
        sample_num <= sample_num + 1;
    end
end

// ── Монітор ───────────────────────────────────────────────────────
always @(posedge clk) begin
    if (we) begin
        $display("sample %02d:  in = %7d   out = %7d  %s",
            sample_num,
            audio_in,
            audio_out,
            (audio_out != 0 && sample_num > 0) ? "<-- echo" : ""
        );
    end
end

// ── Перевірки ─────────────────────────────────────────────────────
// Перевіряємо що dry сигнал на виході (семпл 1 — impulse вже пройшов через dry path)
// dry_out = 10000 * 0.75 = 7500
// Через 1 такт pipeline delay_line → ехо не на тапі N, а N+1

always @(posedge clk) begin
    if (we) begin
        // Dry сигнал: семпл 1 (impulse на семплі 0 + 1 такт реєстрації)
        if (sample_num == 1 && audio_out != 0)
            $display("  >>> PASS: dry signal present at sample 1 (out=%0d) <<<", audio_out);

        // Tap1 ехо: семпл 5+1=6 (delay=5 + 1 pipeline)
        if (sample_num == 6 && audio_out != 0)
            $display("  >>> PASS: tap1 echo at sample 6 (out=%0d, expect ~3750) <<<", audio_out);

        // Tap2 ехо: семпл 10+1=11
        if (sample_num == 11 && audio_out != 0)
            $display("  >>> PASS: tap2 echo at sample 11 (out=%0d, expect ~3000) <<<", audio_out);

        // Tap3 ехо: семпл 18+1=19
        if (sample_num == 19 && audio_out != 0)
            $display("  >>> PASS: tap3 echo at sample 19 (out=%0d, expect ~2250) <<<", audio_out);
    end
end

// ── Запуск ────────────────────────────────────────────────────────
initial begin
    $dumpfile("reverb_core.vcd");
    $dumpvars(0, reverb_core_tb);
    $display("--- reverb_core_tb: taps at samples 5/10/18, decay 0.75/0.60/0.45 ---");
    $display("--- dry=0.75, wet=0.50, impulse=10000 ---");
    $display("");
    // Запускаємо 25 семплів
    repeat (25 * 1041) @(posedge clk);
    $display("");
    $display("--- done ---");
    $finish;
end

endmodule
