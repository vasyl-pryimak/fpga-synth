#include <Wire.h>
#define POT_PIN A0

volatile int smoothed = 512;
volatile bool requested = false;

void setup() {
    Serial.begin(9600);
    digitalWrite(SDA, LOW);
    digitalWrite(SCL, LOW);
    smoothed = analogRead(POT_PIN);
    Wire.begin(0x48);
    Wire.onRequest(sendReading);
    Wire.onReceive(receiveCmd);
    Serial.println("I2C slave started at 0x48");
}

void loop() {
    smoothed = (smoothed * 7 + analogRead(POT_PIN)) / 8;
    if (requested) {
        Serial.print("Sent: ");
        Serial.println(smoothed);
        requested = false;
    }
    delay(5);
}

void receiveCmd(int bytes) {
    while (Wire.available()) Wire.read();
}

void sendReading() {
    requested = true;
//    int16_t val = map(smoothed, 0, 1023, 0, 99);

// Перетворення десяткового числа (0-99) в BCD (0x00 - 0x99)
// byte bcdVal = ((val / 10) << 4) | (val % 10);

// Serial.print("Sent BCD as HEX: 0x");
// Serial.println(bcdVal, HEX);

Wire.write(smoothed);
}