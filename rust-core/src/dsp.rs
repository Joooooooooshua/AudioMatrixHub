use std::f32::consts::PI;

const ITD_BUFFER_SIZE: usize = 256;
const ITD_BUFFER_MASK: usize = 255;
const ROOM_BUFFER_SIZE: usize = 8192;
const ROOM_BUFFER_MASK: usize = 8191;
const MAX_SCRATCH_SAMPLES: usize = 16_384;

#[derive(Clone, Copy)]
struct BiquadCoeffs {
    b0: f32,
    b1: f32,
    b2: f32,
    a1: f32,
    a2: f32,
}

impl Default for BiquadCoeffs {
    fn default() -> Self {
        Self {
            b0: 1.0,
            b1: 0.0,
            b2: 0.0,
            a1: 0.0,
            a2: 0.0,
        }
    }
}

#[derive(Default, Clone, Copy)]
struct BiquadState {
    z1_l: f32,
    z2_l: f32,
    z1_r: f32,
    z2_r: f32,
}

impl BiquadState {
    fn reset(&mut self) {
        self.z1_l = 0.0;
        self.z2_l = 0.0;
        self.z1_r = 0.0;
        self.z2_r = 0.0;
    }

    #[inline(always)]
    fn process_stereo(&mut self, left: &mut f32, right: &mut f32, c: &BiquadCoeffs) {
        let out_l = c.b0 * *left + self.z1_l;
        self.z1_l = c.b1 * *left - c.a1 * out_l + self.z2_l;
        self.z2_l = c.b2 * *left - c.a2 * out_l;
        *left = out_l;

        let out_r = c.b0 * *right + self.z1_r;
        self.z1_r = c.b1 * *right - c.a1 * out_r + self.z2_r;
        self.z2_r = c.b2 * *right - c.a2 * out_r;
        *right = out_r;
    }
}

/// Zero-allocation real-time stereo DSP processor shared across platforms via C-ABI.
pub struct AmDspEngine {
    sample_rate: f64,
    target_enabled: bool,
    target_crossfeed: f32,
    target_room: f32,
    target_bass_db: f32,
    target_mid_db: f32,
    target_treble_db: f32,
    target_limiter_enabled: bool,

    cur_crossfeed: f32,
    cur_room: f32,
    cur_bass_db: f32,
    cur_mid_db: f32,
    cur_treble_db: f32,
    cur_active_blend: f32,
    initialized_params: bool,

    last_bass_db: f32,
    last_mid_db: f32,
    last_treble_db: f32,
    last_sample_rate: f64,

    itd_delay_l: Vec<f32>,
    itd_delay_r: Vec<f32>,
    itd_write_idx: usize,

    room_delay_l: Vec<f32>,
    room_delay_r: Vec<f32>,
    room_write_idx: usize,

    shadow_lp_l: f32,
    shadow_lp_r: f32,
    bass_comp_lp_l: f32,
    bass_comp_lp_r: f32,
    room_damp_l: f32,
    room_damp_r: f32,

    low_shelf_coeffs: BiquadCoeffs,
    low_shelf_state: BiquadState,
    mid_bell_coeffs: BiquadCoeffs,
    mid_bell_state: BiquadState,
    high_shelf_coeffs: BiquadCoeffs,
    high_shelf_state: BiquadState,

    limiter_env: f32,
    dry_scratch: Vec<f32>,
}

