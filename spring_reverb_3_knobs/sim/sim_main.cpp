// sim_main.cpp — Verilator testbench for reverb_core
//
// Full signal chain (mirrors spring_reverb.v):
//   audio_in → reverb_core (audio_in, audio_dry)
//   reverb_core → × volume (A0) → out
//
// Usage:
//   ./reverb-sim input.wav output.wav [options]
//
// Options (fixed or start:end sweep):
//   --volume=0.8        A0: volume (0=silence, 1=full)
//   --wet=0.8           A1: wet/dry (0=dry, 1=full reverb)
//   --decay=0.6         A2: reverb tail (0=no tail, 1=max ~0.85 extreme)
//   --sweep-dur=10      sweep duration in seconds (default: full song)
//   --auto=curve.csv    CSV automation

#include "Vreverb_core.h"
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
    if (memcmp(riff, "RIFF", 4)) { fprintf(stderr, "Not a RIFF file\n"); exit(1); }
    uint32_t file_size; fread(&file_size, 4, 1, f);
    char wave[4]; fread(wave, 1, 4, f);
    if (memcmp(wave, "WAVE", 4)) { fprintf(stderr, "Not a WAVE file\n"); exit(1); }

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
            uint32_t br; fread(&br, 4, 1, f);
            uint16_t ba; fread(&ba, 2, 1, f);
            fread(&bits, 2, 1, f);
            if (size > 16) fseek(f, size - 16, SEEK_CUR);
            if (bits != 16) { fprintf(stderr, "Only 16-bit WAV supported\n"); exit(1); }
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
    fprintf(stderr, "Input : %zu samples @ %u Hz, %u ch\n", samples.size(), rate, channels);
    return samples;
}

