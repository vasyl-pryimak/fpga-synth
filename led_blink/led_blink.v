// Оголошення модуля - як клас в Java
// clk - вхід тактового сигналу (меандр 0/1/0/1...)
// led - вихід на світлодіод
module led_blink #(parameter BITS = 25) (
    input  clk,
    output led
);
    // reg - регістр, зберігає значення між тактами (як поле класу)
    // [24:0] - 25-бітне число (біти від 24 до 0)
    // = 0 - початкове значення
    reg [BITS-1:0] counter = 0;

    // always @(posedge clk) - виконується на кожному передньому фронті clk
    // аналог: while(true) { якщо новий такт -> виконай }
    always @(posedge clk) begin
        // інкрементуємо лічильник кожен такт
        // <= це non-blocking assignment (стандарт для sequential logic)
        counter <= counter + 1;
    end

    // assign - постійне з'єднання, як дріт (wire)
    // counter[24] - старший біт лічильника
    // він перемикається кожні 2^24 = 16 млн тактів
    // на частоті 50 МГц: 16M / 50M = ~0.33 сек -> LED блимає ~1.5 Гц
    assign led = counter[BITS-1];

endmodule