impl AmDspEngine {
    pub fn new(sample_rate: f64) -> Self {
        let clamped_sr = sample_rate.max(8_000.0);
        let mut engine = Self {
            sample_rate: clamped_sr,
            target_enabled: false,
            target_crossfeed: 0.0,
            target_room: 0.0,
            target_bass_db: 0.0,
            target_mid_db: 0.0,
            target_treble_db: 0.0,
            target_limiter_enabled: true,
            cur_crossfeed: 0.0,
            cur_room: 0.0,
            cur_bass_db: 0.0,
            cur_mid_db: 0.0,
            cur_treble_db: 0.0,
            cur_active_blend: 0.0,
            initialized_params: false,
            last_bass_db: -999.0,
            last_mid_db: -999.0,
            last_treble_db: -999.0,
            last_sample_rate: -1.0,
            itd_delay_l: vec![0.0; ITD_BUFFER_SIZE],
            itd_delay_r: vec![0.0; ITD_BUFFER_SIZE],
            itd_write_idx: 0,
            room_delay_l: vec![0.0; ROOM_BUFFER_SIZE],
            room_delay_r: vec![0.0; ROOM_BUFFER_SIZE],
            room_write_idx: 0,
            shadow_lp_l: 0.0,
            shadow_lp_r: 0.0,
            bass_comp_lp_l: 0.0,
            bass_comp_lp_r: 0.0,
            room_damp_l: 0.0,
            room_damp_r: 0.0,
            low_shelf_coeffs: BiquadCoeffs::default(),
            low_shelf_state: BiquadState::default(),
            mid_bell_coeffs: BiquadCoeffs::default(),
            mid_bell_state: BiquadState::default(),
            high_shelf_coeffs: BiquadCoeffs::default(),
            high_shelf_state: BiquadState::default(),
            limiter_env: 0.0,
            dry_scratch: vec![0.0; MAX_SCRATCH_SAMPLES],
        };
        engine.recompute_all_biquads_if_needed(true, clamped_sr);
        engine
    }

    pub fn reset(&mut self) {
        self.itd_delay_l.fill(0.0);
        self.itd_delay_r.fill(0.0);
        self.room_delay_l.fill(0.0);
        self.room_delay_r.fill(0.0);
        self.itd_write_idx = 0;
        self.room_write_idx = 0;
        self.shadow_lp_l = 0.0;
        self.shadow_lp_r = 0.0;
        self.bass_comp_lp_l = 0.0;
        self.bass_comp_lp_r = 0.0;
        self.room_damp_l = 0.0;
        self.room_damp_r = 0.0;
        self.low_shelf_state.reset();
        self.mid_bell_state.reset();
        self.high_shelf_state.reset();
        self.limiter_env = 0.0;
    }

    #[allow(clippy::too_many_arguments)]
    pub fn configure(
        &mut self,
        sample_rate: f64,
        enabled: bool,
        crossfeed: f32,
        room: f32,
        bass_db: f32,
        mid_db: f32,
        treble_db: f32,
        limiter_enabled: bool,
    ) {
        self.sample_rate = sample_rate.max(8_000.0);
        self.target_enabled = enabled;
        self.target_crossfeed = crossfeed.clamp(0.0, 1.0);
        self.target_room = room.clamp(0.0, 1.0);
        self.target_bass_db = bass_db.clamp(-12.0, 12.0);
        self.target_mid_db = mid_db.clamp(-12.0, 12.0);
        self.target_treble_db = treble_db.clamp(-12.0, 12.0);
        self.target_limiter_enabled = limiter_enabled;

        if !self.initialized_params {
            self.cur_crossfeed = self.target_crossfeed;
            self.cur_room = self.target_room;
            self.cur_bass_db = self.target_bass_db;
            self.cur_mid_db = self.target_mid_db;
            self.cur_treble_db = self.target_treble_db;
            self.cur_active_blend = if enabled { 1.0 } else { 0.0 };
            self.initialized_params = true;
            self.recompute_all_biquads_if_needed(true, self.sample_rate);
        }
    }

