#ifndef BASS_DSP_H
#define BASS_DSP_H
#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

typedef struct BassDSP BassDSP;
BassDSP *bass_create(double sample_rate, double boost_db, double frequency, double steepness, double trim_db);
OSStatus bass_attach(AudioObjectID device, BassDSP *dsp, AudioDeviceIOProcID *io_proc);
OSStatus bass_select_tap_input(AudioObjectID device, AudioDeviceIOProcID io_proc, uint32_t stream_count);
void bass_destroy(BassDSP *dsp);
// Single control-thread writer; coefficients are nine [b0,b1,b2,a1,a2] sections.
void bass_equalizer(BassDSP *dsp, const double *coefficients, double gain_db, bool enabled);
void bass_equalizer_stereo(BassDSP *dsp, const double *left, const double *right, double left_gain_db, double right_gain_db, bool enabled);
void bass_configure(BassDSP *dsp, double boost_db, double frequency, double steepness, double trim_db);
void bass_process(BassDSP *dsp, const float *input, float *output, uint32_t frames);
float bass_take_peak(BassDSP *dsp);
uint32_t bass_take_faults(BassDSP *dsp);
uint64_t bass_callbacks(BassDSP *dsp);
double bass_response(double sample_rate, double boost_db, double frequency, double steepness, double at_hz);
OSStatus bass_io(AudioObjectID device, const AudioTimeStamp *now, const AudioBufferList *input,
                 const AudioTimeStamp *input_time, AudioBufferList *output,
                 const AudioTimeStamp *output_time, void *context);
#endif
