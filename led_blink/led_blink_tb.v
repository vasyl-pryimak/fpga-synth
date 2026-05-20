// Testbench - не синтезується на FPGA, тільки для симуляції
// як JUnit тест в Java
module led_blink_tb;
    // reg бо ми самі керуємо сигналом в testbench
    reg clk = 0;
    // wire бо це вихід з модуля (тільки читаємо)
    wire led;

    // Підключаємо модуль який тестуємо
    // uut = "Unit Under Test"
    // .clk(clk) - порт модуля clk з'єднуємо зі змінною clk
    led_blink #(.BITS(4)) uut (
        .clk(clk),
        .led(led)
    );

    // Генератор тактового сигналу
    // #1 - затримка 1 одиниця часу симуляції
    // кожну одиницю інвертуємо clk: 0->1->0->1...
    always #1 clk = ~clk;

    initial begin
        $dumpfile("led_blink.vcd");
        $dumpvars(1, led_blink_tb);
        #100 $finish;
    end

endmodule