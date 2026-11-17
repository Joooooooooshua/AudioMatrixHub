pub mod backend;
pub mod dsp;
pub mod osc;
pub mod ring_buffer;
pub mod wav;

pub use backend::{am_core_version, am_platform_backend_name, AudioPlatformBackend, BackendKind};
pub use dsp::{
    am_dsp_configure, am_dsp_create, am_dsp_destroy, am_dsp_process_stereo_interleaved,
    am_dsp_reset, AmDspEngine,
};
pub use osc::{am_osc_slugify, decode_float_message, encode_float_message, encode_osc_string, slugify_str};
pub use ring_buffer::{
    am_ring_available_frames, am_ring_create, am_ring_destroy, am_ring_read, am_ring_reset,
    am_ring_write, AmRingBuffer,
};
pub use wav::am_wav_write_header;
