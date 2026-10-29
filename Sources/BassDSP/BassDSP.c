#include "BassDSP.h"
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "Real-time controls require lock-free atomics");
_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "Real-time meters require lock-free atomics");
typedef struct { double b0, b1, b2, a1, a2; } Coefficients;
typedef struct { double x1, x2, y1, y2; } History;
enum { EQ_BANDS = 9, EQ_VALUES = 93 };
typedef struct {
    Coefficients coefficients[EQ_BANDS][2];
    History history[EQ_BANDS][2];
    double gain[2];
} EQBank;
struct BassDSP {
    double rate, boost, frequency, steepness, trim;
    Coefficients coefficients;
    History history[2];
    _Atomic uint64_t settings;
    _Atomic uint32_t peak_bits, faults;
    _Atomic uint64_t callbacks;
    _Atomic uint64_t eq_sequence, eq_values[EQ_VALUES];
    uint64_t eq_seen;
    EQBank eq[2];
    int eq_current;
    uint32_t eq_remaining, eq_duration;
    double eq_mix, eq_enabled;
};
static double clamp(double x, double lo, double hi) { return fmax(lo, fmin(hi, x)); }
static uint64_t pack(double boost, double frequency, double steepness, double trim) {
    uint64_t b = (uint64_t)llround(clamp(boost, 0, 24) * 100);
    uint64_t f = (uint64_t)llround(clamp(frequency, 20, 500) * 100);
    uint64_t t = (uint64_t)llround(clamp(-trim, 0, 18) * 100);
    uint64_t s = (uint64_t)llround(clamp(steepness, 0.1, 1) * 1000);
    return b | (f << 16) | (t << 32) | (s << 48);
}
static Coefficients shelf(double rate, double boost, double frequency, double steepness) {
    double a = pow(10, boost / 40), w = 2 * M_PI * frequency / rate;
    double c = cos(w), beta = sqrt((a * a + 1) * (1 / clamp(steepness, 0.1, 1) - 1) + 2 * a) * sin(w);
    double a0 = (a + 1) + (a - 1) * c + beta;
    return (Coefficients){
        a * ((a + 1) - (a - 1) * c + beta) / a0,
        2 * a * ((a - 1) - (a + 1) * c) / a0,
        a * ((a + 1) - (a - 1) * c - beta) / a0,
        -2 * ((a - 1) + (a + 1) * c) / a0,
        ((a + 1) + (a - 1) * c - beta) / a0
    };
}
BassDSP *bass_create(double rate, double boost, double frequency, double steepness, double trim) {
    if (!isfinite(rate) || rate < 8000 || rate > 768000) return NULL;
    BassDSP *dsp = calloc(1, sizeof(*dsp));
    if (!dsp) return NULL;
    dsp->rate = rate;
    dsp->boost = clamp(boost, 0, 24);
    dsp->frequency = clamp(frequency, 20, 500);
    dsp->steepness = clamp(steepness, 0.1, 1);
    dsp->trim = clamp(trim, -18, 0);
    dsp->coefficients = shelf(rate, dsp->boost, dsp->frequency, dsp->steepness);
    atomic_init(&dsp->settings, pack(boost, frequency, steepness, trim));
    atomic_init(&dsp->peak_bits, 0);
    atomic_init(&dsp->faults, 0);
    atomic_init(&dsp->callbacks, 0);
    atomic_init(&dsp->eq_sequence, 0);
    for (int i = 0; i < EQ_VALUES; i++) atomic_init(&dsp->eq_values[i], 0);
    dsp->eq_duration = (uint32_t)(rate * 0.05);
    for (int b = 0; b < 2; b++) {
        for (int ch = 0; ch < 2; ch++) {
            dsp->eq[b].gain[ch] = 1;
            for (int i = 0; i < EQ_BANDS; i++) dsp->eq[b].coefficients[i][ch].b0 = 1;
        }
    }
    return dsp;
}
void bass_destroy(BassDSP *dsp) { free(dsp); }
void bass_configure(BassDSP *dsp, double boost, double frequency, double steepness, double trim) {
    atomic_store_explicit(&dsp->settings, pack(boost, frequency, steepness, trim), memory_order_relaxed);
}
void bass_equalizer(BassDSP *dsp, const double *coefficients, double gain_db, bool enabled) {
    bass_equalizer_stereo(dsp, coefficients, coefficients, gain_db, gain_db, enabled);
}
void bass_equalizer_stereo(BassDSP *dsp, const double *left, const double *right,
                           double left_gain_db, double right_gain_db, bool enabled) {
    double values[EQ_VALUES] = {0};
    const double *channels[2] = {left, right};
    for (int ch = 0; ch < 2; ch++) {
        for (int i = 0; i < EQ_BANDS * 5; i++) {
            if (enabled && (!channels[ch] || !isfinite(channels[ch][i]))) return;
            values[ch * 45 + i] = enabled ? channels[ch][i] : (i % 5 == 0 ? 1 : 0);
        }
    }
    if (!isfinite(left_gain_db) || !isfinite(right_gain_db)) return;
    values[90] = pow(10, fmin(0, left_gain_db) / 20);
    values[91] = pow(10, fmin(0, right_gain_db) / 20);
    values[92] = enabled ? 1 : 0;
    // Atomic payload avoids data races; the callback never waits for the writer.
    atomic_fetch_add_explicit(&dsp->eq_sequence, 1, memory_order_seq_cst);
    for (int i = 0; i < EQ_VALUES; i++) {
        uint64_t bits; memcpy(&bits, &values[i], sizeof(bits));
        atomic_store_explicit(&dsp->eq_values[i], bits, memory_order_seq_cst);
    }
    atomic_fetch_add_explicit(&dsp->eq_sequence, 1, memory_order_seq_cst);
}
static void prepare_equalizer(BassDSP *dsp) {
    if (dsp->eq_remaining) return;
    uint64_t before = atomic_load_explicit(&dsp->eq_sequence, memory_order_seq_cst);
    if ((before & 1) || before == dsp->eq_seen) return;
    double values[EQ_VALUES];
    for (int i = 0; i < EQ_VALUES; i++) {
        uint64_t bits = atomic_load_explicit(&dsp->eq_values[i], memory_order_seq_cst);
        memcpy(&values[i], &bits, sizeof(bits));
    }
    if (before != atomic_load_explicit(&dsp->eq_sequence, memory_order_seq_cst)) return;
    dsp->eq_seen = before;
    dsp->eq_enabled = values[92];
    EQBank *bank = &dsp->eq[1 - dsp->eq_current];
    memset(bank->history, 0, sizeof(bank->history));
    for (int ch = 0; ch < 2; ch++) {
        for (int i = 0; i < EQ_BANDS; i++) {
            const double *c = &values[ch * 45 + i * 5];
            bank->coefficients[i][ch] = (Coefficients){c[0], c[1], c[2], c[3], c[4]};
        }
        bank->gain[ch] = values[90 + ch];
    }
    dsp->eq_remaining = dsp->eq_duration;
}
static double equalizer_channel(BassDSP *dsp, EQBank *bank, int ch, double input) {
    double x = input * bank->gain[ch];
    for (int i = 0; i < EQ_BANDS; i++) {
        Coefficients c = bank->coefficients[i][ch];
        History *h = &bank->history[i][ch];
        double y = c.b0*x + c.b1*h->x1 + c.b2*h->x2 - c.a1*h->y1 - c.a2*h->y2;
        if (!isfinite(y)) {
            memset(h, 0, sizeof(*h));
            atomic_fetch_or_explicit(&dsp->faults, 2, memory_order_relaxed);
            y = 0;
        }
        h->x2 = h->x1; h->x1 = x; h->y2 = h->y1; h->y1 = fabs(y) < 1e-30 ? 0 : y;
        x = y;
    }
    return x;
}
static double approach(double value, double target, double step) {
    return value + clamp(target - value, -step, step);
}
static void frame(BassDSP *dsp, double left, double right, double *out_left, double *out_right, uint64_t settings) {
    double boost = (settings & 0xffff) / 100.0;
    double frequency = ((settings >> 16) & 0xffff) / 100.0;
    double trim = -((double)((settings >> 32) & 0xffff)) / 100.0;
    double steepness = ((settings >> 48) & 0x3ff) / 1000.0;
    double step = 1 / (0.05 * dsp->rate);
    if (dsp->boost != boost || dsp->frequency != frequency || dsp->steepness != steepness) {
        dsp->boost = approach(dsp->boost, boost, 24 * step);
        dsp->frequency = approach(dsp->frequency, frequency, 480 * step);
        dsp->steepness = approach(dsp->steepness, steepness, 0.9 * step);
        dsp->coefficients = shelf(dsp->rate, dsp->boost, dsp->frequency, dsp->steepness);
    }
    dsp->trim = approach(dsp->trim, trim, 18 * step);
    // Reserve the full shelf gain plus 1 dB; no compressor or limiter changes dynamics.
    double gain = pow(10, (-dsp->boost - 1 + dsp->trim) / 20);
    double inputs[2] = {left, right}, results[2];
    Coefficients c = dsp->coefficients;
    for (int ch = 0; ch < 2; ++ch) {
        History *h = &dsp->history[ch];
        double x = inputs[ch];
        double y = c.b0 * x + c.b1 * h->x1 + c.b2 * h->x2 - c.a1 * h->y1 - c.a2 * h->y2;
        if (!isfinite(y)) {
            memset(h, 0, sizeof(*h));
            y = 0;
            atomic_fetch_or_explicit(&dsp->faults, 2, memory_order_relaxed);
        } else {
            h->x2 = h->x1; h->x1 = x; h->y2 = h->y1; h->y1 = fabs(y) < 1e-30 ? 0 : y;
        }
        results[ch] = y * gain;
    }
    if (dsp->eq_mix > 0 || dsp->eq_enabled > 0 || dsp->eq_remaining) {
        double blend = dsp->eq_remaining ? 1 - (double)dsp->eq_remaining / dsp->eq_duration : 0;
        dsp->eq_mix = approach(dsp->eq_mix, dsp->eq_enabled, 1.0 / dsp->eq_duration);
        for (int ch = 0; ch < 2; ch++) {
            double wet = equalizer_channel(dsp, &dsp->eq[dsp->eq_current], ch, inputs[ch]);
            if (dsp->eq_remaining) {
                double next = equalizer_channel(dsp, &dsp->eq[1-dsp->eq_current], ch, inputs[ch]);
                wet = wet*(1-blend) + next*blend;
            }
            results[ch] = results[ch]*(1-dsp->eq_mix) + wet*dsp->eq_mix;
        }
        if (dsp->eq_remaining && --dsp->eq_remaining == 0) dsp->eq_current = 1-dsp->eq_current;
    }
    *out_left = results[0]; *out_right = results[1];
}
static void meter(BassDSP *dsp, float peak) {
    uint32_t bits; memcpy(&bits, &peak, sizeof(bits));
    uint32_t old = atomic_load_explicit(&dsp->peak_bits, memory_order_relaxed);
    if (bits > old) atomic_store_explicit(&dsp->peak_bits, bits, memory_order_relaxed);
}
float bass_take_peak(BassDSP *dsp) {
    uint32_t bits = atomic_exchange_explicit(&dsp->peak_bits, 0, memory_order_relaxed);
    float peak; memcpy(&peak, &bits, sizeof(peak)); return peak;
}
uint32_t bass_take_faults(BassDSP *dsp) { return atomic_exchange_explicit(&dsp->faults, 0, memory_order_relaxed); }
uint64_t bass_callbacks(BassDSP *dsp) { return atomic_load_explicit(&dsp->callbacks, memory_order_relaxed); }
void bass_process(BassDSP *dsp, const float *input, float *output, uint32_t frames) {
    prepare_equalizer(dsp);
    uint64_t settings = atomic_load_explicit(&dsp->settings, memory_order_relaxed);
    float peak = 0;
    for (uint32_t i = 0; i < frames; ++i) {
        double l, r; frame(dsp, input[2*i], input[2*i+1], &l, &r, settings);
        output[2*i] = (float)l; output[2*i+1] = (float)r;
        peak = fmaxf(peak, fmaxf(fabsf((float)l), fabsf((float)r)));
    }
    meter(dsp, peak);
}
double bass_response(double rate, double boost, double frequency, double steepness, double at_hz) {
    Coefficients c = shelf(rate, boost, frequency, steepness);
    double w = 2 * M_PI * at_hz / rate;
    double nr = c.b0 + c.b1 * cos(w) + c.b2 * cos(2*w);
    double ni = -c.b1 * sin(w) - c.b2 * sin(2*w);
    double dr = 1 + c.a1 * cos(w) + c.a2 * cos(2*w);
    double di = -c.a1 * sin(w) - c.a2 * sin(2*w);
    return 20 * log10(hypot(nr, ni) / hypot(dr, di));
}
typedef struct { float *data; uint32_t stride, frames; } Channel;
static bool channel(const AudioBufferList *list, uint32_t index, Channel *result) {
    for (uint32_t b = 0; b < list->mNumberBuffers; ++b) {
        AudioBuffer buffer = list->mBuffers[b];
        if (index < buffer.mNumberChannels) {
            if (!buffer.mData || buffer.mNumberChannels == 0) return false;
            *result = (Channel){(float *)buffer.mData + index, buffer.mNumberChannels,
                buffer.mDataByteSize / (sizeof(float) * buffer.mNumberChannels)};
            return true;
        }
        index -= buffer.mNumberChannels;
    }
    return false;
}
OSStatus bass_io(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input,
                 const AudioTimeStamp *input_time, AudioBufferList *output,
                 const AudioTimeStamp *output_time, void *context) {
    (void)device; (void)now; (void)input_time; (void)output_time;
    BassDSP *dsp = context;
    atomic_fetch_add_explicit(&dsp->callbacks, 1, memory_order_relaxed);
    for (uint32_t b = 0; b < output->mNumberBuffers; ++b)
        if (output->mBuffers[b].mData) memset(output->mBuffers[b].mData, 0, output->mBuffers[b].mDataByteSize);
    uint32_t channels = 0;
    for (uint32_t b = 0; b < input->mNumberBuffers; ++b) channels += input->mBuffers[b].mNumberChannels;
    Channel il, ir, ol, or;
    // The aggregate appends its sole stereo tap after the hardware input streams.
    if (channels < 2 || !channel(input, channels-2, &il) || !channel(input, channels-1, &ir)
        || !channel(output, 0, &ol) || !channel(output, 1, &or)
        || il.frames != ir.frames || il.frames != ol.frames || ol.frames != or.frames) {
        atomic_fetch_or_explicit(&dsp->faults, 1, memory_order_relaxed);
        return noErr;
    }
    prepare_equalizer(dsp);
    uint64_t settings = atomic_load_explicit(&dsp->settings, memory_order_relaxed);
    float peak = 0;
    for (uint32_t i = 0; i < ol.frames; ++i) {
        double l, r; frame(dsp, il.data[i*il.stride], ir.data[i*ir.stride], &l, &r, settings);
        ol.data[i*ol.stride] = (float)l; or.data[i*or.stride] = (float)r;
        peak = fmaxf(peak, fmaxf(fabsf((float)l), fabsf((float)r)));
    }
    meter(dsp, peak);
    return noErr;
}

OSStatus bass_attach(AudioObjectID device, BassDSP *dsp, AudioDeviceIOProcID *io_proc) {
    return AudioDeviceCreateIOProcID(device, bass_io, dsp, io_proc);
}

OSStatus bass_select_tap_input(AudioObjectID device, AudioDeviceIOProcID io_proc, uint32_t stream_count) {
    if (stream_count == 0) return kAudioHardwareIllegalOperationError;
    size_t size = offsetof(AudioHardwareIOProcStreamUsage, mStreamIsOn) + stream_count * sizeof(UInt32);
    AudioHardwareIOProcStreamUsage *usage = calloc(1, size);
    if (!usage) return kAudioHardwareUnspecifiedError;
    usage->mIOProc = (void *)io_proc;
    usage->mNumberStreams = stream_count;
    usage->mStreamIsOn[stream_count - 1] = 1;
    AudioObjectPropertyAddress property = {kAudioDevicePropertyIOProcStreamUsage,
        kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain};
    OSStatus status = AudioObjectSetPropertyData(device, &property, 0, NULL, (UInt32)size, usage);
    free(usage);
    return status;
}
