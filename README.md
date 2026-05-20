# fpga-synth

The idea: attach a piezo to a spring to get a real analog spring reverb as a sound source. Run audio from a phone or MP3 through it, apply effects — bitcrusher, wet/dry mix, decay — controlled by potentiometers in real time. Buttons for switching effect presets are planned.

All DSP written in Verilog from scratch — no IP cores, no libraries.

> Personal learning project. Blog (Ukrainian): [vasyl-pryimak.github.io](https://vasyl-pryimak.github.io/blog/)

---

## Hardware

| Component                          | Role |
|------------------------------------|---|
| EP4CE6E22C8N (Cyclone IV)          | FPGA — main processing |
| CS4344                             | DAC — stereo audio output (I²S) |
| PCM1808 (HW-935)                   | ADC — stereo audio input (I²S) |
| ADS1115                            | 16-bit ADC — reads potentiometers (I²C) |
| Arduino UNO *(optional)*           | I²C bridge: ADS1115 → UART → FPGA |
| 4× potentiometer 10kΩ              | Volume, wet/dry, bitcrusher depth, reverb decay |

## Signal chain

```
Audio in (phone / laptop / MP3) → PCM1808 (ADC) → FPGA
                               │
                            bitcrusher (A2)
                               │
                            reverb_core ← decay (A3)
                               │         ← wet/dry (A1)
                            × volume (A0)
                               │
                           CS4344 (DAC) → Headphones
```

## FPGA pins

| Pin | Signal | Direction |
|-----|--------|-----------|
| 24  | CLK 50MHz | in |
| 110 | MCLK (CS4344 + PCM1808) | out |
| 111 | LRCLK | out |
| 112 | SCLK / BCK | out |
| 113 | SDIN → CS4344 | out |
| 115 | DOUT ← PCM1808 | in |
| 119 | SDA (ADS1115 I²C) | in/out |
| 120 | SCL (ADS1115 I²C) | out |

---

## Project structure

```
led_blink/                      — Hello World: blinking LED
i2s_sine_440/                   — 440 Hz sine wave via CS4344
i2s_passthrough/                — PCM1808 → CS4344 passthrough
i2c_volume/                     — ADS1115 → volume control
i2c_volume/arduino_as_i2c.ino  — Arduino sketch: I2C slave, reads potentiometer
spring_reverb/                  — Spring reverb prototype
spring_reverb_3_knobs/          — Main project: reverb + bitcrusher + 4 knobs
docs/                           — KiCad schematic, SVG diagrams
docs/EP4CE6E22C8N/              — Board datasheets and pin reference
```

## Potentiometers (spring_reverb_3_knobs)

| Channel | Parameter | Range |
|---------|-----------|-------|
| A0 | Volume | 0 = silence → max = full |
| A1 | Wet/dry crossfade | 0 = 100% dry → max = 100% reverb |
| A2 | Bitcrusher depth | 0 = clean 16-bit → max = lo-fi ~4-bit |
| A3 | Reverb decay | 0 = no tail → max ≈ 0.875 (long reggae tail) |

---

## Tools

- **Quartus Prime Lite** — synthesis and programming (free)
- **Icarus Verilog** — simulation
- **PulseView** + FX2 logic analyzer (24MHz 8CH clone) — signal debugging
- **USB Blaster** (CH552G clone, reflashed) — FPGA programmer

## Running on Mac M4

Quartus 20.1 via Rosetta 2 in UTM ARM64 VM (Ubuntu 24.04).  
USB Blaster forwarded via VirtualHere.  
Details: [blog post](https://vasyl-pryimak.github.io/posts/quartus-install/)
