// delay_line_tb.v — testbench для delay_line
//
// Тест: impulse response
//   Посилаємо 1000 на семпл 0, потім нулі.
//   Очікуємо: 1000 з'явиться на виході через delay_samples семплів.
//
// Запуск:
//   iverilog -o delay_line.vvp delay_line.v delay_line_tb.v
//   vvp delay_line.vvp
//   (відкрити delay_line.vcd у WaveTrace/GTKWave)

`timescale 1ns/1ps

module delay_line_tb;

// ── Тактовий сигнал 50 MHz (period = 20 ns) ──────────────────────
reg clk = 0;
always #10 clk = ~clk;

// ── Audio sample clock: 48 kHz → один pulse кожні 1041 тактів ────
// (50_000_000 / 48_000 ≈ 1041.67, округлюємо)
reg        we     = 0;
integer    we_ctr = 0;

always @(posedge clk) begin
    if (we_ctr == 1040) begin
        we_ctr <= 0;
        we     <= 1'b1;
    end else begin
        we_ctr <= we_ctr + 1;
        we     <= 1'b0;
    end
end

// ── DUT ──────────────────────────────────────────────────────────
localparam TEST_DELAY = 3;  // семплів затримки (маленьке для швидкого тесту)

reg  signed [15:0] audio_in     = 16'sd0;
wire        [11:0] delay_samples = 12'd3;
wire signed [15:0] audio_out;

delay_line #(
    .DEPTH(4096),
    .ADDR_BITS(12)
) dut (
    .clk          (clk),
    .we           (we),
    .audio_in     (audio_in),
    .delay_samples(delay_samples),
    .audio_out    (audio_out)
);

// ── Генерація вхідного сигналу: impulse на семпл 0 ───────────────
integer sample_num = 0;

always @(posedge clk) begin
    if (we) begin
        case (sample_num)
            0: audio_in <= 16'sd1000;   // impulse
            default: audio_in <= 16'sd0;
        endcase
        sample_num <= sample_num + 1;
    end
end

// ── Монітор ───────────────────────────────────────────────────────
always @(posedge clk) begin
    if (we) begin
        $display("sample %02d:  in = %6d   out = %6d  %s",
            sample_num,
            audio_in,
            audio_out,
            (audio_out != 0) ? "<-- delayed!" : ""
        );
    end
end

// ── Перевірка результату ─────────────────────────────────────────
// Через N+1 семплів (pipeline latency = 1 такт) маємо побачити 1000
// На семпл TEST_DELAY+1 виход має бути 1000
always @(posedge clk) begin
    if (we && sample_num == TEST_DELAY + 1) begin
        if (audio_out == 16'sd1000)
            $display(">>> PASS: delayed sample arrived at sample %0d <<<", sample_num);
        else
            $display(">>> FAIL: expected 1000, got %0d at sample %0d <<<", audio_out, sample_num);
    end
end

// ── Запуск ────────────────────────────────────────────────────────
initial begin
    $dumpfile("delay_line.vcd");
    $dumpvars(0, delay_line_tb);
    $display("--- delay_line_tb: delay = %0d samples ---", TEST_DELAY);
    // Запускаємо 10 семплів
    repeat (10 * 1041) @(posedge clk);
    $display("--- done ---");
    $finish;
end

endmodule