    pub fn process_stereo_interleaved(&mut self, samples: &mut [f32], frame_count: usize) {
        let total_samples = frame_count.saturating_mul(2);
        if frame_count == 0 || samples.len() < total_samples {
            return;
        }

        let rate = self.sample_rate;
        let sr = rate as f32;
        if (rate - self.last_sample_rate).abs() > 1.0 {
            self.recompute_all_biquads_if_needed(true, rate);
        }

        let target_blend = if self.target_enabled { 1.0 } else { 0.0 };
        if target_blend == 0.0 && self.cur_active_blend < 0.0001 {
            self.cur_active_blend = 0.0;
            for s in &mut samples[..total_samples] {
                if !s.is_finite() {
                    *s = 0.0;
                }
            }
            return;
        }

        let use_dry_blend = (self.cur_active_blend < 0.9999 || target_blend < 0.9999)
            && total_samples <= MAX_SCRATCH_SAMPLES;
        if use_dry_blend {
            self.dry_scratch[..total_samples].copy_from_slice(&samples[..total_samples]);
        }

        let itd_samples = ((0.00029 * sr).round() as usize).clamp(1, ITD_BUFFER_SIZE - 2);
        let shadow_alpha = 1.0 - (-2.0 * PI * 1400.0 / sr).exp();
        let bass_comp_alpha = 1.0 - (-2.0 * PI * 300.0 / sr).exp();
        let room_damp_alpha = 1.0 - (-2.0 * PI * 3500.0 / sr).exp();

        let tap1 = ((0.0073 * sr).round() as usize).clamp(1, ROOM_BUFFER_SIZE - 2);
        let tap2 = ((0.0119 * sr).round() as usize).clamp(1, ROOM_BUFFER_SIZE - 2);
        let tap3 = ((0.0171 * sr).round() as usize).clamp(1, ROOM_BUFFER_SIZE - 2);
        let tap4 = ((0.0234 * sr).round() as usize).clamp(1, ROOM_BUFFER_SIZE - 2);

        let attack_coeff = (-1.0 / (0.0005 * sr)).exp();
        let release_coeff = (-1.0 / (0.080 * sr)).exp();
        let limiter_threshold = 0.89125f32;

        let smooth_coeff = 0.995f32;
        let smooth_one_minus = 1.0 - smooth_coeff;

        for frame in 0..frame_count {
            if (frame & 63) == 0 {
                self.cur_bass_db += (self.target_bass_db - self.cur_bass_db) * 0.25;
                self.cur_mid_db += (self.target_mid_db - self.cur_mid_db) * 0.25;
                self.cur_treble_db += (self.target_treble_db - self.cur_treble_db) * 0.25;
                self.recompute_all_biquads_if_needed(false, rate);
            }

            self.cur_crossfeed =
                self.cur_crossfeed * smooth_coeff + self.target_crossfeed * smooth_one_minus;
            self.cur_room = self.cur_room * smooth_coeff + self.target_room * smooth_one_minus;
            self.cur_active_blend =
                self.cur_active_blend * smooth_coeff + target_blend * smooth_one_minus;

            let idx = frame * 2;
            let mut in_l = if samples[idx].is_finite() {
                samples[idx]
            } else {
                0.0
            };
            let mut in_r = if samples[idx + 1].is_finite() {
                samples[idx + 1]
            } else {
                0.0
            };

            self.low_shelf_state
                .process_stereo(&mut in_l, &mut in_r, &self.low_shelf_coeffs);
            self.mid_bell_state
                .process_stereo(&mut in_l, &mut in_r, &self.mid_bell_coeffs);
            self.high_shelf_state
                .process_stereo(&mut in_l, &mut in_r, &self.high_shelf_coeffs);

            self.itd_delay_l[self.itd_write_idx] = in_l;
            self.itd_delay_r[self.itd_write_idx] = in_r;

            let delayed_idx = self.itd_write_idx.wrapping_sub(itd_samples) & ITD_BUFFER_MASK;
            let raw_cross_from_r = self.itd_delay_r[delayed_idx];
            let raw_cross_from_l = self.itd_delay_l[delayed_idx];
            self.itd_write_idx = (self.itd_write_idx + 1) & ITD_BUFFER_MASK;

            self.shadow_lp_l += shadow_alpha * (raw_cross_from_r - self.shadow_lp_l);
            self.shadow_lp_r += shadow_alpha * (raw_cross_from_l - self.shadow_lp_r);
            let shadowed_cross_to_l = self.shadow_lp_l * 0.72 + raw_cross_from_r * 0.14;
            let shadowed_cross_to_r = self.shadow_lp_r * 0.72 + raw_cross_from_l * 0.14;

            self.bass_comp_lp_l += bass_comp_alpha * (in_l - self.bass_comp_lp_l);
            self.bass_comp_lp_r += bass_comp_alpha * (in_r - self.bass_comp_lp_r);

            let cf_gain = self.cur_crossfeed * 0.34;
            let direct_atten = 1.0 - self.cur_crossfeed * 0.16;
            let bass_boost = self.cur_crossfeed * 0.15;

            let stage1_l =
                in_l * direct_atten + self.bass_comp_lp_l * bass_boost + shadowed_cross_to_l * cf_gain;
            let stage1_r =
                in_r * direct_atten + self.bass_comp_lp_r * bass_boost + shadowed_cross_to_r * cf_gain;

            self.room_delay_l[self.room_write_idx] = stage1_l;
            self.room_delay_r[self.room_write_idx] = stage1_r;

            let t1_l = self.room_delay_l[self.room_write_idx.wrapping_sub(tap1) & ROOM_BUFFER_MASK];
            let t1_r = self.room_delay_r[self.room_write_idx.wrapping_sub(tap1) & ROOM_BUFFER_MASK];
            let t2_l = self.room_delay_l[self.room_write_idx.wrapping_sub(tap2) & ROOM_BUFFER_MASK];
            let t2_r = self.room_delay_r[self.room_write_idx.wrapping_sub(tap2) & ROOM_BUFFER_MASK];
            let t3_l = self.room_delay_l[self.room_write_idx.wrapping_sub(tap3) & ROOM_BUFFER_MASK];
            let t3_r = self.room_delay_r[self.room_write_idx.wrapping_sub(tap3) & ROOM_BUFFER_MASK];
            let t4_l = self.room_delay_l[self.room_write_idx.wrapping_sub(tap4) & ROOM_BUFFER_MASK];
            let t4_r = self.room_delay_r[self.room_write_idx.wrapping_sub(tap4) & ROOM_BUFFER_MASK];
            self.room_write_idx = (self.room_write_idx + 1) & ROOM_BUFFER_MASK;

            let raw_refl_l = t1_l * 0.38 + t2_r * 0.28 + t3_l * 0.20 + t4_r * 0.14;
            let raw_refl_r = t1_r * 0.38 + t2_l * 0.28 + t3_r * 0.20 + t4_l * 0.14;

            self.room_damp_l += room_damp_alpha * (raw_refl_l - self.room_damp_l);
            self.room_damp_r += room_damp_alpha * (raw_refl_r - self.room_damp_r);

            let room_gain = self.cur_room * 0.24;
            let mut out_l = stage1_l + self.room_damp_l * room_gain;
            let mut out_r = stage1_r + self.room_damp_r * room_gain;

            if use_dry_blend {
                let d_l = self.dry_scratch[idx];
                let d_r = self.dry_scratch[idx + 1];
                out_l = d_l + (out_l - d_l) * self.cur_active_blend;
                out_r = d_r + (out_r - d_r) * self.cur_active_blend;
            }

            if self.target_limiter_enabled {
                let peak = out_l.abs().max(out_r.abs());
                if peak > self.limiter_env {
                    self.limiter_env =
                        attack_coeff * self.limiter_env + (1.0 - attack_coeff) * peak;
                } else {
                    self.limiter_env =
                        release_coeff * self.limiter_env + (1.0 - release_coeff) * peak;
                }

                if self.limiter_env > limiter_threshold {
                    let gain_reduction = limiter_threshold / self.limiter_env;
                    out_l *= gain_reduction;
                    out_r *= gain_reduction;
                }

                out_l = (out_l * 1.03).tanh() * 0.966;
                out_r = (out_r * 1.03).tanh() * 0.966;
            }

            samples[idx] = if out_l.is_finite() {
                out_l.clamp(-1.0, 1.0)
            } else {
                0.0
            };
            samples[idx + 1] = if out_r.is_finite() {
                out_r.clamp(-1.0, 1.0)
            } else {
                0.0
            };
        }
    }

