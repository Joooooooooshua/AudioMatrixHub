#ifndef AUDIOMATRIX_RUST_CORE_H
#define AUDIOMATRIX_RUST_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AmDspEngine AmDspEngine;
typedef struct AmRingBuffer AmRingBuffer;

const char *am_core_version(void);
const char *am_platform_backend_name(void);

AmDspEngine *am_dsp_create(double sample_rate);
void am_dsp_destroy(AmDspEngine *ptr);
void am_dsp_reset(AmDspEngine *ptr);
void am_dsp_configure(
    AmDspEngine *ptr,
    double sample_rate,
    bool enabled,
    float crossfeed,
    float room,
    float bass_db,
    float mid_db,
    float treble_db,
    bool limiter_enabled
);
void am_dsp_process_stereo_interleaved(
    AmDspEngine *ptr,
    float *samples,
    size_t frame_count
);

AmRingBuffer *am_ring_create(size_t capacity_frames);
void am_ring_destroy(AmRingBuffer *ptr);
void am_ring_reset(AmRingBuffer *ptr);
size_t am_ring_available_frames(const AmRingBuffer *ptr);
size_t am_ring_write(const AmRingBuffer *ptr, const float *src, size_t frame_count);
size_t am_ring_read(const AmRingBuffer *ptr, float *dst, size_t frame_count);

void am_wav_write_header(
    uint32_t sample_rate,
    uint16_t channels,
    uint32_t data_byte_size,
    uint8_t *out_44_bytes
);

size_t am_osc_slugify(const char *input, char *out_buf, size_t out_cap);

#ifdef __cplusplus
}
#endif

#endif /* AUDIOMATRIX_RUST_CORE_H */
