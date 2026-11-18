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
    #[cfg(not(target_os = "linux"))]
    {
        Vec::new()
    }
}

fn os_set_default_output(_kind: BackendKind, _id: &str) {
    #[cfg(target_os = "linux")]
    {
        let _ = Command::new("pactl").args(["set-default-sink", _id]).status();
    }
    #[cfg(target_os = "windows")]
    {
        let script = format!(
            "if (Get-Command Set-AudioDevice -ErrorAction SilentlyContinue) {{ Set-AudioDevice -Index {} | Out-Null }}",
            _id
        );
        let _ = Command::new("powershell")
            .args(["-NoProfile", "-NonInteractive", "-Command", &script])
            .status();
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
}

fn os_set_app_mute(_kind: BackendKind, _id: &str, _muted: bool) {
    #[cfg(target_os = "linux")]
    {
        let flag = if _muted { "1" } else { "0" };
        let _ = Command::new("pactl")
            .args(["set-sink-input-mute", _id, flag])
            .status();
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
fn windows_query_devices() -> Vec<PlatformAudioDevice> {
    let script = "Get-CimInstance Win32_SoundDevice | Where-Object { $_.Status -eq 'OK' } | Select-Object -ExpandProperty Name";
    let Ok(out) = Command::new("powershell")
        .args(["-NoProfile", "-NonInteractive", "-Command", script])
        .output()
    else {
        return Vec::new();
    };
    if !out.status.success() {
        return Vec::new();
    }
    let names: Vec<String> = String::from_utf8_lossy(&out.stdout)
        .lines()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .collect();
    if names.is_empty() {
        return Vec::new();
    }
    let mut devs = Vec::new();
    for (idx, name) in names.into_iter().enumerate() {
        let low = name.to_lowercase();
        let is_mic_only = low.contains("microphone") || low.contains("mic ");
        let is_virtual = low.contains("virtual") || low.contains("vb-audio");
        devs.push(PlatformAudioDevice {
            id: format!("wasapi-dev-{}", idx),
            name,
            transport: if low.contains("usb") {
                "USB".to_string()
            } else if low.contains("bluetooth") {
                "Bluetooth".to_string()
            } else {
                "WASAPI".to_string()
            },
            is_input: is_mic_only || low.contains("mv7"),
            is_output: !is_mic_only,
            is_virtual,
            is_default_input: idx == 0 && (is_mic_only || low.contains("mv7")),
            is_default_output: idx == 0 && !is_mic_only,
            volume: 0.75,
            sample_rate: 48_000.0,
        });
    }
    devs
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