    fn recompute_all_biquads_if_needed(&mut self, force: bool, rate: f64) {
        let rate_changed = force || (rate - self.last_sample_rate).abs() > 1.0;
        if rate_changed || (self.cur_bass_db - self.last_bass_db).abs() > 0.02 {
            self.low_shelf_coeffs = Self::make_low_shelf(110.0, 0.707, self.cur_bass_db, rate);
            self.last_bass_db = self.cur_bass_db;
        }
        if rate_changed || (self.cur_mid_db - self.last_mid_db).abs() > 0.02 {
            self.mid_bell_coeffs = Self::make_peaking_eq(2500.0, 0.85, self.cur_mid_db, rate);
            self.last_mid_db = self.cur_mid_db;
        }
        if rate_changed || (self.cur_treble_db - self.last_treble_db).abs() > 0.02 {
            self.high_shelf_coeffs =
                Self::make_high_shelf(7000.0, 0.707, self.cur_treble_db, rate);
            self.last_treble_db = self.cur_treble_db;
        }
        self.last_sample_rate = rate;
    }

    fn make_low_shelf(freq: f32, q: f32, gain_db: f32, sample_rate: f64) -> BiquadCoeffs {
        if gain_db.abs() < 0.01 {
            return BiquadCoeffs::default();
        }
        let clamped_db = gain_db.clamp(-12.0, 12.0);
        let a = 10.0f32.powf(clamped_db / 40.0);
        let w0 = 2.0 * PI * freq / (sample_rate as f32);
        let cos_w0 = w0.cos();
        let sin_w0 = w0.sin();
        let alpha = sin_w0 / (2.0 * q);
        let two_sqrt_a_alpha = 2.0 * a.sqrt() * alpha;

        let a0 = (a + 1.0) + (a - 1.0) * cos_w0 + two_sqrt_a_alpha;
        BiquadCoeffs {
            b0: (a * ((a + 1.0) - (a - 1.0) * cos_w0 + two_sqrt_a_alpha)) / a0,
            b1: (2.0 * a * ((a - 1.0) - (a + 1.0) * cos_w0)) / a0,
            b2: (a * ((a + 1.0) - (a - 1.0) * cos_w0 - two_sqrt_a_alpha)) / a0,
            a1: (-2.0 * ((a - 1.0) + (a + 1.0) * cos_w0)) / a0,
            a2: ((a + 1.0) + (a - 1.0) * cos_w0 - two_sqrt_a_alpha) / a0,
        }
    }

