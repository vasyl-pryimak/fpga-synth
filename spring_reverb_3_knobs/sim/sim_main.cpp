// sim_main.cpp — Verilator testbench for sim_top (Reverb + Pitch Shifter)
//
// Full signal chain (via sim_top.v):
//   audio_in → pitch_shifter (A3) → reverb_core (wet path)
//   audio_in → reverb_core (dry path)
//   reverb_core → out
//
// Usage:
//   ./reverb-sim input.wav output.wav [options]

#include "Vsim_top.h"
#include "verilated.h"

#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <cstdint>
#include <vector>
#include <cmath>
#include <string>

// ── WAV I/O ────────────────────────────────────────────────────────────────

std::vector<int16_t> read_wav(const char* path, uint32_t& out_rate) {
    FILE* f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "Cannot open %s\n", path); exit(1); }
    char riff[4]; fread(riff, 1, 4, f);
    uint32_t file_size; fread(&file_size, 4, 1, f);
    char wave[4]; fread(wave, 1, 4, f);
    uint16_t channels = 1, bits = 16;
    uint32_t rate = 48000;
    std::vector<int16_t> samples;
    while (!feof(f)) {
        char id[4]; if (fread(id, 1, 4, f) < 4) break;
        uint32_t size; if (fread(&size, 4, 1, f) < 1) break;
        if (memcmp(id, "fmt ", 4) == 0) {
            uint16_t fmt; fread(&fmt, 2, 1, f);
            fread(&channels, 2, 1, f);
            fread(&rate, 4, 1, f);
            fseek(f, size - 8, SEEK_CUR);
        } else if (memcmp(id, "data", 4) == 0) {
            uint32_t n = size / (channels * 2);
            samples.resize(n);
            for (uint32_t i = 0; i < n; i++) {
                int16_t l; fread(&l, 2, 1, f);
                if (channels == 2) { int16_t r; fread(&r, 2, 1, f); samples[i] = (int16_t)(((int32_t)l+r)/2); }
                else samples[i] = l;
            }
            break;
        } else { fseek(f, size, SEEK_CUR); }
    }
    fclose(f);
    out_rate = rate;
    fprintf(stderr, "Input : %zu samples @ %u Hz\n", samples.size(), rate);
    return samples;
}

void write_wav(const char* path, const std::vector<int16_t>& s, uint32_t rate) {
    FILE* f = fopen(path, "wb");
    uint32_t data_size = s.size() * 2, file_size = 36 + data_size;
    fwrite("RIFF", 1, 4, f); fwrite(&file_size, 4, 1, f);
    fwrite("WAVE", 1, 4, f); fwrite("fmt ", 1, 4, f);
    uint32_t fs=16; fwrite(&fs,4,1,f); uint16_t fmt=1; fwrite(&fmt,2,1,f);
    uint16_t ch=1;  fwrite(&ch,2,1,f); fwrite(&rate,4,1,f);
    uint32_t br=rate*2; fwrite(&br,4,1,f); uint16_t ba=2; fwrite(&ba,2,1,f);
    uint16_t bps=16; fwrite(&bps,2,1,f);
    fwrite("data",1,4,f); fwrite(&data_size,4,1,f);
    fwrite(s.data(), 2, s.size(), f);
    fclose(f);
    fprintf(stderr, "Output: %zu samples → %s\n", s.size(), path);
}

// ── Helpers ───────────────────────────────────────────────────────────────

uint16_t to_q15(float v) {
    if (v >= 1.f) return 0x7FFF;
    if (v <= 0.f) return 0x0000;
    return (uint16_t)(v * 32767.f);
}

static int16_t clamp16(int32_t v) {
    if (v >  32767) return  32767;
    if (v < -32768) return -32768;
    return (int16_t)v;
}

// ── Main ───────────────────────────────────────────────────────────────────

int main(int argc, char** argv) {
    const char* in_path   = nullptr;
    const char* out_path  = nullptr;
    float vol_f = 0.8f, wet_f = 0.5f, decay_f = 0.6f, pitch_f = 0.5f;

    for (int i=1; i<argc; i++) {
        if      (strncmp(argv[i],"--volume=",9)==0)    vol_f   = atof(argv[i]+9);
        else if (strncmp(argv[i],"--wet=",6)==0)       wet_f   = atof(argv[i]+6);
        else if (strncmp(argv[i],"--decay=",8)==0)     decay_f = atof(argv[i]+8);
        else if (strncmp(argv[i],"--pitch=",8)==0)     pitch_f = atof(argv[i]+8);
        else if (!in_path)  in_path  = argv[i];
        else if (!out_path) out_path = argv[i];
    }

    if (!in_path || !out_path) {
        fprintf(stderr, "Usage: reverb-sim input.wav output.wav [options]\n");
        return 1;
    }

    uint32_t rate;
    auto samples = read_wav(in_path, rate);
    
    VerilatedContext* ctx = new VerilatedContext;
    Vsim_top* top = new Vsim_top(ctx);

    std::vector<int16_t> out;
    out.reserve(samples.size());

    for (size_t i=0; i<samples.size(); i++) {
        // A3: Pitch Ratio (Q2.14: 0.95 to 1.05)
        uint32_t r32 = ((uint32_t)(pitch_f * 32767.f) * 1638) >> 15;
        top->pitch_ratio = (uint16_t)(r32 + 15565);

        // A2: Decay (0..0.85)
        uint32_t decay_scaled = ((uint32_t)(decay_f * 32767.f) * 27852) >> 15;
        top->decay_gain = (uint16_t)decay_scaled;

        // A1: Wet/Dry
        top->wet_gain = to_q15(wet_f);
        top->dry_gain = 0x7FFF - top->wet_gain;

        top->audio_dry = samples[i];
        top->audio_in  = samples[i];
        top->we = 1;
        
        top->clk = 0; top->eval();
        top->clk = 1; top->eval();
        
        int16_t reverb_out = top->audio_out;
        
        // A0: Volume
        int16_t final_out = clamp16(((int32_t)reverb_out * to_q15(vol_f)) >> 15);
        out.push_back(final_out);
    }

    write_wav(out_path, out, rate);
    top->final(); delete top; delete ctx;
    return 0;
}
