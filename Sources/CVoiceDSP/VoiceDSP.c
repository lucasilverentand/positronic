#include "VoiceDSP.h"
#include <speex/speex_echo.h>
#include <speex/speex_resampler.h>
#include <rnnoise.h>
#include <math.h>
#include <stdlib.h>
#include <pthread.h>
struct PMVoiceDSP {
    SpeexEchoState *echo;
    DenoiseState *noise;
    SpeexResamplerState *resampler;
    int16_t reference[480];
};
static pthread_once_t noise_once = PTHREAD_ONCE_INIT;
static void initialize_noise_tables(void) {
    DenoiseState *warm = rnnoise_create(NULL);
    if (warm) { float zeros[480] = {0}; rnnoise_process_frame(warm, zeros, zeros); rnnoise_destroy(warm); }
}
static int16_t pcm(float value) {
    if (!isfinite(value)) return 0;
    return (int16_t)lrintf(fmaxf(-1.f, fminf(1.f, value)) * 32767.f);
}
PMVoiceDSP *pm_voice_create(int echo, int noise) {
    PMVoiceDSP *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    if (echo) {
        s->echo = speex_echo_state_init(480, 14400);
        if (!s->echo) { pm_voice_destroy(s); return NULL; }
        int rate = 48000;
        speex_echo_ctl(s->echo, SPEEX_ECHO_SET_SAMPLING_RATE, &rate);
    }
    if (noise) {
        pthread_once(&noise_once, initialize_noise_tables);
        s->noise = rnnoise_create(NULL);
        if (!s->noise) { pm_voice_destroy(s); return NULL; }
    }
    int error = 0;
    s->resampler = speex_resampler_init(1, 48000, 16000, 5, &error);
    if (!s->resampler || error) { pm_voice_destroy(s); return NULL; }
    speex_resampler_skip_zeros(s->resampler);
    return s;
}
void pm_voice_destroy(PMVoiceDSP *s) {
    if (!s) return;
    if (s->echo) speex_echo_state_destroy(s->echo);
    if (s->noise) rnnoise_destroy(s->noise);
    if (s->resampler) speex_resampler_destroy(s->resampler);
    free(s);
}
int pm_voice_render(PMVoiceDSP *s, const float *input, int count) {
    if (!s || !input || count != 480) return -1;
    if (s->echo) {
        for (int i=0; i<480; ++i) s->reference[i] = pcm(input[i]);
    }
    return 0;
}
int pm_voice_capture(PMVoiceDSP *s, const float *input, int count, float *output, int capacity) {
    if (!s || !input || !output || count != 480 || capacity < 160) return -1;
    int16_t microphone[480], cancelled[480];
    float clean[480];
    for (int i=0; i<480; ++i) microphone[i] = pcm(input[i]);
    if (s->echo) speex_echo_cancellation(s->echo, microphone, s->reference, cancelled);
    for (int i=0; i<480; ++i) clean[i] = s->echo ? cancelled[i] : microphone[i];
    if (s->noise) rnnoise_process_frame(s->noise, clean, clean);
    for (int i=0; i<480; ++i) clean[i] = fmaxf(-1.f, fminf(1.f, clean[i] / 32768.f));
    spx_uint32_t in_count = 480, out_count = 160;
    if (speex_resampler_process_float(s->resampler, 0, clean, &in_count, output, &out_count) || in_count != 480) return -1;
    return (int)out_count;
}