    fn make_high_shelf(freq: f32, q: f32, gain_db: f32, sample_rate: f64) -> BiquadCoeffs {
        if gain_db.abs() < 0.01 {
            return BiquadCoeffs::default();
        }
        let clamped_db = gain_db.clamp(-12.0, 12.0);
        let a = 10.0f32.powf(clamped_db / 40.0);
        let w0 = 2.0 * PI * freq / (sample_rate as f32);
        let cos_w0 = w0.cos();
        let sin_w0 = w0.sin();
        let alpha = sin_w0 / (2.0 * q);
        let two_sqrt_a_alpha = 2.0 * a.sqrt() * alpha;

        let a0 = (a + 1.0) - (a - 1.0) * cos_w0 + two_sqrt_a_alpha;
        BiquadCoeffs {
            b0: (a * ((a + 1.0) + (a - 1.0) * cos_w0 + two_sqrt_a_alpha)) / a0,
            b1: (-2.0 * a * ((a - 1.0) + (a + 1.0) * cos_w0)) / a0,
            b2: (a * ((a + 1.0) + (a - 1.0) * cos_w0 - two_sqrt_a_alpha)) / a0,
            a1: (2.0 * ((a - 1.0) - (a + 1.0) * cos_w0)) / a0,
            a2: ((a + 1.0) - (a - 1.0) * cos_w0 - two_sqrt_a_alpha) / a0,
        }
    }

