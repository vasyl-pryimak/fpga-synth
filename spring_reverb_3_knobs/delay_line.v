// delay_line.v — circular buffer delay line у Block RAM
//
// Параметри:
//   DEPTH=4096 → ~85ms max затримки @ 48kHz, використовує ~8 M9K блоків
//   DEPTH=2048 → ~43ms max, ~4 M9K блоки
//
// Використання:
//   - we=1 один такт на кожен аудіо-семпл (на фронті LRCLK)
//   - delay_samples: 1..DEPTH-1 (0 = тот самий семпл, не має сенсу)
//   - audio_out: з'являється через 1 такт після we (pipeline latency M9K)
//
// Block RAM inference: синхронний запис + синхронне читання → Quartus
//   автоматично розміщує в M9K без явного instantiation.

module delay_line #(
    parameter DEPTH     = 4096,  // має бути степінь 2
    parameter ADDR_BITS = 12     // log2(DEPTH): 4096→12, 2048→11, 1024→10
)(
    input  wire                  clk,
    input  wire                  we,            // 1-cycle pulse per audio sample
    input  wire signed [15:0]    audio_in,
    input  wire [ADDR_BITS-1:0]  delay_samples, // затримка в семплах (1..DEPTH-1)
    output reg  signed [15:0]    audio_out
);

// Block RAM: Quartus inference — reg масив + sync read/write = M9K
reg signed [15:0] mem [0:DEPTH-1];

// Ініціалізація нулями для симуляції.
// На реальному залізі M9K теж стартує з 0 після завантаження конфігурації.
// Без цього в симуляції x (uninitialized) отруює весь результат через wet_sum.
integer _i;
initial begin
    for (_i = 0; _i < DEPTH; _i = _i + 1)
        mem[_i] = 16'sd0;
end

reg [ADDR_BITS-1:0] wr_ptr = {ADDR_BITS{1'b0}};

// Читаємо з позиції: поточний запис мінус delay (природнє переповнення модуль DEPTH)
wire [ADDR_BITS-1:0] rd_ptr = wr_ptr - delay_samples;

always @(posedge clk) begin
    if (we) begin
        mem[wr_ptr] <= audio_in;
        wr_ptr      <= wr_ptr + 1'd1;
    end
    // Синхронне читання — ключ до M9K inference
    // audio_out оновлюється кожен такт (навіть без we)
    audio_out <= mem[rd_ptr];
end

endmodule
