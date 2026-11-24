use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::{Seek, SeekFrom, Write};
use std::net::UdpSocket;
use std::os::raw::c_char;
use std::path::PathBuf;
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::dsp::AmDspEngine;
use crate::osc::{encode_float_message, slugify_str};
use crate::ring_buffer::AmRingBuffer;
use crate::wav::am_wav_write_header;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BackendKind {
    MacOSCoreAudio,
    WindowsWasapi,
    LinuxPipeWire,
}

impl BackendKind {
    pub const fn as_c_str(self) -> &'static [u8] {
        match self {
            BackendKind::MacOSCoreAudio => b"macos-coreaudio\0",
            BackendKind::WindowsWasapi => b"windows-wasapi\0",
            BackendKind::LinuxPipeWire => b"linux-pipewire\0",
        }
    }

    pub const fn name(self) -> &'static str {
        match self {
            BackendKind::MacOSCoreAudio => "macos-coreaudio",
            BackendKind::WindowsWasapi => "windows-wasapi",
            BackendKind::LinuxPipeWire => "linux-pipewire",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct PlatformAudioDevice {
    pub id: String,
    pub name: String,
    pub transport: String,
    pub is_input: bool,
    pub is_output: bool,
    pub is_virtual: bool,
    pub is_default_input: bool,
    pub is_default_output: bool,
    pub volume: f32,
    pub sample_rate: f64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct AppAudioStream {
    pub id: String,
    pub app_name: String,
    pub binary_name: String,
    pub pid: u32,
    pub volume: f32,
    pub is_muted: bool,
    pub target_device_id: Option<String>,
    pub is_producing_audio: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct LoopbackMixChannel {
    pub app_id: String,
    pub app_name: String,
    pub included: bool,
    pub gain: f32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DspPresetSpeaker {
    Off,
    Nearfield,
    Studio,
    Stage,
}

impl DspPresetSpeaker {
    pub const ALL: [DspPresetSpeaker; 4] = [
        DspPresetSpeaker::Off,
        DspPresetSpeaker::Nearfield,
        DspPresetSpeaker::Studio,
        DspPresetSpeaker::Stage,
    ];

    pub const fn title(self) -> &'static str {
        match self {
            DspPresetSpeaker::Off => "Off",
            DspPresetSpeaker::Nearfield => "Nearfield",
            DspPresetSpeaker::Studio => "Studio",
            DspPresetSpeaker::Stage => "Stage",
        }
    }

    pub fn from_cli(s: &str) -> Option<Self> {
        match s.to_lowercase().as_str() {
            "off" | "direct" | "0" => Some(Self::Off),
            "nearfield" | "near" | "1" => Some(Self::Nearfield),
            "studio" | "2" => Some(Self::Studio),
            "stage" | "hall" | "3" => Some(Self::Stage),
            _ => None,
        }
    }

    pub const fn default_crossfeed(self) -> f32 {
        match self {
            DspPresetSpeaker::Off => 0.0,
            DspPresetSpeaker::Nearfield => 0.55,
            DspPresetSpeaker::Studio => 0.60,
            DspPresetSpeaker::Stage => 0.72,
        }
    }

    pub const fn default_room(self) -> f32 {
        match self {
            DspPresetSpeaker::Off => 0.0,
            DspPresetSpeaker::Nearfield => 0.14,
            DspPresetSpeaker::Studio => 0.30,
            DspPresetSpeaker::Stage => 0.55,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DspPresetTone {
    Off,
    Warm,
    Clear,
    BassBoost,
    VShape,
}

impl DspPresetTone {
    pub const ALL: [DspPresetTone; 5] = [
        DspPresetTone::Off,
        DspPresetTone::Warm,
        DspPresetTone::Clear,
        DspPresetTone::BassBoost,
        DspPresetTone::VShape,
    ];

    pub const fn title(self) -> &'static str {
        match self {
            DspPresetTone::Off => "Off",
            DspPresetTone::Warm => "Warm",
            DspPresetTone::Clear => "Clear",
            DspPresetTone::BassBoost => "Bass+",
            DspPresetTone::VShape => "V-Shape",
        }
    }

    pub fn from_cli(s: &str) -> Option<Self> {
        match s.to_lowercase().as_str() {
            "off" | "flat" | "0" => Some(Self::Off),
            "warm" => Some(Self::Warm),
            "clear" | "vocal" => Some(Self::Clear),
            "bass" | "bass+" | "bassboost" => Some(Self::BassBoost),
            "vshape" | "v-shape" | "dance" => Some(Self::VShape),
            _ => None,
        }
    }

    pub const fn default_eq(self) -> (f32, f32, f32) {
        match self {
            DspPresetTone::Off => (0.0, 0.0, 0.0),
            DspPresetTone::Warm => (2.5, 0.0, -1.5),
            DspPresetTone::Clear => (-0.5, 2.5, 2.0),
            DspPresetTone::BassBoost => (4.5, 0.0, 0.5),
            DspPresetTone::VShape => (3.5, -1.0, 3.0),
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct DspConfigState {
    pub speaker_mode: DspPresetSpeaker,
    pub tone_mode: DspPresetTone,
    pub crossfeed: f32,
    pub room: f32,
    pub bass_db: f32,
    pub mid_db: f32,
    pub treble_db: f32,
    pub limiter_enabled: bool,
}

impl Default for DspConfigState {
    fn default() -> Self {
        Self {
            speaker_mode: DspPresetSpeaker::Off,
            tone_mode: DspPresetTone::Off,
            crossfeed: 0.0,
            room: 0.0,
            bass_db: 0.0,
            mid_db: 0.0,
            treble_db: 0.0,
            limiter_enabled: true,
        }
    }
}

impl DspConfigState {
    pub fn is_enabled(&self) -> bool {
        self.speaker_mode != DspPresetSpeaker::Off
            || self.tone_mode != DspPresetTone::Off
            || self.crossfeed > 0.01
            || self.room > 0.01
            || self.bass_db.abs() > 0.05
            || self.mid_db.abs() > 0.05
            || self.treble_db.abs() > 0.05
    }

    pub fn apply_speaker_mode(&mut self, mode: DspPresetSpeaker) {
        self.speaker_mode = mode;
        self.crossfeed = mode.default_crossfeed();
        self.room = mode.default_room();
    }

    pub fn apply_tone_mode(&mut self, tone: DspPresetTone) {
        self.tone_mode = tone;
        let (b, m, t) = tone.default_eq();
        self.bass_db = b;
        self.mid_db = m;
        self.treble_db = t;
    }

    pub fn summary_title(&self) -> String {
        match (self.speaker_mode, self.tone_mode) {
            (DspPresetSpeaker::Off, DspPresetTone::Off) => {
                if self.is_enabled() {
                    "Custom".to_string()
                } else {
                    "Direct".to_string()
                }
            }
            (sp, DspPresetTone::Off) => sp.title().to_string(),
            (DspPresetSpeaker::Off, eq) => eq.title().to_string(),
            (sp, eq) => format!("{} + {}", sp.title(), eq.title()),
        }
    }
}

/// Cross-platform OS audio driver abstraction so macOS (CoreAudio), Windows (WASAPI),
/// and Linux (PipeWire/PulseAudio) share the exact same Rust DSP, ring buffer, and OSC/WAV engine.
pub trait AudioPlatformBackend {
    fn backend_kind(&self) -> BackendKind;
    fn supports_process_tap(&self) -> bool;
    fn default_sample_rate(&self) -> f64 {
        48_000.0
    }
}

pub struct NativePlatformBackend;

impl AudioPlatformBackend for NativePlatformBackend {
    fn backend_kind(&self) -> BackendKind {
        #[cfg(target_os = "macos")]
        {
            BackendKind::MacOSCoreAudio
        }
        #[cfg(target_os = "windows")]
        {
            BackendKind::WindowsWasapi
        }
        #[cfg(not(any(target_os = "macos", target_os = "windows")))]
        {
            BackendKind::LinuxPipeWire
        }
    }

    fn supports_process_tap(&self) -> bool {
        #[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
        {
            true
        }
        #[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
        {
            false
        }
    }
}

/// Stateful cross-platform controller managing OS audio I/O devices, Bluetooth mic guard,
/// non-destructive per-app output-stage mixing, independent loopback mixing, WAV recording,
/// and external VST3/AU OSC chain control.
pub struct SystemAudioController {
    pub backend_kind: BackendKind,
    pub using_live_os_driver: bool,
    pub devices: Vec<PlatformAudioDevice>,
    pub apps: Vec<AppAudioStream>,
    pub share_audio_enabled: bool,
    pub secondary_output_id: Option<String>,
    pub secondary_volume: f32,
    pub bt_mic_guard_enabled: bool,
    pub preferred_input_id: Option<String>,
    pub dsp_state: DspConfigState,
    pub dsp_engine: AmDspEngine,
    pub capture_ring: AmRingBuffer,

    pub loopback_active: bool,
    pub loopback_target_bus: String,
    pub loopback_include_mic: bool,
    pub loopback_mic_gain: f32,
    pub loopback_sys_gain: f32,
    pub loopback_channels: HashMap<String, LoopbackMixChannel>,

    pub is_recording: bool,
    pub last_recording_path: Option<PathBuf>,
    recording_file: Option<File>,
    recorded_bytes: u32,

    pub element_host_enabled: bool,
    pub element_osc_host: String,
    pub element_osc_port: u16,
    pub element_slots: Vec<(String, bool)>,

    #[cfg(target_os = "linux")]
    linux_module_ids: Vec<String>,
}

impl Default for SystemAudioController {
    fn default() -> Self {
        Self::new()
    }
}

impl SystemAudioController {
    pub fn new() -> Self {
        let kind = NativePlatformBackend.backend_kind();
        let mut ctrl = Self {
            backend_kind: kind,
            using_live_os_driver: false,
            devices: Vec::new(),
            apps: Vec::new(),
            share_audio_enabled: false,
            secondary_output_id: None,
            secondary_volume: 1.0,
            bt_mic_guard_enabled: true,
            preferred_input_id: None,
            dsp_state: DspConfigState::default(),
            dsp_engine: AmDspEngine::new(48_000.0),
            capture_ring: AmRingBuffer::new(32_768),
            loopback_active: false,
            loopback_target_bus: "AudioMatrix Virtual Mic (Built-in)".to_string(),
            loopback_include_mic: false,
            loopback_mic_gain: 1.8,
            loopback_sys_gain: 1.0,
            loopback_channels: HashMap::new(),
            is_recording: false,
            last_recording_path: None,
            recording_file: None,
            recorded_bytes: 0,
            element_host_enabled: false,
            element_osc_host: "127.0.0.1".to_string(),
            element_osc_port: 9000,
            element_slots: vec![("SoundID Reference".to_string(), false)],
            #[cfg(target_os = "linux")]
            linux_module_ids: Vec::new(),
        };
        ctrl.refresh_all();
        ctrl
    }

    pub fn refresh_all(&mut self) {
        self.refresh_devices();
        self.refresh_app_streams();
        if self.preferred_input_id.is_none() {
            self.preferred_input_id = self
                .devices
                .iter()
                .find(|d| d.is_input && !d.is_virtual && d.is_default_input)
                .or_else(|| self.devices.iter().find(|d| d.is_input && !d.is_virtual))
                .map(|d| d.id.clone());
        }
        if self.secondary_output_id.is_none() {
            self.secondary_output_id = self
                .devices
                .iter()
                .find(|d| d.is_output && !d.is_virtual && !d.is_default_output)
                .map(|d| d.id.clone());
        }
        if self.bt_mic_guard_enabled {
            self.enforce_bt_mic_guard();
        }
    }

    pub fn default_output(&self) -> Option<&PlatformAudioDevice> {
        self.devices
            .iter()
            .find(|d| d.is_output && d.is_default_output)
    }

    pub fn default_input(&self) -> Option<&PlatformAudioDevice> {
        self.devices
            .iter()
            .find(|d| d.is_input && d.is_default_input)
    }

    pub fn refresh_devices(&mut self) {
        let live = query_os_devices(self.backend_kind);
        if !live.is_empty() {
            self.using_live_os_driver = true;
            self.devices = live;
            return;
        }

        // Preserve any modified in-memory fallback devices if already seeded (e.g. headless CI)
        self.using_live_os_driver = false;
        if self.devices.is_empty() {
            self.devices = seed_fallback_devices(self.backend_kind);
        }
    }

    pub fn refresh_app_streams(&mut self) {
        let mut live = query_os_app_streams(self.backend_kind);
        if live.is_empty() {
            if self.apps.is_empty() {
                live = seed_fallback_apps();
            } else {
                live = self.apps.clone();
            }
        }
        for app in &live {
            self.loopback_channels
                .entry(app.id.clone())
                .or_insert_with(|| LoopbackMixChannel {
                    app_id: app.id.clone(),
                    app_name: app.app_name.clone(),
                    included: true,
                    gain: 1.0,
                });
        }
        self.apps = live;
    }

    pub fn select_output_device(&mut self, id: &str) {
        for dev in &mut self.devices {
            if dev.is_output {
                dev.is_default_output = dev.id == id;
            }
        }
        if self.using_live_os_driver {
            os_set_default_output(self.backend_kind, id);
        }
    }

    pub fn select_input_device(&mut self, id: &str) {
        for dev in &mut self.devices {
            if dev.is_input {
                dev.is_default_input = dev.id == id;
            }
        }
        self.preferred_input_id = Some(id.to_string());
        if self.using_live_os_driver {
            os_set_default_input(self.backend_kind, id);
        }
    }

    pub fn set_device_volume(&mut self, id: &str, volume: f32) {
        let clamped = volume.clamp(0.0, 1.0);
        for dev in &mut self.devices {
            if dev.id == id {
                dev.volume = clamped;
            }
        }
        if self.using_live_os_driver {
            os_set_device_volume(self.backend_kind, id, clamped);
        }
    }

    pub fn enforce_bt_mic_guard(&mut self) -> bool {
        if !self.bt_mic_guard_enabled {
            return false;
        }
        let pref = match self.preferred_input_id.clone() {
            Some(p) => p,
            None => return false,
        };
        let is_bt_hijacked = self.default_input().is_some_and(|d| {
            let low = format!("{} {}", d.id, d.name).to_lowercase();
            (low.contains("bluez")
                || low.contains("hands-free")
                || low.contains("hfp")
                || low.contains("headset")
                || low.contains("airpods"))
                && d.id != pref
        });
        if is_bt_hijacked {
            self.select_input_device(&pref);
            return true;
        }
        false
    }

    pub fn set_share_audio(&mut self, enabled: bool, secondary_id: Option<&str>) {
        self.share_audio_enabled = enabled;
        if let Some(id) = secondary_id {
            self.secondary_output_id = Some(id.to_string());
        }
        #[cfg(target_os = "linux")]
        if self.using_live_os_driver {
            let primary = self.default_output().map(|d| d.id.clone());
            let secondary = self.secondary_output_id.clone();
            linux_toggle_share_audio(
                enabled,
                primary.as_deref(),
                secondary.as_deref(),
                &mut self.linux_module_ids,
            );
        }
        #[cfg(target_os = "macos")]
        if self.using_live_os_driver {
            if enabled {
                if let (Some(a), Some(b)) = (
                    self.default_output().map(|d| d.name.clone()),
                    self.secondary_output_id.clone(),
                ) {
                    let _ = Command::new("audiomatrix")
                        .args(["listen-together", "on", &a, &b])
                        .status();
                }
            } else {
                let _ = Command::new("audiomatrix")
                    .args(["listen-together", "off"])
                    .status();
            }
        }
    }

    pub fn update_dsp_config(&mut self, next: DspConfigState) {
        let sr = self
            .default_output()
            .map(|d| d.sample_rate)
            .unwrap_or(48_000.0);
        self.dsp_engine.configure(
            sr,
            next.is_enabled(),
            next.crossfeed,
            next.room,
            next.bass_db,
            next.mid_db,
            next.treble_db,
            next.limiter_enabled,
        );
        self.dsp_state = next;
    }

    pub fn set_app_volume(&mut self, app_id: &str, volume: f32) {
        let clamped = volume.clamp(0.0, 2.0);
        for app in &mut self.apps {
            if app.id == app_id {
                app.volume = clamped;
            }
        }
        if self.using_live_os_driver {
            os_set_app_volume(self.backend_kind, app_id, clamped);
        }
    }

    pub fn toggle_app_mute(&mut self, app_id: &str) {
        let mut next_muted = false;
        for app in &mut self.apps {
            if app.id == app_id {
                app.is_muted = !app.is_muted;
                next_muted = app.is_muted;
            }
        }
        if self.using_live_os_driver {
            os_set_app_mute(self.backend_kind, app_id, next_muted);
        }
    }

    pub fn route_app(&mut self, app_id: &str, target_device_id: Option<&str>) {
        for app in &mut self.apps {
            if app.id == app_id {
                app.target_device_id = target_device_id.map(str::to_string);
            }
        }
        if self.using_live_os_driver {
            if let Some(dev_id) = target_device_id {
                os_route_app(self.backend_kind, app_id, dev_id);
            }
        }
    }

    pub fn has_custom_app_changes(&self) -> bool {
        self.apps
            .iter()
            .any(|a| (a.volume - 1.0).abs() > 0.02 || a.is_muted || a.target_device_id.is_some())
    }

    pub fn reset_all_app_streams(&mut self) {
        let default_sink = self.default_output().map(|d| d.id.clone());
        let ids: Vec<String> = self.apps.iter().map(|a| a.id.clone()).collect();
        for app in &mut self.apps {
            app.volume = 1.0;
            app.is_muted = false;
            app.target_device_id = None;
        }
        if self.using_live_os_driver {
            for id in ids {
                os_set_app_volume(self.backend_kind, &id, 1.0);
                os_set_app_mute(self.backend_kind, &id, false);
                if let Some(ref sink) = default_sink {
                    os_route_app(self.backend_kind, &id, sink);
                }
            }
        }
    }

    pub fn set_loopback_active(&mut self, enabled: bool) {
        self.loopback_active = enabled;
        #[cfg(target_os = "linux")]
        if self.using_live_os_driver {
            linux_toggle_loopback(enabled, self.loopback_include_mic, &mut self.linux_module_ids);
        }
    }

    pub fn reset_loopback_mix(&mut self) {
        self.loopback_include_mic = false;
        self.loopback_mic_gain = 1.8;
        self.loopback_sys_gain = 1.0;
        for ch in self.loopback_channels.values_mut() {
            ch.included = true;
            ch.gain = 1.0;
        }
    }

    pub fn has_custom_loopback_mix(&self) -> bool {
        self.loopback_include_mic
            || (self.loopback_mic_gain - 1.8).abs() > 0.02
            || (self.loopback_sys_gain - 1.0).abs() > 0.02
            || self
                .loopback_channels
                .values()
                .any(|c| !c.included || (c.gain - 1.0).abs() > 0.02)
    }

    pub fn loopback_bus_options(&self) -> Vec<String> {
        let mut opts = vec!["AudioMatrix Virtual Mic (Built-in)".to_string()];
        for d in &self.devices {
            if d.is_virtual && !opts.contains(&d.name) {
                opts.push(d.name.clone());
            }
        }
        opts
    }

    pub fn start_recording(&mut self, custom_path: Option<PathBuf>) -> std::io::Result<PathBuf> {
        if self.is_recording {
            return Ok(self.last_recording_path.clone().unwrap());
        }
        let path = match custom_path {
            Some(p) => p,
            None => {
                let ts = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .map(|d| d.as_secs())
                    .unwrap_or(0);
                let mut dir = std::env::temp_dir();
                dir.push(format!("AudioMatrix_Loopback_{}.wav", ts));
                dir
            }
        };
        let mut file = OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .open(&path)?;
        let mut hdr = [0u8; 44];
        unsafe {
            am_wav_write_header(48_000, 2, 0, hdr.as_mut_ptr());
        }
        file.write_all(&hdr)?;
        self.capture_ring.reset();
        self.recording_file = Some(file);
        self.recorded_bytes = 0;
        self.last_recording_path = Some(path.clone());
        self.is_recording = true;
        Ok(path)
    }

    /// Feeds stereo interleaved PCM frames through the active Rust DSP engine + ring buffer
    /// into the open 48kHz IEEE Float32 WAV recorder.
    pub fn process_and_record_frames(&mut self, samples: &mut [f32]) -> std::io::Result<usize> {
        let frames = samples.len() / 2;
        if frames == 0 {
            return Ok(0);
        }
        self.dsp_engine.process_stereo_interleaved(samples, frames);
        unsafe {
            self.capture_ring.write(samples.as_ptr(), frames);
        }
        if !self.is_recording {
            return Ok(frames);
        }
        let mut drained = vec![0.0f32; frames * 2];
        let read_frames = unsafe { self.capture_ring.read(drained.as_mut_ptr(), frames) };
        if let Some(ref mut file) = self.recording_file {
            let mut bytes = Vec::with_capacity(read_frames * 8);
            for s in &drained[..read_frames * 2] {
                bytes.extend_from_slice(&(*s * self.loopback_sys_gain).to_le_bytes());
            }
            file.write_all(&bytes)?;
            self.recorded_bytes = self.recorded_bytes.saturating_add(bytes.len() as u32);
        }
        Ok(read_frames)
    }

    pub fn stop_recording(&mut self) -> Option<PathBuf> {
        if !self.is_recording {
            return None;
        }
        self.is_recording = false;
        if let Some(mut file) = self.recording_file.take() {
            let mut hdr = [0u8; 44];
            unsafe {
                am_wav_write_header(48_000, 2, self.recorded_bytes, hdr.as_mut_ptr());
            }
            let _ = file.seek(SeekFrom::Start(0));
            let _ = file.write_all(&hdr);
            let _ = file.flush();
        }
        self.last_recording_path.clone()
    }

    pub fn send_element_slot_bypass(&mut self, index: usize, bypass: bool) {
        if let Some(slot) = self.element_slots.get_mut(index) {
            slot.1 = bypass;
            let slug = slugify_str(&slot.0);
            let pkt = encode_float_message(
                &format!("/element/node/{}/bypass", slug),
                if bypass { 1.0 } else { 0.0 },
            );
            if let Ok(sock) = UdpSocket::bind("127.0.0.1:0") {
                let target = format!("{}:{}", self.element_osc_host, self.element_osc_port);
                let _ = sock.send_to(&pkt, target);
            }
        }
    }
}

fn seed_fallback_devices(kind: BackendKind) -> Vec<PlatformAudioDevice> {
    let (out_name, out_id, mic_name, mic_id) = match kind {
        BackendKind::WindowsWasapi => (
            "Speakers (Realtek High Definition Audio)",
            "wasapi-out-realtek",
            "Microphone (Shure MV7i)",
            "wasapi-in-mv7i",
        ),
        BackendKind::LinuxPipeWire => (
            "Built-in Audio Analog Stereo (PipeWire)",
            "alsa_output.pci-0000_00_1f.3.analog-stereo",
            "Shure MV7i Mono (PipeWire)",
            "alsa_input.usb-Shure_MV7i.mono-fallback",
        ),
        BackendKind::MacOSCoreAudio => (
            "MacBook Pro Speakers",
            "BuiltInSpeakerDevice",
            "MacBook Pro Microphone",
            "BuiltInMicrophoneDevice",
        ),
    };
    vec![
        PlatformAudioDevice {
            id: out_id.to_string(),
            name: out_name.to_string(),
            transport: "Built-in".to_string(),
            is_input: false,
            is_output: true,
            is_virtual: false,
            is_default_input: false,
            is_default_output: true,
            volume: 0.72,
            sample_rate: 48_000.0,
        },
        PlatformAudioDevice {
            id: "usb-dac-sk02".to_string(),
            name: "Fosi Audio SK02".to_string(),
            transport: "USB".to_string(),
            is_input: false,
            is_output: true,
            is_virtual: false,
            is_default_input: false,
            is_default_output: false,
            volume: 0.68,
            sample_rate: 48_000.0,
        },
        PlatformAudioDevice {
            id: mic_id.to_string(),
            name: mic_name.to_string(),
            transport: "USB".to_string(),
            is_input: true,
            is_output: false,
            is_virtual: false,
            is_default_input: true,
            is_default_output: false,
            volume: 1.0,
            sample_rate: 48_000.0,
        },
        PlatformAudioDevice {
            id: "audiomatrix-virtual-mic".to_string(),
            name: "AudioMatrix Virtual Mic".to_string(),
            transport: "Virtual".to_string(),
            is_input: true,
            is_output: false,
            is_virtual: true,
            is_default_input: false,
            is_default_output: false,
            volume: 1.0,
            sample_rate: 48_000.0,
        },
    ]
}

fn seed_fallback_apps() -> Vec<AppAudioStream> {
    vec![
        AppAudioStream {
            id: "app-chrome".to_string(),
            app_name: "Google Chrome".to_string(),
            binary_name: "chrome".to_string(),
            pid: 1024,
            volume: 1.0,
            is_muted: false,
            target_device_id: None,
            is_producing_audio: true,
        },
        AppAudioStream {
            id: "app-discord".to_string(),
            app_name: "Discord".to_string(),
            binary_name: "discord".to_string(),
            pid: 2048,
            volume: 1.0,
            is_muted: false,
            target_device_id: None,
            is_producing_audio: true,
        },
        AppAudioStream {
            id: "app-spotify".to_string(),
            app_name: "Spotify".to_string(),
            binary_name: "spotify".to_string(),
            pid: 3072,
            volume: 1.0,
            is_muted: false,
            target_device_id: None,
            is_producing_audio: false,
        },
    ]
}

fn query_os_devices(_kind: BackendKind) -> Vec<PlatformAudioDevice> {
    #[cfg(target_os = "linux")]
    {
        return linux_query_devices();
    }
    #[cfg(target_os = "windows")]
    {
        return windows_query_devices();
    }
    #[cfg(target_os = "macos")]
    {
        return Vec::new();
    }
    #[allow(unreachable_code)]
    Vec::new()
}

fn query_os_app_streams(_kind: BackendKind) -> Vec<AppAudioStream> {
    #[cfg(target_os = "linux")]
    {
        return linux_query_app_streams();
    }
    #[cfg(target_os = "windows")]
    {
        return windows_query_app_streams();
    }
    #[cfg(target_os = "macos")]
    {
        return Vec::new();
    }
    #[allow(unreachable_code)]
    Vec::new()
}

fn os_set_default_output(_kind: BackendKind, _id: &str) {
    #[cfg(target_os = "linux")]
    {
        let _ = Command::new("pactl").args(["set-default-sink", _id]).status();
    }
    #[cfg(target_os = "windows")]
    {
        windows_run_wasapi(&["set-default", _id]);
    }
    #[cfg(target_os = "macos")]
    {
        let _ = Command::new("audiomatrix").args(["output", _id]).status();
    }
}

fn os_set_default_input(_kind: BackendKind, _id: &str) {
    #[cfg(target_os = "linux")]
    {
        let _ = Command::new("pactl")
            .args(["set-default-source", _id])
            .status();
    }
    #[cfg(target_os = "windows")]
    {
        windows_run_wasapi(&["set-default", _id]);
    }
    #[cfg(target_os = "macos")]
    {
        let _ = Command::new("audiomatrix").args(["input", _id]).status();
    }
}

fn os_set_device_volume(_kind: BackendKind, _id: &str, _vol: f32) {
    #[cfg(target_os = "linux")]
    {
        let pct = format!("{}%", (_vol * 100.0).round() as i32);
        let _ = Command::new("pactl")
            .args(["set-sink-volume", _id, &pct])
            .status();
    }
    #[cfg(target_os = "windows")]
    {
        let pct = format!("{}", (_vol * 100.0).round().clamp(0.0, 100.0) as i32);
        windows_run_wasapi(&["set-volume", _id, &pct]);
    }
    #[cfg(target_os = "macos")]
    {
        let pct = format!("{}", (_vol * 100.0).round() as i32);
        let _ = Command::new("audiomatrix")
            .args(["volume", _id, &pct])
            .status();
    }
}

fn os_set_app_volume(_kind: BackendKind, _id: &str, _vol: f32) {
    #[cfg(target_os = "linux")]
    {
        let pct = format!("{}%", (_vol * 100.0).round() as i32);
        let _ = Command::new("pactl")
            .args(["set-sink-input-volume", _id, &pct])
            .status();
    }
    #[cfg(target_os = "windows")]
    {
        let pct = format!("{}", (_vol * 100.0).round().clamp(0.0, 100.0) as i32);
        windows_run_wasapi(&["set-app-volume", _id, &pct]);
    }
}

fn os_set_app_mute(_kind: BackendKind, _id: &str, _muted: bool) {
    #[cfg(target_os = "linux")]
    {
        let flag = if _muted { "1" } else { "0" };
        let _ = Command::new("pactl")
            .args(["set-sink-input-mute", _id, flag])
            .status();
    }
    #[cfg(target_os = "windows")]
    {
        let flag = if _muted { "1" } else { "0" };
        windows_run_wasapi(&["set-app-mute", _id, flag]);
    }
}

fn os_route_app(_kind: BackendKind, _id: &str, _target_sink: &str) {
    #[cfg(target_os = "linux")]
    {
        let _ = Command::new("pactl")
            .args(["move-sink-input", _id, _target_sink])
            .status();
    }
}

#[cfg(target_os = "linux")]
fn linux_query_devices() -> Vec<PlatformAudioDevice> {
    let default_sink = Command::new("pactl")
        .arg("get-default-sink")
        .output()
        .ok()
        .and_then(|o| {
            if o.status.success() {
                Some(String::from_utf8_lossy(&o.stdout).trim().to_string())
            } else {
                None
            }
        })
        .unwrap_or_default();
    let default_source = Command::new("pactl")
        .arg("get-default-source")
        .output()
        .ok()
        .and_then(|o| {
            if o.status.success() {
                Some(String::from_utf8_lossy(&o.stdout).trim().to_string())
            } else {
                None
            }
        })
        .unwrap_or_default();

    let mut devices = Vec::new();
    if let Ok(out) = Command::new("pactl").args(["list", "short", "sinks"]).output() {
        if out.status.success() {
            for line in String::from_utf8_lossy(&out.stdout).lines() {
                let cols: Vec<&str> = line.split('\t').collect();
                if cols.len() >= 2 {
                    let id = cols[1].trim().to_string();
                    let is_virtual = id.contains("null") || id.contains("audiomatrix");
                    let pretty = id.replace('.', " ").replace('_', " ");
                    devices.push(PlatformAudioDevice {
                        id: id.clone(),
                        name: if id.contains("audiomatrix_virtual_mic") {
                            "AudioMatrix Virtual Mic".to_string()
                        } else {
                            pretty
                        },
                        transport: if id.contains("bluez") {
                            "Bluetooth".to_string()
                        } else if id.contains("usb") {
                            "USB".to_string()
                        } else if is_virtual {
                            "Virtual".to_string()
                        } else {
                            "PipeWire".to_string()
                        },
                        is_input: false,
                        is_output: true,
                        is_virtual,
                        is_default_input: false,
                        is_default_output: id == default_sink,
                        volume: 0.75,
                        sample_rate: 48_000.0,
                    });
                }
            }
        }
    }

    if let Ok(out) = Command::new("pactl")
        .args(["list", "short", "sources"])
        .output()
    {
        if out.status.success() {
            for line in String::from_utf8_lossy(&out.stdout).lines() {
                let cols: Vec<&str> = line.split('\t').collect();
                if cols.len() >= 2 {
                    let id = cols[1].trim().to_string();
                    if id.ends_with(".monitor") && !id.contains("audiomatrix") {
                        continue;
                    }
                    let is_virtual = id.contains("audiomatrix") || id.contains("monitor");
                    devices.push(PlatformAudioDevice {
                        id: id.clone(),
                        name: if id.contains("audiomatrix") {
                            "AudioMatrix Virtual Mic".to_string()
                        } else {
                            id.replace('.', " ").replace('_', " ")
                        },
                        transport: if is_virtual {
                            "Virtual".to_string()
                        } else if id.contains("usb") {
                            "USB".to_string()
                        } else {
                            "PipeWire".to_string()
                        },
                        is_input: true,
                        is_output: false,
                        is_virtual,
                        is_default_input: id == default_source,
                        is_default_output: false,
                        volume: 1.0,
                        sample_rate: 48_000.0,
                    });
                }
            }
        }
    }

    devices
}

#[cfg(target_os = "linux")]
fn linux_query_app_streams() -> Vec<AppAudioStream> {
    let Ok(out) = Command::new("pactl").args(["list", "sink-inputs"]).output() else {
        return Vec::new();
    };
    if !out.status.success() {
        return Vec::new();
    }
    let text = String::from_utf8_lossy(&out.stdout);
    let mut result = Vec::new();
    let mut cur_id: Option<String> = None;
    let mut cur_name = String::new();
    let mut cur_bin = String::new();
    let mut cur_pid = 0u32;
    let mut cur_muted = false;
    let mut cur_vol = 1.0f32;

    for raw_line in text.lines() {
        let line = raw_line.trim();
        if let Some(rest) = line.strip_prefix("Sink Input #") {
            if let Some(id) = cur_id.take() {
                result.push(AppAudioStream {
                    id,
                    app_name: if cur_name.is_empty() {
                        "Audio Stream".to_string()
                    } else {
                        cur_name.clone()
                    },
                    binary_name: cur_bin.clone(),
                    pid: cur_pid,
                    volume: cur_vol,
                    is_muted: cur_muted,
                    target_device_id: None,
                    is_producing_audio: true,
                });
            }
            cur_id = Some(rest.trim().to_string());
            cur_name.clear();
            cur_bin.clear();
            cur_pid = 0;
            cur_muted = false;
            cur_vol = 1.0;
        } else if let Some(val) = line.strip_prefix("Mute:") {
            cur_muted = val.trim().eq_ignore_ascii_case("yes");
        } else if line.starts_with("Volume:") {
            if let Some(pct_idx) = line.find('%') {
                let prefix = &line[..pct_idx];
                if let Some(num_str) = prefix.split_whitespace().last() {
                    if let Ok(pct) = num_str.parse::<f32>() {
                        cur_vol = (pct / 100.0).clamp(0.0, 2.0);
                    }
                }
            }
        } else if let Some(val) = line.strip_prefix("application.name = ") {
            cur_name = val.trim_matches('"').to_string();
        } else if let Some(val) = line.strip_prefix("application.process.binary = ") {
            cur_bin = val.trim_matches('"').to_string();
        } else if let Some(val) = line.strip_prefix("application.process.id = ") {
            cur_pid = val.trim_matches('"').parse::<u32>().unwrap_or(0);
        }
    }
    if let Some(id) = cur_id.take() {
        result.push(AppAudioStream {
            id,
            app_name: if cur_name.is_empty() {
                "Audio Stream".to_string()
            } else {
                cur_name
            },
            binary_name: cur_bin,
            pid: cur_pid,
            volume: cur_vol,
            is_muted: cur_muted,
            target_device_id: None,
            is_producing_audio: true,
        });
    }
    result
}

#[cfg(target_os = "linux")]
fn linux_toggle_share_audio(
    enabled: bool,
    primary: Option<&str>,
    secondary: Option<&str>,
    module_ids: &mut Vec<String>,
) {
    if !enabled {
        for m in module_ids.drain(..) {
            let _ = Command::new("pactl").args(["unload-module", &m]).status();
        }
        return;
    }
    if let (Some(a), Some(b)) = (primary, secondary) {
        let slaves = format!("slaves={},{}", a, b);
        if let Ok(out) = Command::new("pactl")
            .args([
                "load-module",
                "module-combine-sink",
                "sink_name=audiomatrix_dual_out",
                &slaves,
            ])
            .output()
        {
            if out.status.success() {
                let mod_id = String::from_utf8_lossy(&out.stdout).trim().to_string();
                module_ids.push(mod_id);
                let _ = Command::new("pactl")
                    .args(["set-default-sink", "audiomatrix_dual_out"])
                    .status();
            }
        }
    }
}

#[cfg(target_os = "linux")]
fn linux_toggle_loopback(enabled: bool, include_mic: bool, module_ids: &mut Vec<String>) {
    if !enabled {
        for m in module_ids.drain(..) {
            let _ = Command::new("pactl").args(["unload-module", &m]).status();
        }
        return;
    }
    if let Ok(out) = Command::new("pactl")
        .args([
            "load-module",
            "module-null-sink",
            "sink_name=audiomatrix_virtual_mic",
            "sink_properties=device.description=AudioMatrix_Virtual_Mic",
        ])
        .output()
    {
        if out.status.success() {
            module_ids.push(String::from_utf8_lossy(&out.stdout).trim().to_string());
        }
    }
    if let Ok(def_sink) = Command::new("pactl").arg("get-default-sink").output() {
        let sink = String::from_utf8_lossy(&def_sink.stdout).trim().to_string();
        if !sink.is_empty() {
            let monitor = format!("source={}.monitor", sink);
            if let Ok(out) = Command::new("pactl")
                .args([
                    "load-module",
                    "module-loopback",
                    &monitor,
                    "sink=audiomatrix_virtual_mic",
                ])
                .output()
            {
                if out.status.success() {
                    module_ids.push(String::from_utf8_lossy(&out.stdout).trim().to_string());
                }
            }
        }
    }
    if include_mic {
        if let Ok(out) = Command::new("pactl")
            .args([
                "load-module",
                "module-loopback",
                "sink=audiomatrix_virtual_mic",
            ])
            .output()
        {
            if out.status.success() {
                module_ids.push(String::from_utf8_lossy(&out.stdout).trim().to_string());
            }
        }
    }
}

#[cfg(target_os = "windows")]
const WINDOWS_WASAPI_HELPER_PS1: &str = r#"
param(
    [string]$Action,
    [string]$Arg1 = "",
    [string]$Arg2 = ""
)

$code = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace AudioMatrixWasapi {
    [StructLayout(LayoutKind.Sequential)]
    public struct PROPERTYKEY {
        public Guid fmtid;
        public uint pid;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PROPVARIANT {
        public ushort vt;
        public ushort wReserved1;
        public ushort wReserved2;
        public ushort wReserved3;
        public IntPtr p;
        public int p2;
    }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPropertyStore {
        int GetCount(out int cProps);
        int GetAt(int iProp, out PROPERTYKEY pkey);
        int GetValue(ref PROPERTYKEY key, out PROPVARIANT pv);
        int SetValue(ref PROPERTYKEY key, ref PROPVARIANT propvar);
        int Commit();
    }

    [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IAudioEndpointVolume {
        int RegisterControlChangeNotify(IntPtr pNotify);
        int UnregisterControlChangeNotify(IntPtr pNotify);
        int GetChannelCount(out uint pnChannelCount);
        int SetMasterVolumeLevel(float fLevelDB, ref Guid pguidEventContext);
        int SetMasterVolumeLevelScalar(float fLevel, ref Guid pguidEventContext);
        int GetMasterVolumeLevel(out float pfLevelDB);
        int GetMasterVolumeLevelScalar(out float pfLevel);
        int SetChannelVolumeLevel(uint nChannel, float fLevelDB, ref Guid pguidEventContext);
        int SetChannelVolumeLevelScalar(uint nChannel, float fLevel, ref Guid pguidEventContext);
        int GetChannelVolumeLevel(uint nChannel, out float pfLevelDB);
        int GetChannelVolumeLevelScalar(uint nChannel, out float pfLevel);
        int SetMute([MarshalAs(UnmanagedType.Bool)] bool bMute, ref Guid pguidEventContext);
        int GetMute([MarshalAs(UnmanagedType.Bool)] out bool pbMute);
    }

    [ComImport, Guid("87CE5498-68D6-44E5-9215-6DA47EF883D8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface ISimpleAudioVolume {
        int SetMasterVolume(float fLevel, ref Guid EventContext);
        int GetMasterVolume(out float pfLevel);
        int SetMute([MarshalAs(UnmanagedType.Bool)] bool bMute, ref Guid EventContext);
        int GetMute([MarshalAs(UnmanagedType.Bool)] out bool pbMute);
    }

    [ComImport, Guid("F4B1A599-7266-4319-A8CA-E70ACB11E8CD"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IAudioSessionControl {
        int GetState(out int pRetVal);
        int GetDisplayName([MarshalAs(UnmanagedType.LPWStr)] out string pRetVal);
        int SetDisplayName([MarshalAs(UnmanagedType.LPWStr)] string Value, ref Guid EventContext);
        int GetIconPath([MarshalAs(UnmanagedType.LPWStr)] out string pRetVal);
        int SetIconPath([MarshalAs(UnmanagedType.LPWStr)] string Value, ref Guid EventContext);
        int GetGroupingParam(out Guid pRetVal);
        int SetGroupingParam(ref Guid Override, ref Guid EventContext);
        int RegisterAudioSessionNotification(IntPtr NewNotifications);
        int UnregisterAudioSessionNotification(IntPtr NewNotifications);
    }

    [ComImport, Guid("BFB7FF88-7239-4FC9-8FA2-07C950BE9C6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IAudioSessionControl2 {
        int GetState(out int pRetVal);
        int GetDisplayName([MarshalAs(UnmanagedType.LPWStr)] out string pRetVal);
        int SetDisplayName([MarshalAs(UnmanagedType.LPWStr)] string Value, ref Guid EventContext);
        int GetIconPath([MarshalAs(UnmanagedType.LPWStr)] out string pRetVal);
        int SetIconPath([MarshalAs(UnmanagedType.LPWStr)] string Value, ref Guid EventContext);
        int GetGroupingParam(out Guid pRetVal);
        int SetGroupingParam(ref Guid Override, ref Guid EventContext);
        int RegisterAudioSessionNotification(IntPtr NewNotifications);
        int UnregisterAudioSessionNotification(IntPtr NewNotifications);
        int GetSessionIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string pRetVal);
        int GetSessionInstanceIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string pRetVal);
        int GetProcessId(out uint pRetVal);
        int IsSystemSoundsSession();
        int SetDuckingPreference([MarshalAs(UnmanagedType.Bool)] bool optOut);
    }

    [ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IAudioSessionEnumerator {
        int GetCount(out int SessionCount);
        int GetSession(int SessionCount, out IAudioSessionControl Session);
    }

    [ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IAudioSessionManager2 {
        int GetAudioSessionControl(IntPtr AudioSessionGuid, uint StreamFlags, out IAudioSessionControl SessionControl);
        int GetSimpleAudioVolume(IntPtr AudioSessionGuid, uint StreamFlags, out ISimpleAudioVolume AudioVolume);
        int GetSessionEnumerator(out IAudioSessionEnumerator SessionEnum);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMMDevice {
        int Activate(ref Guid iid, int dwClsCtx, IntPtr pActivationParams, [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface);
        int OpenPropertyStore(int stgmAccess, out IPropertyStore ppProperties);
        int GetId([MarshalAs(UnmanagedType.LPWStr)] out string ppstrId);
        int GetState(out int pdwState);
    }

    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMMDeviceCollection {
        int GetCount(out int pcDevices);
        int Item(int nDevice, out IMMDevice ppDevice);
    }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMMDeviceEnumerator {
        int EnumAudioEndpoints(int dataFlow, int dwStateMask, out IMMDeviceCollection ppDevices);
        int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice ppEndpoint);
        int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string pwstrId, out IMMDevice ppDevice);
    }

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    public class MMDeviceEnumeratorCom {}

    [ComImport, Guid("F8679F50-850A-41CF-9C72-430F290290C8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPolicyConfig {
        int GetMixFormat(string pszDeviceName, IntPtr ppFormat);
        int GetDeviceFormat(string pszDeviceName, bool bDefault, IntPtr ppFormat);
        int ResetDeviceFormat(string pszDeviceName);
        int SetDeviceFormat(string pszDeviceName, IntPtr pEndpointFormat, IntPtr mixFormat);
        int GetProcessingPeriod(string pszDeviceName, bool bDefault, IntPtr pmftDefaultPeriod, IntPtr pmftMinimumPeriod);
        int SetProcessingPeriod(string pszDeviceName, IntPtr pmftPeriod);
        int GetShareMode(string pszDeviceName, IntPtr pMode);
        int SetShareMode(string pszDeviceName, IntPtr mode);
        int GetPropertyValue(string pszDeviceName, bool bFxStore, IntPtr key, IntPtr pv);
        int SetPropertyValue(string pszDeviceName, bool bFxStore, IntPtr key, IntPtr pv);
        int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string pszDeviceName, int role);
        int SetEndpointVisibility(string pszDeviceName, bool bVisible);
    }

    [ComImport, Guid("870AF99C-171D-4F9E-AF0D-E63DF40C2BC9")]
    public class PolicyConfigClientCom {}

    public static class Hub {
        private static readonly Guid IID_IAudioEndpointVolume = new Guid("5CDF2C82-841E-4546-9722-0CF74078229A");
        private static readonly Guid IID_IAudioSessionManager2 = new Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F");

        private static string GetFriendlyName(IMMDevice dev) {
            try {
                IPropertyStore store;
                if (dev.OpenPropertyStore(0, out store) != 0 || store == null) return "Audio Device";
                PROPERTYKEY key = new PROPERTYKEY { fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), pid = 14 };
                PROPVARIANT pv;
                if (store.GetValue(ref key, out pv) == 0 && pv.vt == 31 && pv.p != IntPtr.Zero) {
                    return Marshal.PtrToStringUni(pv.p) ?? "Audio Device";
                }
            } catch {}
            return "Audio Device";
        }

        private static string GetDefaultId(IMMDeviceEnumerator enumObj, int flow) {
            try {
                IMMDevice defDev;
                if (enumObj.GetDefaultAudioEndpoint(flow, 0, out defDev) == 0 && defDev != null) {
                    string id;
                    if (defDev.GetId(out id) == 0) return id ?? "";
                }
            } catch {}
            return "";
        }

        public static List<string> ListDevices() {
            var lines = new List<string>();
            try {
                var enumObj = (IMMDeviceEnumerator)(new MMDeviceEnumeratorCom());
                string defOut = GetDefaultId(enumObj, 0);
                string defIn = GetDefaultId(enumObj, 1);

                for (int flow = 0; flow <= 1; flow++) {
                    IMMDeviceCollection col;
                    if (enumObj.EnumAudioEndpoints(flow, 1, out col) != 0 || col == null) continue;
                    int count;
                    col.GetCount(out count);
                    for (int i = 0; i < count; i++) {
                        IMMDevice dev;
                        if (col.Item(i, out dev) != 0 || dev == null) continue;
                        string id;
                        dev.GetId(out id);
                        string name = GetFriendlyName(dev).Replace("\t", " ");
                        float vol = 0.75f;
                        try {
                            object obj;
                            Guid iid = IID_IAudioEndpointVolume;
                            if (dev.Activate(ref iid, 23, IntPtr.Zero, out obj) == 0 && obj != null) {
                                ((IAudioEndpointVolume)obj).GetMasterVolumeLevelScalar(out vol);
                            }
                        } catch {}
                        string isOut = flow == 0 ? "1" : "0";
                        string isIn = flow == 1 ? "1" : "0";
                        string isDefOut = (flow == 0 && id == defOut) ? "1" : "0";
                        string isDefIn = (flow == 1 && id == defIn) ? "1" : "0";
                        lines.Add(string.Format("{0}\t{1}\t{2}\t{3}\t{4}\t{5}\t{6}",
                            id, name, isOut, isIn, isDefOut, isDefIn,
                            vol.ToString(System.Globalization.CultureInfo.InvariantCulture)));
                    }
                }
            } catch {}
            return lines;
        }

        public static void SetDefault(string id) {
            try {
                var pc = (IPolicyConfig)(new PolicyConfigClientCom());
                pc.SetDefaultEndpoint(id, 0);
                pc.SetDefaultEndpoint(id, 1);
                pc.SetDefaultEndpoint(id, 2);
            } catch {}
        }

        public static void SetDeviceVolume(string id, float scalar) {
            try {
                var enumObj = (IMMDeviceEnumerator)(new MMDeviceEnumeratorCom());
                IMMDevice dev;
                if (enumObj.GetDevice(id, out dev) == 0 && dev != null) {
                    object obj;
                    Guid iid = IID_IAudioEndpointVolume;
                    if (dev.Activate(ref iid, 23, IntPtr.Zero, out obj) == 0 && obj != null) {
                        Guid ctx = Guid.Empty;
                        ((IAudioEndpointVolume)obj).SetMasterVolumeLevelScalar(Math.Max(0f, Math.Min(1f, scalar)), ref ctx);
                    }
                }
            } catch {}
        }

        public static List<string> ListApps() {
            var lines = new List<string>();
            var seenPids = new HashSet<uint>();
            try {
                var enumObj = (IMMDeviceEnumerator)(new MMDeviceEnumeratorCom());
                IMMDevice defOut;
                if (enumObj.GetDefaultAudioEndpoint(0, 0, out defOut) != 0 || defOut == null) return lines;
                object mgrObj;
                Guid iid = IID_IAudioSessionManager2;
                if (defOut.Activate(ref iid, 23, IntPtr.Zero, out mgrObj) != 0 || mgrObj == null) return lines;
                IAudioSessionEnumerator sessEnum;
                ((IAudioSessionManager2)mgrObj).GetSessionEnumerator(out sessEnum);
                int count;
                sessEnum.GetCount(out count);
                for (int i = 0; i < count; i++) {
                    IAudioSessionControl ctrl;
                    if (sessEnum.GetSession(i, out ctrl) != 0 || ctrl == null) continue;
                    var ctrl2 = ctrl as IAudioSessionControl2;
                    var sav = ctrl as ISimpleAudioVolume;
                    if (ctrl2 == null || sav == null) continue;
                    if (ctrl2.IsSystemSoundsSession() == 0) continue;
                    uint pid = 0;
                    ctrl2.GetProcessId(out pid);
                    if (pid == 0 || seenPids.Contains(pid)) continue;
                    seenPids.Add(pid);
                    string procName = "App " + pid;
                    try {
                        var p = Process.GetProcessById((int)pid);
                        if (!string.IsNullOrEmpty(p.ProcessName)) procName = p.ProcessName;
                    } catch {}
                    int state = 0;
                    ctrl2.GetState(out state);
                    float vol = 1f;
                    bool muted = false;
                    sav.GetMasterVolume(out vol);
                    sav.GetMute(out muted);
                    lines.Add(string.Format("{0}\t{1}\t{2}\t{3}\t{4}",
                        pid, procName.Replace("\t", " "),
                        vol.ToString(System.Globalization.CultureInfo.InvariantCulture),
                        muted ? "1" : "0",
                        state == 1 ? "1" : "0"));
                }
            } catch {}
            return lines;
        }

        public static void SetAppControl(uint pid, float scalar, bool? muteFlag) {
            try {
                var enumObj = (IMMDeviceEnumerator)(new MMDeviceEnumeratorCom());
                IMMDevice defOut;
                if (enumObj.GetDefaultAudioEndpoint(0, 0, out defOut) != 0 || defOut == null) return;
                object mgrObj;
                Guid iid = IID_IAudioSessionManager2;
                if (defOut.Activate(ref iid, 23, IntPtr.Zero, out mgrObj) != 0 || mgrObj == null) return;
                IAudioSessionEnumerator sessEnum;
                ((IAudioSessionManager2)mgrObj).GetSessionEnumerator(out sessEnum);
                int count;
                sessEnum.GetCount(out count);
                Guid ctx = Guid.Empty;
                for (int i = 0; i < count; i++) {
                    IAudioSessionControl ctrl;
                    if (sessEnum.GetSession(i, out ctrl) != 0 || ctrl == null) continue;
                    var ctrl2 = ctrl as IAudioSessionControl2;
                    var sav = ctrl as ISimpleAudioVolume;
                    if (ctrl2 == null || sav == null) continue;
                    uint spid = 0;
                    ctrl2.GetProcessId(out spid);
                    if (spid != pid) continue;
                    if (muteFlag.HasValue) {
                        sav.SetMute(muteFlag.Value, ref ctx);
                    } else {
                        sav.SetMasterVolume(Math.Max(0f, Math.Min(1f, scalar)), ref ctx);
                    }
                }
            } catch {}
        }
    }
}
'@

if (-not ("AudioMatrixWasapi.Hub" -as [type])) {
    Add-Type -TypeDefinition $code -Language CSharp | Out-Null
}

switch ($Action) {
    "list-devices" { [AudioMatrixWasapi.Hub]::ListDevices() }
    "set-default" { [AudioMatrixWasapi.Hub]::SetDefault($Arg1) }
    "set-volume" { [AudioMatrixWasapi.Hub]::SetDeviceVolume($Arg1, ([float]$Arg2 / 100.0)) }
    "list-apps" { [AudioMatrixWasapi.Hub]::ListApps() }
    "set-app-volume" { [AudioMatrixWasapi.Hub]::SetAppControl([uint32]$Arg1, ([float]$Arg2 / 100.0), $null) }
    "set-app-mute" { [AudioMatrixWasapi.Hub]::SetAppControl([uint32]$Arg1, 1.0, ($Arg2 -eq "1")) }
}
"#;

#[cfg(target_os = "windows")]
fn windows_ensure_wasapi_helper() -> Option<PathBuf> {
    let path = std::env::temp_dir().join("audiomatrix_wasapi_helper.ps1");
    if !path.exists() {
        std::fs::write(&path, WINDOWS_WASAPI_HELPER_PS1).ok()?;
    }
    Some(path)
}

#[cfg(target_os = "windows")]
fn windows_run_wasapi(args: &[&str]) -> String {
    let Some(helper) = windows_ensure_wasapi_helper() else {
        return String::new();
    };
    let helper_str = helper.to_string_lossy().to_string();
    let mut cmd_args = vec![
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        &helper_str,
    ];
    cmd_args.extend_from_slice(args);
    Command::new("powershell")
        .args(&cmd_args)
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).to_string())
        .unwrap_or_default()
}

#[cfg(target_os = "windows")]
fn windows_query_devices() -> Vec<PlatformAudioDevice> {
    let raw = windows_run_wasapi(&["list-devices"]);
    let mut devs = Vec::new();
    for line in raw.lines() {
        let cols: Vec<&str> = line.split('\t').collect();
        if cols.len() >= 7 {
            let id = cols[0].trim().to_string();
            let name = cols[1].trim().to_string();
            let low = name.to_lowercase();
            let is_output = cols[2].trim() == "1";
            let is_input = cols[3].trim() == "1";
            let is_default_output = cols[4].trim() == "1";
            let is_default_input = cols[5].trim() == "1";
            let volume = cols[6].trim().parse::<f32>().unwrap_or(0.75).clamp(0.0, 1.0);
            let is_virtual = low.contains("virtual") || low.contains("vb-audio") || low.contains("cable");
            let transport = if low.contains("usb") {
                "USB"
            } else if low.contains("bluetooth") || low.contains("hands-free") {
                "Bluetooth"
            } else if is_virtual {
                "Virtual"
            } else {
                "WASAPI"
            };
            devs.push(PlatformAudioDevice {
                id,
                name,
                transport: transport.to_string(),
                is_input,
                is_output,
                is_virtual,
                is_default_input,
                is_default_output,
                volume,
                sample_rate: 48_000.0,
            });
        }
    }
    devs
}

#[cfg(target_os = "windows")]
fn windows_query_app_streams() -> Vec<AppAudioStream> {
    let raw = windows_run_wasapi(&["list-apps"]);
    let mut apps = Vec::new();
    for line in raw.lines() {
        let cols: Vec<&str> = line.split('\t').collect();
        if cols.len() >= 5 {
            let pid_str = cols[0].trim().to_string();
            let pid = pid_str.parse::<u32>().unwrap_or(0);
            let name = cols[1].trim().to_string();
            let volume = cols[2].trim().parse::<f32>().unwrap_or(1.0).clamp(0.0, 2.0);
            let is_muted = cols[3].trim() == "1";
            let is_producing_audio = cols[4].trim() == "1";
            apps.push(AppAudioStream {
                id: pid_str,
                app_name: name.clone(),
                binary_name: name.to_lowercase(),
                pid,
                volume,
                is_muted,
                target_device_id: None,
                is_producing_audio,
            });
        }
    }
    apps
}

const CORE_VERSION_CSTR: &[u8] = b"2.0.0\0";

#[no_mangle]
pub extern "C" fn am_core_version() -> *const c_char {
    CORE_VERSION_CSTR.as_ptr() as *const c_char
}

#[no_mangle]
pub extern "C" fn am_platform_backend_name() -> *const c_char {
    let backend = NativePlatformBackend;
    backend.backend_kind().as_c_str().as_ptr() as *const c_char
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CStr;

    #[test]
    fn test_backend_detection_and_c_exports() {
        let backend = NativePlatformBackend;
        let kind = backend.backend_kind();
        assert!(backend.supports_process_tap());
        assert_eq!(backend.default_sample_rate(), 48_000.0);

        unsafe {
            let ver = CStr::from_ptr(am_core_version()).to_str().unwrap();
            assert_eq!(ver, "2.0.0");

            let name = CStr::from_ptr(am_platform_backend_name()).to_str().unwrap();
            assert_eq!(name, kind.name());
        }
    }

    #[test]
    fn test_system_controller_mixer_dsp_and_wav_pipeline() {
        let mut ctrl = SystemAudioController::new();
        assert!(!ctrl.devices.is_empty());

        let mut dsp = DspConfigState::default();
        dsp.apply_speaker_mode(DspPresetSpeaker::Studio);
        dsp.apply_tone_mode(DspPresetTone::VShape);
        assert_eq!(dsp.summary_title(), "Studio + V-Shape");
        ctrl.update_dsp_config(dsp);

        ctrl.set_app_volume("app-chrome", 1.45);
        assert!(ctrl.has_custom_app_changes());
        ctrl.reset_all_app_streams();
        assert!(!ctrl.has_custom_app_changes());

        let wav_path = ctrl.start_recording(None).unwrap();
        let mut audio = vec![0.25f32; 512 * 2];
        let processed = ctrl.process_and_record_frames(&mut audio).unwrap();
        assert_eq!(processed, 512);
        let closed = ctrl.stop_recording().unwrap();
        assert_eq!(closed, wav_path);
        let meta = std::fs::metadata(&closed).unwrap();
        assert_eq!(meta.len(), 44 + 512 * 8);
        let _ = std::fs::remove_file(&closed);
    }
}
