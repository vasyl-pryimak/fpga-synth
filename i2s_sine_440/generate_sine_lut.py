#!/usr/bin/env python3
"""
Генератор таблиці синуса для FPGA I2S проєкту.

Що це і навіщо:
  FPGA не може рахувати sin(x) на льоту — це складна математика.
  Тому рахуємо заздалегідь 256 значень синуса (один повний оберт 0°..360°)
  і зберігаємо у файл sine_lut.hex.
  Verilog зчитає цей файл як ROM і просто індексуватиме по ньому.

Результат:
  256 рядків у форматі hex, кожен — 16-бітне знакове число у two's complement.
  Діапазон: -32767 .. +32767  (16-bit signed PCM)
"""

import math

ENTRIES = 256        # кількість точок на один оберт синуса
MAX_VAL = 32767      # максимум 16-bit signed (32768 - 1)

with open("sine_lut.hex", "w") as f:
    for i in range(ENTRIES):
        angle = 2 * math.pi * i / ENTRIES          # кут в радіанах
        value = round(MAX_VAL * math.sin(angle))   # -32767 .. +32767
        value_u16 = value & 0xFFFF                 # two's complement 16-bit
        f.write(f"{value_u16:04X}\n")

print(f"OK: sine_lut.hex згенеровано ({ENTRIES} значень, 16-bit signed)")
print(f"    Перше: 0000 (sin 0° = 0)")
print(f"    Пік  : {round(MAX_VAL * math.sin(math.pi/2)):+d} на index 64")