    fn make_peaking_eq(freq: f32, q: f32, gain_db: f32, sample_rate: f64) -> BiquadCoeffs {
        if gain_db.abs() < 0.01 {
            return BiquadCoeffs::default();
        }
        let clamped_db = gain_db.clamp(-12.0, 12.0);
        let a = 10.0f32.powf(clamped_db / 40.0);
        let w0 = 2.0 * PI * freq / (sample_rate as f32);
        let cos_w0 = w0.cos();
        let sin_w0 = w0.sin();
        let alpha = sin_w0 / (2.0 * q);

        let a0 = 1.0 + alpha / a;
        BiquadCoeffs {
            b0: (1.0 + alpha * a) / a0,
            b1: (-2.0 * cos_w0) / a0,
            b2: (1.0 - alpha * a) / a0,
            a1: (-2.0 * cos_w0) / a0,
            a2: (1.0 - alpha / a) / a0,
        }
    }
}

#[no_mangle]
pub extern "C" fn am_dsp_create(sample_rate: f64) -> *mut AmDspEngine {
    Box::into_raw(Box::new(AmDspEngine::new(sample_rate)))
}

#[no_mangle]
pub unsafe extern "C" fn am_dsp_destroy(ptr: *mut AmDspEngine) {
    if !ptr.is_null() {
        drop(Box::from_raw(ptr));
    }
}

#[no_mangle]
pub unsafe extern "C" fn am_dsp_reset(ptr: *mut AmDspEngine) {
    if let Some(engine) = ptr.as_mut() {
        engine.reset();
    }
}

#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn am_dsp_configure(
    ptr: *mut AmDspEngine,
    sample_rate: f64,
    enabled: bool,
    crossfeed: f32,
    room: f32,
    bass_db: f32,
    mid_db: f32,
    treble_db: f32,
    limiter_enabled: bool,
) {
    if let Some(engine) = ptr.as_mut() {
        engine.configure(
            sample_rate,
            enabled,
            crossfeed,
            room,
            bass_db,
            mid_db,
            treble_db,
            limiter_enabled,
        );
    }
}

#[no_mangle]
pub unsafe extern "C" fn am_dsp_process_stereo_interleaved(
    ptr: *mut AmDspEngine,
    samples: *mut f32,
    frame_count: usize,
) {
    if samples.is_null() || frame_count == 0 {
        return;
    }
    if let Some(engine) = ptr.as_mut() {
        let slice = std::slice::from_raw_parts_mut(samples, frame_count * 2);
        engine.process_stereo_interleaved(slice, frame_count);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_crossfeed_limiter_and_nan_sanitization() {
        unsafe {
            let dsp = am_dsp_create(48_000.0);
            am_dsp_configure(dsp, 48_000.0, true, 0.65, 0.30, 3.0, 0.0, 2.0, true);

            let frame_count = 512usize;
            let mut buf = vec![0.0f32; frame_count * 2];
            buf[0] = 1.0;
            am_dsp_process_stereo_interleaved(dsp, buf.as_mut_ptr(), frame_count);

            let mut right_energy = 0.0f32;
            for f in 1..frame_count {
                let l = buf[f * 2];
                let r = buf[f * 2 + 1];
                assert!(l.is_finite() && r.is_finite());
                right_energy += r * r;
            }
            assert!(right_energy > 1e-4, "crossfeed energy too small: {}", right_energy);

            let mut overload = vec![4.0f32; 256 * 2];
            overload[4] = f32::NAN;
            overload[5] = f32::INFINITY;
            am_dsp_process_stereo_interleaved(dsp, overload.as_mut_ptr(), 256);
            for s in overload {
                assert!(s.is_finite());
                assert!(s.abs() <= 1.0, "limiter overflow: {}", s);
            }

            am_dsp_destroy(dsp);
        }
    }
}
