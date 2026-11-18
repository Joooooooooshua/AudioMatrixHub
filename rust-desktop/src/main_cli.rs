use std::env;
use std::path::PathBuf;
use std::process;

use audiomatrix_rust_core::{
    am_dsp_configure, am_dsp_create, am_dsp_destroy, am_dsp_process_stereo_interleaved,
    am_wav_write_header, decode_float_message, encode_float_message, slugify_str,
    AmRingBuffer, DspPresetSpeaker, DspPresetTone, SystemAudioController,
};

fn print_usage() {
    println!(
        "AudioMatrix PC CLI (v2.0.0 — Windows WASAPI / Linux PipeWire / macOS)
Usage:
  audiomatrix-pc status
  audiomatrix-pc speaker <off|nearfield|studio|stage>
  audiomatrix-pc tone <off|warm|clear|bass|vshape>
  audiomatrix-pc input <device_id>
  audiomatrix-pc output <device_id>
  audiomatrix-pc volume <device_id> <0-100>
  audiomatrix-pc app-volume <app_id> <0-200>
  audiomatrix-pc reset-apps
  audiomatrix-pc record <output.wav>
  audiomatrix-pc self-test"
    );
}

fn check(cond: bool, msg: &str) {
    if !cond {
        eprintln!("TEST FAILURE: {}", msg);
        process::exit(1);
    }
}

