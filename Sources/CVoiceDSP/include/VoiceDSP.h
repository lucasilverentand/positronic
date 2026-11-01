#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct PMVoiceDSP PMVoiceDSP;
/* One state per stream. Caller serializes all operations. 10 ms at 48 kHz.
 * Supply the contemporaneous render reference before each capture block. */
PMVoiceDSP *pm_voice_create(int echo, int noise);
void pm_voice_destroy(PMVoiceDSP *state);
int pm_voice_render(PMVoiceDSP *state, const float *samples, int count);
int pm_voice_capture(PMVoiceDSP *state, const float *samples, int count, float *output, int capacity);
#ifdef __cplusplus
}
#endif