void write_wav(const char* path, const std::vector<int16_t>& s, uint32_t rate) {
    FILE* f = fopen(path, "wb");
    if (!f) { fprintf(stderr, "Cannot write %s\n", path); exit(1); }
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

// ── Automation ─────────────────────────────────────────────────────────────

struct AutoPoint { float time_sec, volume, wet, decay, predelay; };

static float lerp(float t, float t0, float v0, float t1, float v1) {
    if (t1 <= t0) return v0;
    float a = (t-t0)/(t1-t0);
    if (a < 0) a = 0; if (a > 1) a = 1;
    return v0 + a*(v1-v0);
}

static void auto_at(const std::vector<AutoPoint>& pts, float t,
                    float& vol, float& wet, float& decay, float& predelay) {
    if (pts.empty()) return;
    if (t <= pts.front().time_sec) { vol=pts.front().volume; wet=pts.front().wet; decay=pts.front().decay; predelay=pts.front().predelay; return; }
    if (t >= pts.back().time_sec)  { vol=pts.back().volume;  wet=pts.back().wet;  decay=pts.back().decay;  predelay=pts.back().predelay;  return; }
    for (size_t i=1; i<pts.size(); i++) {
        if (t <= pts[i].time_sec) {
            float t0=pts[i-1].time_sec, t1=pts[i].time_sec;
            vol      = lerp(t, t0, pts[i-1].volume,   t1, pts[i].volume);
            wet      = lerp(t, t0, pts[i-1].wet,      t1, pts[i].wet);
            decay    = lerp(t, t0, pts[i-1].decay,    t1, pts[i].decay);
            predelay = lerp(t, t0, pts[i-1].predelay, t1, pts[i].predelay);
            return;
        }
    }
}

std::vector<AutoPoint> load_csv(const char* path) {
    FILE* f = fopen(path, "r"); if (!f) { fprintf(stderr, "Cannot open %s\n", path); exit(1); }
    std::vector<AutoPoint> pts;
    char line[256];
    while (fgets(line, sizeof(line), f)) {
        if (line[0]=='#' || line[0]=='\n') continue;
        AutoPoint p;
        if (sscanf(line, "%f,%f,%f,%f,%f", &p.time_sec, &p.volume, &p.wet, &p.decay, &p.predelay) == 5)
            pts.push_back(p);
    }
    fclose(f);
    fprintf(stderr, "Auto  : %zu points from %s\n", pts.size(), path);
    return pts;
}

// ── Param ──────────────────────────────────────────────────────────────────

struct Param {
    float start, end;
    bool is_sweep() const { return start != end; }
    float at(float t) const { return start + t*(end-start); }
};

Param parse_param(const char* s) {
    Param p; char buf[64]; strncpy(buf, s, 63);
    char* c = strchr(buf, ':');
    if (c) { *c='\0'; p.start=atof(buf); p.end=atof(c+1); }
    else   { p.start = p.end = atof(buf); }
    return p;
}

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

static uint64_t sim_time = 0;
void tick(Vreverb_core* top) {
    top->clk=0; top->eval(); sim_time++;
    top->clk=1; top->eval(); sim_time++;
}

// ── Pre-delay (Bypassed in main loop) ─────────────────────────────────────

// ── Main ───────────────────────────────────────────────────────────────────

int main(int argc, char** argv) {
    const char* in_path   = nullptr;
    const char* out_path  = nullptr;
    const char* auto_path = nullptr;
    Param vol_p      = {1.0f, 1.0f};
    Param wet_p      = {0.8f, 0.8f};
    Param decay_p    = {0.6f, 0.6f};
    Param predelay_p = {0.0f, 0.0f}; // Ignored for now
    float sweep_dur  = -1.f;

    for (int i=1; i<argc; i++) {
        if      (strncmp(argv[i],"--volume=",9)==0)    vol_p      = parse_param(argv[i]+9);
        else if (strncmp(argv[i],"--wet=",6)==0)       wet_p      = parse_param(argv[i]+6);
        else if (strncmp(argv[i],"--decay=",8)==0)     decay_p    = parse_param(argv[i]+8);
        else if (strncmp(argv[i],"--sweep-dur=",12)==0) sweep_dur  = atof(argv[i]+12);
        else if (strncmp(argv[i],"--auto=",7)==0)      auto_path  = argv[i]+7;
        else if (!in_path)  in_path  = argv[i];
        else if (!out_path) out_path = argv[i];
    }

    if (!in_path || !out_path) {
        fprintf(stderr,
            "Usage: reverb-sim input.wav output.wav [options]\n"
            "  --volume=1.0       A0: volume\n"
            "  --wet=0.8          A1: wet/dry\n"
            "  --decay=0.6        A2: reverb tail (0..1 -> 0..0.85)\n"
            "  --sweep-dur=10     sweep duration in seconds\n"
            "  --auto=curve.csv   CSV: time,volume,wet,decay,predelay\n");
        return 1;
    }

    uint32_t rate;
    auto samples = read_wav(in_path, rate);
    size_t total = samples.size();

    std::vector<AutoPoint> auto_pts;
    if (auto_path) auto_pts = load_csv(auto_path);

    VerilatedContext* ctx = new VerilatedContext;
    ctx->commandArgs(argc, argv);
    Vreverb_core* top = new Vreverb_core(ctx);
    top->we=0; top->audio_in=top->audio_dry=0; top->wet_gain=top->dry_gain=top->decay_gain=0;
    for (int i=0; i<8; i++) tick(top);

    std::vector<int16_t> out;
    out.reserve(total);

    float dur = (sweep_dur > 0.f) ? sweep_dur : (float)total / (float)rate;
    float prev_wet=-1, prev_decay=-1;

    for (size_t i=0; i<total; i++) {
        float t_sec = (float)i / (float)rate;
        float t_pos = t_sec / dur; if (t_pos > 1.f) t_pos = 1.f;

        float vol, wet, decay, predelay_dummy;
        if (!auto_pts.empty()) {
            auto_at(auto_pts, t_sec, vol, wet, decay, predelay_dummy);
        } else {
            vol      = vol_p.at(t_pos);
            wet      = wet_p.at(t_pos);
            decay    = decay_p.at(t_pos);
        }

        // A1/A2: reverb_core settings
        if (wet != prev_wet || decay != prev_decay) {
            // A2 decay: hardware formula (0..0.85 limit)
            uint16_t decay_raw = to_q15(decay);
            uint32_t decay_scaled = ((uint32_t)decay_raw * 27852) >> 15;
            top->decay_gain = (uint16_t)decay_scaled;

            top->wet_gain   = to_q15(wet);
            top->dry_gain   = 0x7FFF - top->wet_gain;
            prev_wet = wet; prev_decay = decay;
        }

        top->audio_dry = samples[i]; // Direct path
        top->audio_in  = samples[i]; // Wet path (No Pre-delay)
        top->we = 1; tick(top);
        int16_t reverb_out = top->audio_out;
        top->we = 0; tick(top);

        // A0: volume
        uint16_t vol_q15 = to_q15(vol);
        int16_t final_out = clamp16(((int32_t)reverb_out * vol_q15) >> 15);
        out.push_back(final_out);
    }

    if (!auto_pts.empty()) {
        fprintf(stderr, "Mode  : CSV automation, %zu points\n", auto_pts.size());
    } else {
        fprintf(stderr, "volume: %.2f%s\n", vol_p.start, vol_p.is_sweep() ? (" → "+std::to_string(vol_p.end)).c_str() : "");
        fprintf(stderr, "wet   : %.2f%s\n", wet_p.start, wet_p.is_sweep() ? (" → "+std::to_string(wet_p.end)).c_str() : "");
        fprintf(stderr, "decay : %.2f%s\n", decay_p.start, decay_p.is_sweep() ? (" → "+std::to_string(decay_p.end)).c_str() : "");
    }

    write_wav(out_path, out, rate);
    top->final(); delete top; delete ctx;
    return 0;
}