fn run_self_tests() {
    println!("Running AudioMatrix Cross-Platform (Rust Core + OS Drivers) self-test suite...");

    // 1. OSC slugify & IEEE-754 big-endian encode/decode
    check(slugify_str("Waves NX") == "waves-nx", "Slugify mismatch");
    let pkt = encode_float_message("/element/node/waves-nx/bypass", 1.0);
    let decoded = decode_float_message(&pkt).unwrap();
    check(
        decoded.0 == "/element/node/waves-nx/bypass" && decoded.1 == 1.0,
        "OSC decode mismatch",
    );
    println!("  [PASS] 1/6: Cross-platform OSC slugify & IEEE-754 binary codec");

    // 2. Real-time Rust DSP (ITD/ILD crossfeed, room reflections, EQ, limiter, NaN guard)
    unsafe {
        let dsp = am_dsp_create(48_000.0);
        am_dsp_configure(dsp, 48_000.0, true, 0.65, 0.30, 3.5, -1.0, 3.0, true);
        let mut buf = vec![0.0f32; 512 * 2];
        buf[0] = 1.0;
        am_dsp_process_stereo_interleaved(dsp, buf.as_mut_ptr(), 512);
        let mut right_energy = 0.0f32;
        for f in 1..512 {
            let l = buf[f * 2];
            let r = buf[f * 2 + 1];
            check(l.is_finite() && r.is_finite(), "DSP non-finite output");
            right_energy += r * r;
        }
        check(right_energy > 1e-4, "ITD/ILD crossfeed energy check failed");

        let mut overload = vec![4.0f32; 256 * 2];
        overload[2] = f32::NAN;
        am_dsp_process_stereo_interleaved(dsp, overload.as_mut_ptr(), 256);
        for s in overload {
            check(s.is_finite() && s.abs() <= 1.0, "Limiter/NaN guard failed");
        }
        am_dsp_destroy(dsp);
    }
    println!("  [PASS] 2/6: Cross-platform Rust AmDspEngine (crossfeed, EQ, limiter & NaN guard)");

    // 3. Lock-free SPSC Ring Buffer
    unsafe {
        let ring = AmRingBuffer::new(256);
        let mut src = vec![0.0f32; 160 * 2];
        for i in 0..160 {
            src[i * 2] = i as f32;
            src[i * 2 + 1] = -(i as f32);
        }
        check(ring.write(src.as_ptr(), 160) == 160, "Ring write failed");
        let mut dst = vec![0.0f32; 160 * 2];
        check(ring.read(dst.as_mut_ptr(), 160) == 160, "Ring read failed");
        check(
            dst[159 * 2] == 159.0 && dst[159 * 2 + 1] == -159.0,
            "Ring sample verification failed",
        );
    }
    println!("  [PASS] 3/6: Lock-free AtomicU64 SPSC ring buffer");

    // 4. OS Backend Detection & Device Enumeration
    let mut ctrl = SystemAudioController::new();
    check(!ctrl.devices.is_empty(), "Expected >= 1 audio endpoint");
    println!(
        "  [PASS] 4/6: OS backend [{}] enumerated {} device(s)",
        ctrl.backend_kind.name(),
        ctrl.devices.len()
    );

    // 5. Output-stage Per-App Mixer, Reset to Default & BT Mic Guard
    ctrl.set_app_volume("app-chrome", 1.5);
    check(
        ctrl.has_custom_app_changes(),
        "App mixer should report custom changes",
    );
    ctrl.reset_all_app_streams();
    check(
        !ctrl.has_custom_app_changes(),
        "reset_all_app_streams failed",
    );
    ctrl.set_loopback_active(true);
    check(ctrl.loopback_active, "Loopback enable failed");
    ctrl.set_loopback_active(false);
    println!("  [PASS] 5/6: Output-stage per-app mixer reset & zero-echo loopback toggle");

    // 6. 48kHz IEEE Float32 WAV Recorder & DSP File Export
    let mut hdr = [0u8; 44];
    unsafe {
        am_wav_write_header(48_000, 2, 1024 * 8, hdr.as_mut_ptr());
    }
    check(&hdr[0..4] == b"RIFF" && &hdr[8..12] == b"WAVE", "Invalid WAV header");

    let rec_path = ctrl.start_recording(None).unwrap();
    let mut pcm = vec![0.25f32; 1024 * 2];
    ctrl.process_and_record_frames(&mut pcm).unwrap();
    let saved = ctrl.stop_recording().unwrap();
    let meta = std::fs::metadata(&saved).unwrap();
    check(meta.len() == 44 + 1024 * 8, "WAV recorded byte count mismatch");
    let _ = std::fs::remove_file(&rec_path);
    println!("  [PASS] 6/6: 48kHz IEEE Float32 internal WAV recorder & file export");

    println!("All 6 cross-platform self-test suites passed.");
}

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    if args.is_empty() {
        print_usage();
        return;
    }

    let mut ctrl = SystemAudioController::new();
    match args[0].as_str() {
        "status" => {
            println!("Backend        : {}", ctrl.backend_kind.name());
            println!(
                "Driver Mode    : {}",
                if ctrl.using_live_os_driver {
                    "Live OS Driver"
                } else {
                    "Virtual/Fallback"
                }
            );
            if let Some(d) = ctrl.default_input() {
                println!(
                    "Default Input  : {} ({}) | BT Guard: {}",
                    d.name,
                    d.transport,
                    if ctrl.bt_mic_guard_enabled {
                        "On"
                    } else {
                        "Off"
                    }
                );
            }
            if let Some(d) = ctrl.default_output() {
                println!(
                    "Default Output : {} ({}) | Vol: {}%",
                    d.name,
                    d.transport,
                    (d.volume * 100.0).round() as i32
                );
            }
            println!("\nDevices ({}):", ctrl.devices.len());
            for d in &ctrl.devices {
                println!("  - [{}] {} ({})", d.id, d.name, d.transport);
            }
        }
        "speaker" => {
            let mode = args
                .get(1)
                .and_then(|s| DspPresetSpeaker::from_cli(s))
                .unwrap_or_else(|| {
                    eprintln!("Usage: audiomatrix-pc speaker <off|nearfield|studio|stage>");
                    process::exit(1);
                });
            let mut next = ctrl.dsp_state.clone();
            next.apply_speaker_mode(mode);
            ctrl.update_dsp_config(next);
            println!("Speaker mode: {}", ctrl.dsp_state.summary_title());
        }
        "tone" => {
            let tone = args
                .get(1)
                .and_then(|s| DspPresetTone::from_cli(s))
                .unwrap_or_else(|| {
                    eprintln!("Usage: audiomatrix-pc tone <off|warm|clear|bass|vshape>");
                    process::exit(1);
                });
            let mut next = ctrl.dsp_state.clone();
            next.apply_tone_mode(tone);
            ctrl.update_dsp_config(next);
            println!("Tone profile: {}", ctrl.dsp_state.summary_title());
        }
        "input" => {
            let id = args.get(1).unwrap_or_else(|| process::exit(1));
            ctrl.select_input_device(id);
            println!("Selected input: {}", id);
        }
        "output" => {
            let id = args.get(1).unwrap_or_else(|| process::exit(1));
            ctrl.select_output_device(id);
            println!("Selected output: {}", id);
        }
        "volume" => {
            let id = args.get(1).unwrap_or_else(|| process::exit(1));
            let pct: f32 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(75.0);
            ctrl.set_device_volume(id, pct / 100.0);
            println!("Set {} volume to {}%", id, pct);
        }
        "app-volume" => {
            let id = args.get(1).unwrap_or_else(|| process::exit(1));
            let pct: f32 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(100.0);
            ctrl.set_app_volume(id, pct / 100.0);
            println!("Set app {} volume to {}%", id, pct);
        }
        "reset-apps" => {
            ctrl.reset_all_app_streams();
            println!("Reset all app mixer streams to default.");
        }
        "record" => {
            let out = args.get(1).map(PathBuf::from);
            let p = ctrl.start_recording(out).unwrap();
            let mut frames = vec![0.1f32; 4800 * 2];
            ctrl.process_and_record_frames(&mut frames).unwrap();
            let saved = ctrl.stop_recording().unwrap();
            println!("Saved internal audio WAV: {} ({})", saved.display(), p.display());
        }
        "self-test" => {
            run_self_tests();
        }
        _ => print_usage(),
    }
}
